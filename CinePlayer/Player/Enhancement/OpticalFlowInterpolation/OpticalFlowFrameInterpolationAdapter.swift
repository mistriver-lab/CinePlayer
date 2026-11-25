#if !os(tvOS)
    import CoreMedia
    import CoreVideo
    import Foundation
    import Metal
    import CinePlayerSDK
    @preconcurrency import VideoToolbox
    import Vision

    nonisolated struct OpticalFlowRequestKey: Hashable, Sendable {
        let previousTimestamp: Int64
        let currentTimestamp: Int64
        let generation: Int64
        let width: Int
        let height: Int
    }

    nonisolated struct OpticalFlowPair: @unchecked Sendable {
        let forwardFlow: CVPixelBuffer
        let backwardFlow: CVPixelBuffer
    }

    nonisolated private struct OpticalFlowFusedParams {
        var t: Float
        var flowErrorPivot: Float
    }

    nonisolated private final class OpticalFlowDownscaler: @unchecked Sendable {
        private let lock = NSLock()
        private var pool: CVPixelBufferPool?
        private var poolKey: (Int, Int)?
        private var transferSession: VTPixelTransferSession?

        static func targetSize(
            width: Int,
            height: Int,
            thermalState: ProcessInfo.ThermalState = ProcessInfo.processInfo.thermalState
        ) -> (Int, Int) {
            let maxLong: Double
            let maxShort: Double
            if thermalState == .serious || thermalState == .critical {
                maxLong = 480.0
                maxShort = 270.0
            } else {
                maxLong = 640.0
                maxShort = 360.0
            }
            let longSide = max(width, height)
            let shortSide = min(width, height)
            if Double(longSide) <= maxLong && Double(shortSide) <= maxShort {
                return (width, height)
            }
            let scale = min(maxLong / Double(longSide), maxShort / Double(shortSide))
            let scaledW = max(16, (Int(Double(width) * scale) / 2) * 2)
            let scaledH = max(16, (Int(Double(height) * scale) / 2) * 2)
            return (scaledW, scaledH)
        }

        func downscaleIfNeeded(
            _ buffer: CVPixelBuffer,
            thermalState: ProcessInfo.ThermalState = ProcessInfo.processInfo.thermalState
        ) -> CVPixelBuffer? {
            let srcW = CVPixelBufferGetWidth(buffer)
            let srcH = CVPixelBufferGetHeight(buffer)
            guard srcW > 0, srcH > 0 else { return nil }

            let (dstW, dstH) = Self.targetSize(width: srcW, height: srcH, thermalState: thermalState)
            let pixelFormat = CVPixelBufferGetPixelFormatType(buffer)
            if srcW == dstW, srcH == dstH, pixelFormat == kCVPixelFormatType_32BGRA {
                return buffer
            }

            lock.lock()
            defer { lock.unlock() }
            guard let outBuffer = ensureBufferOnLock(width: dstW, height: dstH),
                  let session = ensureTransferSessionOnLock()
            else {
                return nil
            }
            guard VTPixelTransferSessionTransferImage(session, from: buffer, to: outBuffer) == noErr else {
                return nil
            }
            return outBuffer
        }

        func reset() {
            lock.lock()
            if let session = transferSession {
                VTPixelTransferSessionInvalidate(session)
            }
            transferSession = nil
            pool = nil
            poolKey = nil
            lock.unlock()
        }

        private func ensureTransferSessionOnLock() -> VTPixelTransferSession? {
            if let transferSession {
                return transferSession
            }
            var session: VTPixelTransferSession?
            guard VTPixelTransferSessionCreate(
                allocator: kCFAllocatorDefault,
                pixelTransferSessionOut: &session
            ) == noErr,
            let session
            else {
                return nil
            }
            transferSession = session
            return session
        }

        private func ensureBufferOnLock(width: Int, height: Int) -> CVPixelBuffer? {
            let key = (width, height)
            if let existing = poolKey, existing == key, let pool {
                var buf: CVPixelBuffer?
                guard CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &buf) == kCVReturnSuccess,
                      let buf
                else {
                    return nil
                }
                return buf
            }
            let attrs: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA),
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
                kCVPixelBufferMetalCompatibilityKey as String: true,
                kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
            ]
            var newPool: CVPixelBufferPool?
            guard CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, attrs as CFDictionary, &newPool) == kCVReturnSuccess,
                  let newPool
            else {
                return nil
            }
            pool = newPool
            poolKey = key
            var buf: CVPixelBuffer?
            guard CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, newPool, &buf) == kCVReturnSuccess,
                  let buf
            else {
                return nil
            }
            return buf
        }
    }

    nonisolated final class OpticalFlowAsyncProvider: @unchecked Sendable {
        private let flowQueue = DispatchQueue(
            label: "cn.com.cinemore.opticalflow.async-provider",
            qos: .userInitiated
        )
        private let lock = NSLock()
        private let cacheLimit: Int
        private let flowRunner: @Sendable (CVPixelBuffer, CVPixelBuffer) -> OpticalFlowPair?
        private var cache: [OpticalFlowRequestKey: OpticalFlowPair] = [:]
        private var order: [OpticalFlowRequestKey] = []
        private var pending: Set<OpticalFlowRequestKey> = []
        private var resetEpoch: Int64 = 0

        init(
            maxCachedPairs: Int = 6,
            flowRunner: @escaping @Sendable (CVPixelBuffer, CVPixelBuffer) -> OpticalFlowPair?
        ) {
            cacheLimit = max(1, maxCachedPairs)
            self.flowRunner = flowRunner
        }

        nonisolated func cachedResult(for key: OpticalFlowRequestKey) -> OpticalFlowPair? {
            lock.lock()
            defer { lock.unlock() }
            return cache[key]
        }

        nonisolated func submitIfNeeded(
            key: OpticalFlowRequestKey,
            previous: CVPixelBuffer,
            current: CVPixelBuffer
        ) {
            lock.lock()
            if cache[key] != nil || pending.contains(key) {
                lock.unlock()
                return
            }
            pending.insert(key)
            let epoch = resetEpoch
            lock.unlock()

            flowQueue.async { [weak self] in
                guard let self else { return }
                let result = autoreleasepool {
                    self.flowRunner(previous, current)
                }
                self.lock.lock()
                defer { self.lock.unlock() }
                self.pending.remove(key)
                guard epoch == self.resetEpoch, let result else {
                    return
                }
                self.cache[key] = result
                self.order.removeAll { $0 == key }
                self.order.append(key)
                while self.order.count > self.cacheLimit {
                    let removed = self.order.removeFirst()
                    self.cache.removeValue(forKey: removed)
                }
            }
        }

        nonisolated func reset() {
            lock.lock()
            resetEpoch &+= 1
            cache.removeAll(keepingCapacity: false)
            order.removeAll(keepingCapacity: false)
            pending.removeAll(keepingCapacity: false)
            lock.unlock()
        }
    }

    /// 光流补帧适配器：计算下采样前后向光流，单 Pass Metal 融合着色器完成双向 backward-warp、
    /// 前后向与颜色双重置信度计算及合成，避免多 Pass 中间纹理与 barrier 开销，并防止大位移/遮挡鬼影。
    nonisolated final class OpticalFlowFrameInterpolationAdapter: @unchecked Sendable {
        static let shared = OpticalFlowFrameInterpolationAdapter()

        private let queue = DispatchQueue(label: "cn.com.cinemore.opticalflow.adapter", qos: .userInitiated)
        private var device: MTLDevice?
        private var textureCache: CVMetalTextureCache?
        private var fusedPipelineState: MTLComputePipelineState?
        private var library: MTLLibrary?
        private var commandQueue: MTLCommandQueue?
        private var outputPool: CVPixelBufferPool?
        private var outputPoolKey: (Int, Int)?
        private var bgraConversionPool: CVPixelBufferPool?
        private var bgraConversionPoolKey: (Int, Int)?
        private var pixelTransferSession: VTPixelTransferSession?
        private let flowDownscaler = OpticalFlowDownscaler()
        private var asyncFlowProvider: OpticalFlowAsyncProvider
        private var cacheHits: Int = 0
        private var cacheMisses: Int = 0
        private var lastDiagLogNs: UInt64 = 0
        private var lastThermalWarnNs: UInt64 = 0

        /// 前后向残差的 smoothstep 中心（输出像素单位）。低于 0.5× 完全可信，高于 1.5× 完全不可信。
        private static let flowErrorPivot: Float = 1.5

        init() {
            asyncFlowProvider = OpticalFlowAsyncProvider { _, _ in nil }
            asyncFlowProvider = OpticalFlowAsyncProvider { [weak self] previous, current in
                self?.createOpticalFlowPair(source: previous, target: current)
            }
        }

        /// 结束会话并释放资源。
        nonisolated func endSession() {
            queue.sync {
                textureCache = nil
                fusedPipelineState = nil
                library = nil
                commandQueue = nil
                outputPool = nil
                outputPoolKey = nil
                bgraConversionPool = nil
                bgraConversionPoolKey = nil
                if let session = pixelTransferSession {
                    VTPixelTransferSessionInvalidate(session)
                }
                pixelTransferSession = nil
                cacheHits = 0
                cacheMisses = 0
                lastDiagLogNs = 0
                lastThermalWarnNs = 0
                flowDownscaler.reset()
                asyncFlowProvider.reset()
            }
        }

        /// Center 首帧前预热：在 user-initiated 后台线程提前完成 Metal device/library/pipelineState/commandQueue/textureCache 初始化。
        /// `dimensions` 仅作为接口对称参数（OF 流水线本身不依赖；textureCache 不需要尺寸）。
        nonisolated func warmup(dimensions _: CMVideoDimensions) async {
            await Task.detached(priority: .userInitiated) { [weak self] in
                self?.queue.sync {
                    _ = self?.ensureMetalResourcesOnQueue()
                }
            }.value
        }

        /// 时域插帧：根据 prev/curr 生成 [插值帧..., 当前帧]，覆盖 [prevTs, currTs)。previous 由 Center 填充；为 nil 直接 passthrough（Center 走兜底保形）。
        nonisolated func processTemporal(
            previous: PreviousVideoFrameSnapshot?,
            current: VideoFrameContext,
            targetFPS: InterpolationTargetFPS = .doubleSource,
            screenMaxFPS: Int = 60
        ) -> VideoFrameResult {
            queue.sync {
                guard let previous else {
                    return .passthrough
                }
                guard current.timestamp > previous.timestamp else {
                    return .passthrough
                }
                return processTemporalOnQueue(
                    previous: previous,
                    current: current,
                    targetFPS: targetFPS,
                    screenMaxFPS: screenMaxFPS
                )
            }
        }

        nonisolated func resetPrefetchCache() {
            asyncFlowProvider.reset()
        }

        nonisolated func prefetchFlow(
            previous: PreviousVideoFrameSnapshot,
            currentPixelBuffer: CVPixelBuffer,
            currentTimestamp: Int64,
            generation: Int64
        ) {
            let width = CVPixelBufferGetWidth(currentPixelBuffer)
            let height = CVPixelBufferGetHeight(currentPixelBuffer)
            guard width > 0, height > 0, currentTimestamp > previous.timestamp else {
                return
            }
            let key = OpticalFlowRequestKey(
                previousTimestamp: previous.timestamp,
                currentTimestamp: currentTimestamp,
                generation: generation,
                width: width,
                height: height
            )
            asyncFlowProvider.submitIfNeeded(
                key: key,
                previous: previous.pixelBuffer,
                current: currentPixelBuffer
            )
        }

        private func processTemporalOnQueue(
            previous: PreviousVideoFrameSnapshot,
            current: VideoFrameContext,
            targetFPS: InterpolationTargetFPS,
            screenMaxFPS: Int
        ) -> VideoFrameResult {
            // 每帧用 autoreleasepool 包裹:Swift + GCD queue.sync 不会自动 drain Obj-C autorelease pool,
            // Metal/Vision/VTPixelTransfer 产生的临时 IOSurface 引用会累积到 per-client 16384 配额触顶。
            autoreleasepool {
                let totalStart = DispatchTime.now().uptimeNanoseconds
                let prevTs = previous.timestamp
                let currTs = current.timestamp
                guard currTs > prevTs else {
                    return .passthrough
                }

                // 整数 timebase 源(1 tick/帧,例如 720x480 DVD 级)segmentDur=1,无法切两半插帧。
                // 输出单帧 anchor 段覆盖 [prevTs, currTs),时间线连续、降级为 1x fps,不运行 Vision/Metal。
                let segmentDur = currTs - prevTs
                guard segmentDur >= 2 else {
                    let generated: [GeneratedVideoFrame] = [
                        GeneratedVideoFrame(pixelBuffer: current.pixelBuffer, timestamp: prevTs, duration: segmentDur),
                    ]
                    return .replaceMany(generated)
                }

                let thermalState = ProcessInfo.processInfo.thermalState
                if thermalState == .critical {
                    let nowNs = DispatchTime.now().uptimeNanoseconds
                    if lastThermalWarnNs == 0 || nowNs &- lastThermalWarnNs >= 5_000_000_000 {
                        lastThermalWarnNs = nowNs
                        EnhancementTelemetryCollector.shared.recordDowngrade(
                            reason: "光流设备过热，已切直通"
                        )
                    }
                    return .passthrough
                }

                var insertedCount = PlayerEnhancementModel.resolveInterpolatedFrameCount(
                    sourceFPS: Double(current.fps),
                    target: targetFPS,
                    screenMaxFPS: screenMaxFPS,
                    maxAllowedInsertedFrames: 3,
                    thermalState: thermalState
                )
                if insertedCount == 0 {
                    return .passthrough
                }
                let maxByDuration = Int(min(Int64(insertedCount), segmentDur - 1))
                if maxByDuration < 1 {
                    return .replaceMany([
                        GeneratedVideoFrame(pixelBuffer: current.pixelBuffer, timestamp: prevTs, duration: segmentDur),
                    ])
                }
                insertedCount = maxByDuration

                let width = CVPixelBufferGetWidth(current.pixelBuffer)
                let height = CVPixelBufferGetHeight(current.pixelBuffer)
                guard width > 0, height > 0 else {
                    return .passthrough
                }

                guard let resources = ensureMetalResourcesOnQueue() else {
                    return .passthrough
                }
                let fusedPipeline = resources.fusedPipeline
                let commandQueue = resources.commandQueue
                let cache = resources.textureCache

                // 函数退出时强制 flush Metal 纹理缓存:CVMetalTextureCache 内部会按 IOSurface 缓存
                // 纹理对象,不 flush 就会留存本帧用到的输入/flow/输出 IOSurface 引用。
                defer { CVMetalTextureCacheFlush(cache, 0) }

                guard let firstBGRA = pixelBufferAsBGRA(previous.pixelBuffer, width: width, height: height),
                      let secondBGRA = pixelBufferAsBGRA(current.pixelBuffer, width: width, height: height)
                else {
                    cinemoreLog(level: .debug, "[VFI-OF] pixelBufferAsBGRA failed")
                    return .passthrough
                }

                let requestKey = OpticalFlowRequestKey(
                    previousTimestamp: prevTs,
                    currentTimestamp: currTs,
                    generation: current.generation,
                    width: width,
                    height: height
                )
                let visionStart = DispatchTime.now().uptimeNanoseconds
                let flowPair: OpticalFlowPair?
                if let cached = asyncFlowProvider.cachedResult(for: requestKey) {
                    cacheHits += 1
                    flowPair = cached
                } else {
                    cacheMisses += 1
                    flowPair = createOpticalFlowPair(source: firstBGRA, target: secondBGRA)
                }
                guard let flowPair else {
                    cinemoreLog(level: .debug, "[VFI-OF] optical flow pair unavailable")
                    return .passthrough
                }
                let visionMs = Double(DispatchTime.now().uptimeNanoseconds - visionStart) / 1_000_000

                let fwdFlowW = CVPixelBufferGetWidth(flowPair.forwardFlow)
                let fwdFlowH = CVPixelBufferGetHeight(flowPair.forwardFlow)
                let bwdFlowW = CVPixelBufferGetWidth(flowPair.backwardFlow)
                let bwdFlowH = CVPixelBufferGetHeight(flowPair.backwardFlow)
                guard fwdFlowW > 0, fwdFlowH > 0, bwdFlowW > 0, bwdFlowH > 0 else {
                    cinemoreLog(level: .debug, "[VFI-OF] invalid flow dimensions")
                    return .passthrough
                }

                let firstTex = makeTextureFromPixelBuffer(firstBGRA, textureCache: cache, width: width, height: height, pixelFormat: .bgra8Unorm)
                let secondTex = makeTextureFromPixelBuffer(secondBGRA, textureCache: cache, width: width, height: height, pixelFormat: .bgra8Unorm)
                let forwardFlowTex = makeTextureFromFlowBuffer(flowPair.forwardFlow, textureCache: cache, width: fwdFlowW, height: fwdFlowH)
                let backwardFlowTex = makeTextureFromFlowBuffer(flowPair.backwardFlow, textureCache: cache, width: bwdFlowW, height: bwdFlowH)

                guard let firstTex, let secondTex, let forwardFlowTex, let backwardFlowTex else {
                    cinemoreLog(level: .debug, "[VFI-OF] texture create failed")
                    return .passthrough
                }

                var outputs: [(CVPixelBuffer, MTLTexture)] = []
                outputs.reserveCapacity(insertedCount)
                for _ in 0..<insertedCount {
                    guard let outBuffer = ensureOutputPool(width: width, height: height) else {
                        return .passthrough
                    }
                    current.pixelBuffer.copyPropagatedAttachments(to: outBuffer)
                    guard let outTex = makeTextureFromPixelBuffer(outBuffer, textureCache: cache, width: width, height: height, pixelFormat: .bgra8Unorm) else {
                        cinemoreLog(level: .debug, "[VFI-OF] output texture create failed")
                        return .passthrough
                    }
                    outputs.append((outBuffer, outTex))
                }

                guard let cmdBuffer = commandQueue.makeCommandBuffer(),
                      let encoder = cmdBuffer.makeComputeCommandEncoder()
                else {
                    return .passthrough
                }

                encoder.setComputePipelineState(fusedPipeline)
                encoder.setTexture(firstTex, index: 0)
                encoder.setTexture(secondTex, index: 1)
                encoder.setTexture(forwardFlowTex, index: 2)
                encoder.setTexture(backwardFlowTex, index: 3)

                let tw = fusedPipeline.threadExecutionWidth
                let th = min(16, max(1, fusedPipeline.maxTotalThreadsPerThreadgroup / tw))
                let groups = MTLSize(
                    width: (width + tw - 1) / tw,
                    height: (height + th - 1) / th,
                    depth: 1
                )
                let threadsPerGroup = MTLSize(width: tw, height: th, depth: 1)

                for (idx, (_, outTex)) in outputs.enumerated() {
                    let t = Float(idx + 1) / Float(insertedCount + 1)
                    var params = OpticalFlowFusedParams(t: t, flowErrorPivot: Self.flowErrorPivot)
                    encoder.setTexture(outTex, index: 4)
                    encoder.setBytes(&params, length: MemoryLayout<OpticalFlowFusedParams>.stride, index: 0)
                    encoder.dispatchThreadgroups(groups, threadsPerThreadgroup: threadsPerGroup)
                }

                encoder.endEncoding()
                cmdBuffer.commit()
                cmdBuffer.waitUntilCompleted()
                if cmdBuffer.status != .completed {
                    cinemoreLog(level: .debug, "[VFI-OF] Metal command buffer status \(cmdBuffer.status.rawValue)")
                    return .passthrough
                }

                let durations = PlayerEnhancementModel.splitSegmentDurations(
                    totalDuration: segmentDur,
                    segmentCount: insertedCount + 1
                )
                var generated: [GeneratedVideoFrame] = []
                generated.reserveCapacity(insertedCount + 1)
                var runningTs = prevTs
                for idx in 0..<insertedCount {
                    let dur = durations[idx]
                    generated.append(
                        GeneratedVideoFrame(pixelBuffer: outputs[idx].0, timestamp: runningTs, duration: dur)
                    )
                    runningTs += dur
                }
                let lastDur = durations[insertedCount]
                generated.append(
                    GeneratedVideoFrame(pixelBuffer: current.pixelBuffer, timestamp: runningTs, duration: lastDur)
                )

                let nowNs = DispatchTime.now().uptimeNanoseconds
                if lastDiagLogNs == 0 || nowNs &- lastDiagLogNs >= 1_000_000_000 {
                    lastDiagLogNs = nowNs
                    let totalMs = Double(nowNs - totalStart) / 1_000_000
                    let metalMs = max(0, totalMs - visionMs)
                    let totalLookups = cacheHits + cacheMisses
                    let thermal = DiagnosticLogStore.currentThermalStateText()
                    cinemoreLog(
                        level: .debug,
                        "[VFI-OF] diag total=\(String(format: "%.1f", totalMs))ms vision2x=\(String(format: "%.1f", visionMs))ms metal=\(String(format: "%.1f", metalMs))ms ins=\(insertedCount) flow=\(fwdFlowW)x\(fwdFlowH) out=\(width)x\(height) hit=\(cacheHits)/\(totalLookups) thermal=\(thermal)"
                    )
                }
                return .replaceMany(generated)
            }
        }

        // MARK: - Private

        private struct MetalResources {
            let device: MTLDevice
            let library: MTLLibrary
            let fusedPipeline: MTLComputePipelineState
            let commandQueue: MTLCommandQueue
            let textureCache: CVMetalTextureCache
        }

        /// 懒加载 Metal device/library/pipeline/commandQueue/textureCache。warmup 与 processTemporalOnQueue 共用。
        private func ensureMetalResourcesOnQueue() -> MetalResources? {
            guard let dev = device ?? MTLCreateSystemDefaultDevice() else {
                cinemoreLog(level: .debug, "[VFI-OF] Metal device nil")
                return nil
            }
            if device == nil {
                device = dev
            }

            guard let lib = library ?? dev.makeDefaultLibrary() else {
                cinemoreLog(level: .debug, "[VFI-OF] Metal default library nil")
                return nil
            }
            if library == nil {
                library = lib
            }

            guard let fusedPipe = fusedPipelineState ?? makePipeline(device: dev, library: lib, function: "opticalFlowInterpolateFused") else {
                return nil
            }
            if fusedPipelineState == nil {
                fusedPipelineState = fusedPipe
            }

            guard let cmdQueue = commandQueue ?? dev.makeCommandQueue() else {
                cinemoreLog(level: .debug, "[VFI-OF] Metal command queue nil")
                return nil
            }
            if commandQueue == nil {
                commandQueue = cmdQueue
            }

            guard let cache = ensureTextureCache(device: dev) else {
                return nil
            }

            return MetalResources(
                device: dev,
                library: lib,
                fusedPipeline: fusedPipe,
                commandQueue: cmdQueue,
                textureCache: cache
            )
        }

        private func makePipeline(device: MTLDevice, library: MTLLibrary, function: String) -> MTLComputePipelineState? {
            guard let fn = library.makeFunction(name: function) else {
                cinemoreLog(level: .debug, "[VFI-OF] \(function) function not found")
                return nil
            }
            do {
                return try device.makeComputePipelineState(function: fn)
            } catch {
                cinemoreLog(level: .debug, "[VFI-OF] pipeline \(function) failed: \(error)")
                return nil
            }
        }

        private func ensureTextureCache(device: MTLDevice) -> CVMetalTextureCache? {
            if let cache = textureCache {
                return cache
            }
            var cache: CVMetalTextureCache?
            guard CVMetalTextureCacheCreate(
                kCFAllocatorDefault,
                nil,
                device,
                nil,
                &cache
            ) == kCVReturnSuccess, let cache else {
                return nil
            }
            textureCache = cache
            return cache
        }

        private func ensureOutputPool(width: Int, height: Int) -> CVPixelBuffer? {
            let key = (width, height)
            if let existingKey = outputPoolKey, existingKey == key, let pool = outputPool {
                var buf: CVPixelBuffer?
                guard CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &buf) == kCVReturnSuccess, let buf else {
                    return nil
                }
                return buf
            }
            let attrs: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA),
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
                kCVPixelBufferMetalCompatibilityKey as String: true,
                kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
            ]
            var pool: CVPixelBufferPool?
            guard CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, attrs as CFDictionary, &pool) == kCVReturnSuccess,
                  let pool
            else {
                return nil
            }
            outputPool = pool
            outputPoolKey = key
            var buf: CVPixelBuffer?
            guard CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &buf) == kCVReturnSuccess, let buf else {
                return nil
            }
            return buf
        }

        private func pixelBufferAsBGRA(_ buffer: CVPixelBuffer, width: Int, height: Int) -> CVPixelBuffer? {
            if CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_32BGRA {
                return buffer
            }
            // 通过 CVPixelBufferPool 回收 BGRA 转换缓冲:原先 CVPixelBufferCreate 每帧分 2 个 IOSurface,
            // 触达 per-client 16384 上限后解码器级联失败。池化后 IOSurface 数量与在飞数量线性相关。
            guard let outRef = ensureBGRAConversionBuffer(width: width, height: height) else {
                return nil
            }
            if let existing = pixelTransferSession {
                guard VTPixelTransferSessionTransferImage(existing, from: buffer, to: outRef) == noErr else {
                    return nil
                }
                return outRef
            }
            var newSession: VTPixelTransferSession?
            guard VTPixelTransferSessionCreate(allocator: kCFAllocatorDefault, pixelTransferSessionOut: &newSession) == noErr,
                  let newSession
            else {
                return nil
            }
            pixelTransferSession = newSession
            guard VTPixelTransferSessionTransferImage(newSession, from: buffer, to: outRef) == noErr else {
                return nil
            }
            return outRef
        }

        private func ensureBGRAConversionBuffer(width: Int, height: Int) -> CVPixelBuffer? {
            let key = (width, height)
            if let existingKey = bgraConversionPoolKey, existingKey == key, let pool = bgraConversionPool {
                var buf: CVPixelBuffer?
                guard CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &buf) == kCVReturnSuccess, let buf else {
                    return nil
                }
                return buf
            }
            let attrs: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA),
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
                kCVPixelBufferMetalCompatibilityKey as String: true,
                kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
            ]
            var pool: CVPixelBufferPool?
            guard CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, attrs as CFDictionary, &pool) == kCVReturnSuccess,
                  let pool
            else {
                return nil
            }
            bgraConversionPool = pool
            bgraConversionPoolKey = key
            var buf: CVPixelBuffer?
            guard CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &buf) == kCVReturnSuccess, let buf else {
                return nil
            }
            return buf
        }

        private func createOpticalFlowPair(
            source: CVPixelBuffer,
            target: CVPixelBuffer
        ) -> OpticalFlowPair? {
            let origW = CVPixelBufferGetWidth(source)
            let origH = CVPixelBufferGetHeight(source)
            let thermalState = ProcessInfo.processInfo.thermalState
            guard origW > 0, origH > 0,
                  let smallSrc = flowDownscaler.downscaleIfNeeded(source, thermalState: thermalState),
                  let smallDst = flowDownscaler.downscaleIfNeeded(target, thermalState: thermalState)
            else {
                cinemoreLog(level: .debug, "[VFI-OF] downscale for optical flow failed")
                return nil
            }
            guard let forwardFlow = createOpticalFlow(
                source: smallSrc,
                target: smallDst,
                originalWidth: origW,
                originalHeight: origH,
                thermalState: thermalState
            ) else {
                cinemoreLog(level: .debug, "[VFI-OF] forward flow failed")
                return nil
            }
            guard let backwardFlow = createOpticalFlow(
                source: smallDst,
                target: smallSrc,
                originalWidth: origW,
                originalHeight: origH,
                thermalState: thermalState
            ) else {
                cinemoreLog(level: .debug, "[VFI-OF] backward flow failed")
                return nil
            }
            return OpticalFlowPair(forwardFlow: forwardFlow, backwardFlow: backwardFlow)
        }

        /// 单向光流：source → target 的像素位移场（RG32Float）。
        private func createOpticalFlow(
            source: CVPixelBuffer,
            target: CVPixelBuffer,
            originalWidth: Int,
            originalHeight: Int,
            thermalState: ProcessInfo.ThermalState
        ) -> CVPixelBuffer? {
            // autoreleasepool 强制 drain Vision 内部临时 IOSurface；
            // 否则 Swift + GCD queue.sync 不会在 block 结束时 drain Obj-C autorelease pool，
            // float 光流 buffer 持续累积会触发 per-client 16384 IOSurface 配额上限。
            autoreleasepool {
                let request = VNGenerateOpticalFlowRequest(targetedCVPixelBuffer: target, orientation: .up)
                request.revision = VNGenerateOpticalFlowRequestRevision1
                let isHot = thermalState == .serious || thermalState == .critical
                #if os(iOS)
                    request.computationAccuracy = (isHot || min(originalWidth, originalHeight) > 540) ? .low : .medium
                #else
                    _ = originalWidth
                    _ = originalHeight
                    request.computationAccuracy = isHot ? .low : .medium
                #endif
                let handler = VNImageRequestHandler(cvPixelBuffer: source, options: [:])
                do {
                    try handler.perform([request])
                } catch {
                    cinemoreLog(level: .debug, "[VFI-OF] VNGenerateOpticalFlowRequest error: \(error)")
                    return nil
                }
                guard let observation = request.results?.first else {
                    return nil
                }
                return observation.pixelBuffer
            }
        }

        private func makeTextureFromPixelBuffer(
            _ buffer: CVPixelBuffer,
            textureCache: CVMetalTextureCache,
            width: Int,
            height: Int,
            pixelFormat: MTLPixelFormat
        ) -> MTLTexture? {
            var cvTex: CVMetalTexture?
            let err = CVMetalTextureCacheCreateTextureFromImage(
                kCFAllocatorDefault,
                textureCache,
                buffer,
                nil,
                pixelFormat,
                width,
                height,
                0,
                &cvTex
            )
            guard err == kCVReturnSuccess, let cvTex else {
                return nil
            }
            return CVMetalTextureGetTexture(cvTex)
        }

        private func makeTextureFromFlowBuffer(
            _ buffer: CVPixelBuffer,
            textureCache: CVMetalTextureCache,
            width: Int,
            height: Int
        ) -> MTLTexture? {
            var cvTex: CVMetalTexture?
            let err = CVMetalTextureCacheCreateTextureFromImage(
                kCFAllocatorDefault,
                textureCache,
                buffer,
                nil,
                .rg32Float,
                width,
                height,
                0,
                &cvTex
            )
            guard err == kCVReturnSuccess, let cvTex else {
                return nil
            }
            return CVMetalTextureGetTexture(cvTex)
        }
    }

    nonisolated private final class OpticalFlowTemporalProcessor: VideoFrameProcessor, @unchecked Sendable {
        private let adapter: OpticalFlowFrameInterpolationAdapter
        private let targetFPS: InterpolationTargetFPS
        private let screenMaxFPS: Int
        private let buffer = TemporalReorderBuffer()

        init(
            adapter: OpticalFlowFrameInterpolationAdapter,
            targetFPS: InterpolationTargetFPS,
            screenMaxFPS: Int
        ) {
            self.adapter = adapter
            self.targetFPS = targetFPS
            self.screenMaxFPS = screenMaxFPS
        }

        func onFrame(_ ctx: VideoFrameContext) -> VideoFrameResult {
            buffer.accept(
                ctx,
                onPrefetchNext: { [adapter] prev, next in
                    adapter.prefetchFlow(
                        previous: prev,
                        currentPixelBuffer: next.pixelBuffer,
                        currentTimestamp: next.timestamp,
                        generation: next.generation
                    )
                },
                buildSegment: { [adapter, targetFPS, screenMaxFPS] previous, current in
                    adapter.processTemporal(
                        previous: previous,
                        current: current,
                        targetFPS: targetFPS,
                        screenMaxFPS: screenMaxFPS
                    )
                }
            )
        }

        func onInvalidate(newGeneration _: Int64) {
            buffer.onInvalidate()
            adapter.resetPrefetchCache()
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

    extension OpticalFlowFrameInterpolationAdapter {
        nonisolated func makeTemporalProcessor(
            targetFPS: InterpolationTargetFPS = .doubleSource,
            screenMaxFPS: Int = 60
        ) -> any VideoFrameProcessor {
            OpticalFlowTemporalProcessor(
                adapter: self,
                targetFPS: targetFPS,
                screenMaxFPS: screenMaxFPS
            )
        }
    }
#endif
