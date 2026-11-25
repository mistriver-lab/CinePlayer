#if !os(tvOS)
import CinePlayerSDK
import CoreMedia
import CoreVideo
import Foundation
import Metal
import RifeMetal
@preconcurrency import VideoToolbox

/// RIFE frame interpolation adapter. Mirrors OpticalFlowFrameInterpolationAdapter's
/// shape (singleton, serial queue, pools, autorelease per frame) but delegates the
/// actual interpolation to RifeMetal's RifeInterpolator.
nonisolated final class RifeFrameInterpolationAdapter: @unchecked Sendable {
    static let shared = RifeFrameInterpolationAdapter()

    private let queue = DispatchQueue(
        label: "cn.com.cinemore.rife.adapter",
        qos: .userInitiated
    )

    // RIFE state — rebuilt when (width, height, tier) changes.
    // Note: stream holds a strong ref to its parent RifeInterpolator internally,
    // so we don't need a separate field here.
    private var stream: RifeStream?
    private var streamKey: (Int, Int, RifeQualityTier)?
    #if targetEnvironment(simulator)
    private var didLogSimulatorFallback: Bool = false
    #endif

    // Per-resolution pixel buffer pools.
    private var outputPool: CVPixelBufferPool?
    private var outputPoolKey: (Int, Int)?
    private var workOutputPool: CVPixelBufferPool?
    private var workOutputPoolKey: (Int, Int)?
    private var bgraConversionPool: CVPixelBufferPool?
    private var bgraConversionPoolKey: (Int, Int)?
    private var pixelTransferSession: VTPixelTransferSession?

    // Adaptive tier downgrade. Caller passes a preferred tier from static
    // resolution-based logic; if measured inference time consistently exceeds
    // the source-fps budget, we downgrade (hq → balanced → fast). Never
    // upgrades — avoids tier-flapping (each switch costs a ~200ms graph rebuild).
    private var effectiveTier: RifeQualityTier?
    private var lastDims: (Int, Int)?
    private var perfSamplesMs: [Double] = []
    private var framesSinceLastSwitch: Int = 0
    private var consecutiveOverBudgetFrames: Int = 0
    private var overloadSkipRemaining: Int = 0
    private var lastDiagLogNs: UInt64 = 0
    private var lastThermalWarnNs: UInt64 = 0
    private var lockedThermalLevel: Int = 0
    private var lastThermalAdjustNs: UInt64 = 0
    private var adaptiveDowngradeEnabled: Bool = true
    private var dynamicMaxInsertedFrames: Int? = nil
    private var multiFrameOverBudgetCount: Int = 0
    private var lastTargetFPS: InterpolationTargetFPS? = nil
    private static let perfWindowSize = 12
    private static let switchCooldownFrames = 20
    private static let downgradeBudgetRatio = 0.9 // p90 > 0.9 × budget triggers downgrade
    private static let overloadPassBudgetRatio = 1.35
    private static let overloadConsecutiveThreshold = 6
    private static let overloadCooldownFrames = 10
    private static let seriousOverloadPassBudgetRatio = 1.20
    private static let seriousOverloadConsecutiveThreshold = 5
    private static let seriousOverloadCooldownFrames = 24
    private static let thermalRecoveryHoldNs: UInt64 = 20_000_000_000
    private static let manualSevereBudgetRatio = 2.0
    private static let manualSevereConsecutiveThreshold = 6

    private static func thermalLevel(for state: ProcessInfo.ThermalState) -> Int {
        switch state {
        case .nominal: 0
        case .fair: 1
        case .serious: 2
        case .critical: 3
        @unknown default: 0
        }
    }

    /// Enable / disable runtime auto-downgrade. Disabled when the user picks an
    /// explicit tier — their choice is honored unless severe overload occurs on iOS.
    /// Clears prior runtime state so the next frame takes the caller-provided tier.
    nonisolated func setAdaptiveDowngradeEnabled(_ enabled: Bool) {
        queue.sync {
            adaptiveDowngradeEnabled = enabled
            effectiveTier = nil
            perfSamplesMs.removeAll(keepingCapacity: true)
            framesSinceLastSwitch = 0
            consecutiveOverBudgetFrames = 0
            overloadSkipRemaining = 0
            lastDiagLogNs = 0
            lastThermalWarnNs = 0
            lockedThermalLevel = 0
            lastThermalAdjustNs = 0
            dynamicMaxInsertedFrames = nil
            multiFrameOverBudgetCount = 0
            lastTargetFPS = nil
        }
    }

    /// Called on the queue when the adapter auto-switches tiers. Consumer
    /// (VideoPlayerModel) wires this up to update `PlayerEnhancementModel.currentRifeTier`
    /// for the UI footer.
    var onTierChanged: (@Sendable (RifeQualityTier) -> Void)?

    /// 结束会话并释放资源。
    nonisolated func endSession() {
        queue.sync {
            stream = nil
            streamKey = nil
            outputPool = nil
            outputPoolKey = nil
            workOutputPool = nil
            workOutputPoolKey = nil
            bgraConversionPool = nil
            bgraConversionPoolKey = nil
            if let session = pixelTransferSession {
                VTPixelTransferSessionInvalidate(session)
            }
            pixelTransferSession = nil
            effectiveTier = nil
            lastDims = nil
            perfSamplesMs.removeAll(keepingCapacity: true)
            framesSinceLastSwitch = 0
            consecutiveOverBudgetFrames = 0
            overloadSkipRemaining = 0
            lastDiagLogNs = 0
            lastThermalWarnNs = 0
            lockedThermalLevel = 0
            lastThermalAdjustNs = 0
            dynamicMaxInsertedFrames = nil
            multiFrameOverBudgetCount = 0
            lastTargetFPS = nil
            #if targetEnvironment(simulator)
            didLogSimulatorFallback = false
            #endif
        }
    }

    nonisolated static func workingDimensions(
        sourceWidth: Int,
        sourceHeight: Int,
        tier: RifeQualityTier,
        thermalLevel: Int = 0,
        insertedCount: Int = 1
    ) -> (Int, Int) {
        #if os(iOS)
        let baseLongEdge: Int
        switch tier {
        case .fast: baseLongEdge = 640
        case .balanced: baseLongEdge = 896
        case .hq: baseLongEdge = 896
        }
        let multiScale = insertedCount >= 2 ? 0.80 : 1.0
        let scaledBase = max(448, (Int(Double(baseLongEdge) * multiScale) / 32) * 32)
        let maxLongEdge: Int
        if thermalLevel >= 2 {
            maxLongEdge = max(416, (Int(Double(scaledBase) * 0.75) / 32) * 32)
        } else if thermalLevel == 1 {
            maxLongEdge = max(448, (Int(Double(scaledBase) * 0.85) / 32) * 32)
        } else {
            maxLongEdge = scaledBase
        }
        let longEdge = max(sourceWidth, sourceHeight)
        guard longEdge > maxLongEdge, longEdge > 0 else {
            return (sourceWidth, sourceHeight)
        }
        let scale = Double(maxLongEdge) / Double(longEdge)
        let alignDown32: (Int) -> Int = { raw in
            max(64, (raw / 32) * 32)
        }
        return (
            alignDown32(Int((Double(sourceWidth) * scale).rounded(.down))),
            alignDown32(Int((Double(sourceHeight) * scale).rounded(.down)))
        )
        #else
        return (sourceWidth, sourceHeight)
        #endif
    }

    /// Pre-build the RifeInterpolator and graph for the given dims/tier on a background
    /// thread, so the first frame doesn't pay the build cost.
    nonisolated func warmup(dimensions: CMVideoDimensions, tier: RifeQualityTier) async {
        let srcW = Int(dimensions.width)
        let srcH = Int(dimensions.height)
        guard srcW > 0, srcH > 0 else { return }
        let initialThermalLevel = min(2, Self.thermalLevel(for: ProcessInfo.processInfo.thermalState))
        let (workW, workH) = Self.workingDimensions(
            sourceWidth: srcW,
            sourceHeight: srcH,
            tier: tier,
            thermalLevel: initialThermalLevel
        )
        await Task.detached(priority: .userInitiated) { [weak self] in
            self?.queue.sync {
                _ = self?.ensureStreamOnQueue(
                    width: workW,
                    height: workH,
                    tier: tier
                )
            }
        }.value
    }

    nonisolated func processTemporal(
        previous: PreviousVideoFrameSnapshot?,
        current: VideoFrameContext,
        tier: RifeQualityTier,
        targetFPS: InterpolationTargetFPS = .doubleSource,
        screenMaxFPS: Int = 60
    ) -> VideoFrameResult {
        queue.sync {
            guard let previous, current.timestamp > previous.timestamp else {
                return .passthrough
            }
            return processTemporalOnQueue(
                previous: previous,
                current: current,
                tier: tier,
                targetFPS: targetFPS,
                screenMaxFPS: screenMaxFPS
            )
        }
    }

    private func processTemporalOnQueue(
        previous: PreviousVideoFrameSnapshot,
        current: VideoFrameContext,
        tier: RifeQualityTier,
        targetFPS: InterpolationTargetFPS,
        screenMaxFPS: Int
    ) -> VideoFrameResult {
        // autoreleasepool 强制 drain VT/CV 临时 IOSurface,避免 per-client 16384 配额上限。
        autoreleasepool {
            let totalStart = DispatchTime.now().uptimeNanoseconds
            let prevTs = previous.timestamp
            let currTs = current.timestamp
            let segmentDur = currTs - prevTs

            // 整数 timebase 1 tick/帧无法切两半,降级为 anchor 段。
            guard segmentDur >= 2 else {
                return .replaceMany([
                    GeneratedVideoFrame(pixelBuffer: current.pixelBuffer,
                                         timestamp: prevTs,
                                         duration: segmentDur)
                ])
            }

            let thermalState = ProcessInfo.processInfo.thermalState
            if thermalState == .critical {
                let nowNs = DispatchTime.now().uptimeNanoseconds
                if lastThermalWarnNs == 0 || nowNs &- lastThermalWarnNs >= 5_000_000_000 {
                    lastThermalWarnNs = nowNs
                    EnhancementTelemetryCollector.shared.recordDowngrade(
                        reason: "RIFE 设备过热，已切直通"
                    )
                }
                stream?.reset()
                return .passthrough
            }

            if overloadSkipRemaining > 0 {
                overloadSkipRemaining -= 1
                stream?.reset()
                return .passthrough
            }

            let width = CVPixelBufferGetWidth(current.pixelBuffer)
            let height = CVPixelBufferGetHeight(current.pixelBuffer)
            guard width > 0, height > 0 else { return .passthrough }

            // Reset adaptive state on dimension change (different perf characteristics).
            let dims = (width, height)
            if lastDims.map({ $0 != dims }) ?? true {
                effectiveTier = tier
                perfSamplesMs.removeAll(keepingCapacity: true)
                framesSinceLastSwitch = 0
                consecutiveOverBudgetFrames = 0
                overloadSkipRemaining = 0
                lastDiagLogNs = 0
                lastThermalWarnNs = 0
                lockedThermalLevel = 0
                lastThermalAdjustNs = 0
                dynamicMaxInsertedFrames = nil
                multiFrameOverBudgetCount = 0
                lastTargetFPS = targetFPS
                lastDims = dims
            } else if lastTargetFPS != targetFPS {
                dynamicMaxInsertedFrames = nil
                multiFrameOverBudgetCount = 0
                lastTargetFPS = targetFPS
            }

            let rawThermalLevel = min(2, Self.thermalLevel(for: thermalState))
            if rawThermalLevel > lockedThermalLevel {
                lockedThermalLevel = rawThermalLevel
                lastThermalAdjustNs = totalStart
                let label = rawThermalLevel >= 2 ? "偏热" : "温热"
                EnhancementTelemetryCollector.shared.recordDowngrade(
                    reason: "RIFE 设备\(label)，已动态降低推理分辨率"
                )
            } else if rawThermalLevel < lockedThermalLevel,
                      totalStart &- lastThermalAdjustNs >= Self.thermalRecoveryHoldNs
            {
                lockedThermalLevel -= 1
                lastThermalAdjustNs = totalStart
            }

            #if os(iOS)
            let baseMaxAllowed = (thermalState == .fair || thermalState == .serious) ? 1 : 2
            #else
            let baseMaxAllowed = 3
            #endif
            let effectiveMaxAllowed = dynamicMaxInsertedFrames.map { min(baseMaxAllowed, $0) } ?? baseMaxAllowed
            var insertedCount = PlayerEnhancementModel.resolveInterpolatedFrameCount(
                sourceFPS: Double(current.fps),
                target: targetFPS,
                screenMaxFPS: screenMaxFPS,
                maxAllowedInsertedFrames: effectiveMaxAllowed,
                thermalState: thermalState
            )
            if insertedCount == 0 {
                stream?.reset()
                return .passthrough
            }
            insertedCount = min(insertedCount, Int(segmentDur) - 1)
            guard insertedCount > 0 else {
                return .replaceMany([
                    GeneratedVideoFrame(pixelBuffer: current.pixelBuffer,
                                         timestamp: prevTs,
                                         duration: segmentDur)
                ])
            }

            let activeTier = effectiveTier ?? tier
            let (workW, workH) = Self.workingDimensions(
                sourceWidth: width,
                sourceHeight: height,
                tier: activeTier,
                thermalLevel: lockedThermalLevel,
                insertedCount: insertedCount
            )
            let needsScaling = (workW != width || workH != height)

            guard let stream = ensureStreamOnQueue(width: workW, height: workH, tier: activeTier) else {
                return .passthrough
            }

            // Stream caches the prev frame internally; convert and hardware-scale curr in one pass.
            guard let currBGRA = pixelBufferAsBGRAOnQueue(current.pixelBuffer, width: workW, height: workH) else {
                cinemoreLog(level: .debug, "[VFI-RIFE] pixelBufferAsBGRA failed")
                return .passthrough
            }
            let tAfterVT = DispatchTime.now().uptimeNanoseconds

            let tAfterPool: UInt64
            let tAfterInfer: UInt64
            let generated: [GeneratedVideoFrame]

            if insertedCount == 1 {
                guard let inferOutBuffer = needsScaling
                    ? ensureWorkOutputPool(width: workW, height: workH)
                    : ensureOutputPool(width: width, height: height) else {
                    cinemoreLog(level: .debug, "[VFI-RIFE] ensureOutputPool failed")
                    return .passthrough
                }
                if !needsScaling {
                    current.pixelBuffer.copyPropagatedAttachments(to: inferOutBuffer)
                }
                tAfterPool = DispatchTime.now().uptimeNanoseconds

                let didWriteMidframe: Bool
                do {
                    didWriteMidframe = try stream.push(currBGRA, into: inferOutBuffer)
                } catch {
                    cinemoreLog(level: .debug, "[VFI-RIFE] stream.push failed: \(error)")
                    return .passthrough
                }
                tAfterInfer = DispatchTime.now().uptimeNanoseconds

                if !didWriteMidframe {
                    return .replaceMany([
                        GeneratedVideoFrame(pixelBuffer: current.pixelBuffer,
                                             timestamp: prevTs,
                                             duration: segmentDur)
                    ])
                }

                let finalMidBuffer: CVPixelBuffer
                if needsScaling {
                    guard let fullOutBuffer = ensureOutputPool(width: width, height: height) else {
                        cinemoreLog(level: .debug, "[VFI-RIFE] ensureOutputPool (upscale) failed")
                        return .passthrough
                    }
                    current.pixelBuffer.copyPropagatedAttachments(to: fullOutBuffer)
                    guard scaleBufferOnQueue(inferOutBuffer, into: fullOutBuffer) else {
                        cinemoreLog(level: .debug, "[VFI-RIFE] upscale failed")
                        return .passthrough
                    }
                    finalMidBuffer = fullOutBuffer
                } else {
                    finalMidBuffer = inferOutBuffer
                }

                // 两段 duration 严格相加 == segmentDur,否则时间轴错位。
                let firstDuration = segmentDur / 2
                let secondDuration = segmentDur - firstDuration
                let midTs = prevTs + firstDuration
                generated = [
                    GeneratedVideoFrame(pixelBuffer: finalMidBuffer, timestamp: prevTs, duration: firstDuration),
                    GeneratedVideoFrame(pixelBuffer: current.pixelBuffer, timestamp: midTs, duration: secondDuration),
                ]
            } else {
                tAfterPool = DispatchTime.now().uptimeNanoseconds
                let timesteps = (1...insertedCount).map { Float($0) / Float(insertedCount + 1) }
                let rawMids: [CVPixelBuffer]
                do {
                    rawMids = try stream.push(currBGRA, timesteps: timesteps)
                } catch {
                    cinemoreLog(level: .debug, "[VFI-RIFE] stream.push(timesteps:) failed: \(error)")
                    return .passthrough
                }
                tAfterInfer = DispatchTime.now().uptimeNanoseconds

                if rawMids.isEmpty {
                    return .replaceMany([
                        GeneratedVideoFrame(pixelBuffer: current.pixelBuffer,
                                             timestamp: prevTs,
                                             duration: segmentDur)
                    ])
                }

                var finalMids: [CVPixelBuffer] = []
                finalMids.reserveCapacity(rawMids.count)
                for rawMid in rawMids {
                    if needsScaling {
                        guard let fullOutBuffer = ensureOutputPool(width: width, height: height) else {
                            cinemoreLog(level: .debug, "[VFI-RIFE] ensureOutputPool (multi-upscale) failed")
                            return .passthrough
                        }
                        current.pixelBuffer.copyPropagatedAttachments(to: fullOutBuffer)
                        guard scaleBufferOnQueue(rawMid, into: fullOutBuffer) else {
                            cinemoreLog(level: .debug, "[VFI-RIFE] multi-upscale failed")
                            return .passthrough
                        }
                        finalMids.append(fullOutBuffer)
                    } else {
                        current.pixelBuffer.copyPropagatedAttachments(to: rawMid)
                        finalMids.append(rawMid)
                    }
                }

                let durations = PlayerEnhancementModel.splitSegmentDurations(
                    totalDuration: segmentDur,
                    segmentCount: finalMids.count + 1
                )
                var frames: [GeneratedVideoFrame] = []
                frames.reserveCapacity(finalMids.count + 1)
                var runningTs = prevTs
                for (idx, midBuf) in finalMids.enumerated() {
                    let dur = durations[idx]
                    frames.append(GeneratedVideoFrame(pixelBuffer: midBuf, timestamp: runningTs, duration: dur))
                    runningTs += dur
                }
                frames.append(
                    GeneratedVideoFrame(
                        pixelBuffer: current.pixelBuffer,
                        timestamp: runningTs,
                        duration: durations[finalMids.count]
                    )
                )
                generated = frames
            }
            let tEnd = DispatchTime.now().uptimeNanoseconds
            let totalMs = Double(tEnd - totalStart) / 1_000_000
            if lastDiagLogNs == 0 || tEnd &- lastDiagLogNs >= 1_000_000_000 {
                lastDiagLogNs = tEnd
                let vtMs    = Double(tAfterVT - totalStart)   / 1_000_000
                let poolMs  = Double(tAfterPool - tAfterVT)   / 1_000_000
                let inferMs = Double(tAfterInfer - tAfterPool) / 1_000_000
                let postMs  = Double(tEnd - tAfterInfer)       / 1_000_000
                let thermal = DiagnosticLogStore.currentThermalStateText()
                cinemoreLog(
                    level: .debug,
                    "[VFI-RIFE] diag total=\(String(format: "%.1f", totalMs))ms" +
                    " (vt=\(String(format: "%.1f", vtMs))" +
                    " pool=\(String(format: "%.1f", poolMs))" +
                    " infer=\(String(format: "%.1f", inferMs))" +
                    " post=\(String(format: "%.1f", postMs)))" +
                    " tier=\(activeTier.rawValue) ins=\(insertedCount) src=\(width)x\(height) work=\(workW)x\(workH) thermal=\(thermal)"
                )
            }

            adaptTierIfNeededOnQueue(elapsedMs: totalMs, fps: current.fps, currentTier: activeTier)

            if insertedCount > 1, current.fps > 0.5 {
                let budgetMs = 1000.0 / Double(current.fps)
                if totalMs > budgetMs * 0.90 {
                    multiFrameOverBudgetCount += 1
                    if multiFrameOverBudgetCount >= 6 {
                        dynamicMaxInsertedFrames = max(1, insertedCount - 1)
                        multiFrameOverBudgetCount = 0
                        EnhancementTelemetryCollector.shared.recordDowngrade(
                            reason: "RIFE \(insertedCount + 1)× 超出帧预算(\(Int(totalMs))ms)，已稳帧为 \(insertedCount)×"
                        )
                    }
                } else {
                    multiFrameOverBudgetCount = 0
                }
            } else {
                multiFrameOverBudgetCount = 0
            }

            if adaptiveDowngradeEnabled, activeTier == .fast, current.fps > 0.5 {
                let budgetMs = 1000.0 / Double(current.fps)
                let activeBudgetRatio = thermalState == .serious
                    ? Self.seriousOverloadPassBudgetRatio
                    : Self.overloadPassBudgetRatio
                let activeConsecThreshold = thermalState == .serious
                    ? Self.seriousOverloadConsecutiveThreshold
                    : Self.overloadConsecutiveThreshold
                let activeCooldownFrames = thermalState == .serious
                    ? Self.seriousOverloadCooldownFrames
                    : Self.overloadCooldownFrames
                if totalMs > budgetMs * activeBudgetRatio {
                    consecutiveOverBudgetFrames += 1
                    if consecutiveOverBudgetFrames >= activeConsecThreshold {
                        overloadSkipRemaining = activeCooldownFrames
                        consecutiveOverBudgetFrames = 0
                        EnhancementTelemetryCollector.shared.recordDowngrade(
                            reason: "RIFE 极速档超负荷，短暂直通冷却"
                        )
                    }
                } else {
                    consecutiveOverBudgetFrames = 0
                }
            } else if !adaptiveDowngradeEnabled,
                      let next = activeTier.downgraded(),
                      current.fps > 0.5 {
                #if os(iOS)
                let budgetMs = 1000.0 / Double(current.fps)
                if totalMs > budgetMs * Self.manualSevereBudgetRatio {
                    consecutiveOverBudgetFrames += 1
                    if consecutiveOverBudgetFrames >= Self.manualSevereConsecutiveThreshold {
                        let reason = "RIFE \(activeTier.rawValue.uppercased()) 严重超时，自动降档至 \(next.rawValue.uppercased())"
                        cinemoreLog(
                            level: .warning,
                            "[VFI-RIFE] manual severe timeout \(activeTier.rawValue) -> \(next.rawValue) (total=\(String(format: "%.1f", totalMs))ms budget=\(String(format: "%.1f", budgetMs))ms fps=\(current.fps))"
                        )
                        EnhancementTelemetryCollector.shared.recordDowngrade(
                            reason: reason,
                            detail: next.rawValue
                        )
                        effectiveTier = next
                        consecutiveOverBudgetFrames = 0
                        framesSinceLastSwitch = 0
                        perfSamplesMs.removeAll(keepingCapacity: true)
                        self.stream = nil
                        self.streamKey = nil
                        let cb = onTierChanged
                        cb?(next)
                    }
                } else {
                    consecutiveOverBudgetFrames = 0
                }
                #else
                consecutiveOverBudgetFrames = 0
                #endif
            } else {
                consecutiveOverBudgetFrames = 0
            }

            return .replaceMany(generated)
        }
    }

    /// Drop the stream's cached previous-frame state. Called on seek /
    /// generation change so the next push goes through the first-frame path
    /// instead of interpolating across a discontinuity.
    nonisolated func resetStream() {
        queue.sync {
            stream?.reset()
        }
    }

    /// Single-direction adaptive tier control: downgrade hq → balanced → fast when
    /// measured p90 inference time exceeds the source-fps budget. Never upgrades —
    /// each tier change costs a ~200 ms graph rebuild stall, so flapping must be
    /// avoided. Once at fast, no further action.
    private func adaptTierIfNeededOnQueue(elapsedMs: Double, fps: Float, currentTier: RifeQualityTier) {
        guard adaptiveDowngradeEnabled else { return }
        framesSinceLastSwitch += 1
        perfSamplesMs.append(elapsedMs)
        if perfSamplesMs.count > Self.perfWindowSize {
            perfSamplesMs.removeFirst()
        }

        guard let next = currentTier.downgraded() else { return }
        guard perfSamplesMs.count >= Self.perfWindowSize,
              framesSinceLastSwitch >= Self.switchCooldownFrames,
              fps > 0.5 else { return }

        let budgetMs = 1000.0 / Double(fps)
        let sorted = perfSamplesMs.sorted()
        let p90 = sorted[Int(Double(sorted.count) * 0.9)]
        guard p90 > budgetMs * Self.downgradeBudgetRatio else { return }

        cinemoreLog(
            level: .warning,
            "[VFI-RIFE] auto-downgrade \(currentTier.rawValue) → \(next.rawValue) (p90=\(String(format: "%.1f", p90))ms budget=\(String(format: "%.1f", budgetMs))ms fps=\(fps))"
        )
        EnhancementTelemetryCollector.shared.recordDowngrade(
            reason: "RIFE 过载，自动降档 \(currentTier.rawValue.uppercased()) → \(next.rawValue.uppercased())",
            detail: next.rawValue
        )
        effectiveTier = next
        framesSinceLastSwitch = 0
        consecutiveOverBudgetFrames = 0
        perfSamplesMs.removeAll(keepingCapacity: true)
        // Force RifeStream rebuild on next frame with the new tier.
        stream = nil
        streamKey = nil
        let cb = onTierChanged
        cb?(next)
    }

    // MARK: - Private (queue-confined)

    private func ensureStreamOnQueue(
        width: Int,
        height: Int,
        tier: RifeQualityTier
    ) -> RifeStream? {
        #if targetEnvironment(simulator)
        if !didLogSimulatorFallback {
            didLogSimulatorFallback = true
            cinemoreLog(
                level: .warning,
                "[VFI-RIFE] MPSGraphDevice is unavailable on iOS Simulator (Apple MetalPerformanceShadersGraph NSInvalidArgumentException); falling back to passthrough (\(width)x\(height) tier=\(tier.rawValue))"
            )
        }
        return nil
        #else
        let key = (width, height, tier)
        if let existing = stream,
           let existingKey = streamKey,
           existingKey == key {
            return existing
        }
        do {
            let interp = try RifeInterpolator(
                configuration: .bundled(qualityTier: tier))
            let s = try interp.makeStream(width: width, height: height)
            stream = s
            streamKey = key
            return s
        } catch {
            cinemoreLog(level: .debug, "[VFI-RIFE] makeStream init failed: \(error)")
            return nil
        }
        #endif
    }

    private func ensureOutputPool(width: Int, height: Int) -> CVPixelBuffer? {
        acquireBGRAPixelBuffer(
            pool: &outputPool,
            poolKey: &outputPoolKey,
            width: width,
            height: height
        )
    }

    private func ensureWorkOutputPool(width: Int, height: Int) -> CVPixelBuffer? {
        acquireBGRAPixelBuffer(
            pool: &workOutputPool,
            poolKey: &workOutputPoolKey,
            width: width,
            height: height
        )
    }

    private func ensureBGRAConversionBuffer(width: Int, height: Int) -> CVPixelBuffer? {
        acquireBGRAPixelBuffer(
            pool: &bgraConversionPool,
            poolKey: &bgraConversionPoolKey,
            width: width,
            height: height
        )
    }

    private func acquireBGRAPixelBuffer(
        pool: inout CVPixelBufferPool?,
        poolKey: inout (Int, Int)?,
        width: Int,
        height: Int
    ) -> CVPixelBuffer? {
        let key = (width, height)
        if let existingKey = poolKey, existingKey == key, let existingPool = pool {
            var buf: CVPixelBuffer?
            guard CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, existingPool, &buf) == kCVReturnSuccess,
                  let buf else { return nil }
            return buf
        }
        let attrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA),
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferMetalCompatibilityKey as String: true,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
        ]
        var createdPool: CVPixelBufferPool?
        guard CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, attrs as CFDictionary, &createdPool) == kCVReturnSuccess,
              let createdPool else { return nil }
        pool = createdPool
        poolKey = key
        var buf: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, createdPool, &buf) == kCVReturnSuccess,
              let buf else { return nil }
        return buf
    }

    private func ensurePixelTransferSession() -> VTPixelTransferSession? {
        if let existing = pixelTransferSession {
            return existing
        }
        var newSession: VTPixelTransferSession?
        guard VTPixelTransferSessionCreate(
            allocator: kCFAllocatorDefault,
            pixelTransferSessionOut: &newSession
        ) == noErr,
        let newSession else {
            return nil
        }
        pixelTransferSession = newSession
        return newSession
    }

    private func scaleBufferOnQueue(_ source: CVPixelBuffer, into destination: CVPixelBuffer) -> Bool {
        guard let session = ensurePixelTransferSession() else {
            return false
        }
        return VTPixelTransferSessionTransferImage(session, from: source, to: destination) == noErr
    }

    private func pixelBufferAsBGRAOnQueue(_ buffer: CVPixelBuffer,
                                            width: Int,
                                            height: Int) -> CVPixelBuffer? {
        if CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_32BGRA,
           CVPixelBufferGetWidth(buffer) == width,
           CVPixelBufferGetHeight(buffer) == height {
            return buffer
        }
        guard let outRef = ensureBGRAConversionBuffer(width: width, height: height) else {
            return nil
        }
        return scaleBufferOnQueue(buffer, into: outRef) ? outRef : nil
    }
}

nonisolated private final class RifeTemporalProcessor: VideoFrameProcessor, @unchecked Sendable {
    private let adapter: RifeFrameInterpolationAdapter
    private let tier: RifeQualityTier
    private let targetFPS: InterpolationTargetFPS
    private let screenMaxFPS: Int
    private let buffer = TemporalReorderBuffer()

    init(
        adapter: RifeFrameInterpolationAdapter,
        tier: RifeQualityTier,
        targetFPS: InterpolationTargetFPS,
        screenMaxFPS: Int
    ) {
        self.adapter = adapter
        self.tier = tier
        self.targetFPS = targetFPS
        self.screenMaxFPS = screenMaxFPS
    }

    func onFrame(_ ctx: VideoFrameContext) -> VideoFrameResult {
        buffer.accept(ctx) { previous, current in
            adapter.processTemporal(
                previous: previous,
                current: current,
                tier: tier,
                targetFPS: targetFPS,
                screenMaxFPS: screenMaxFPS
            )
        }
    }

    func onInvalidate(newGeneration _: Int64) {
        adapter.resetStream()
        buffer.onInvalidate()
    }

    func drainPendingFrames() -> [GeneratedVideoFrame] {
        buffer.drainPendingFrames()
    }

    func onDrain() {
        buffer.onDrain()
        adapter.endSession()
    }

    var hasPendingFrames: Bool {
        buffer.hasPendingFrames
    }
}

extension RifeFrameInterpolationAdapter {
    nonisolated func makeTemporalProcessor(
        tier: RifeQualityTier,
        targetFPS: InterpolationTargetFPS = .doubleSource,
        screenMaxFPS: Int = 60
    ) -> any VideoFrameProcessor {
        RifeTemporalProcessor(
            adapter: self,
            tier: tier,
            targetFPS: targetFPS,
            screenMaxFPS: screenMaxFPS
        )
    }
}

private extension RifeQualityTier {
    nonisolated func downgraded() -> RifeQualityTier? {
        switch self {
        case .hq: return .balanced
        case .balanced: return .fast
        case .fast: return nil
        }
    }
}

#endif
