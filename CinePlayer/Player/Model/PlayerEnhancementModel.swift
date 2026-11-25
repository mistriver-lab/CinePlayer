import Anime4KMetal
import Foundation
import SwiftUI
import Combine

#if !os(tvOS)
import CinePlayerSDK
import CoreVideo
import Metal
import os
import RifeMetal
#if canImport(UIKit)
import UIKit
#endif
#if canImport(MetalFX)
@preconcurrency import MetalFX
#endif
#if !targetEnvironment(simulator)
@preconcurrency import VideoToolbox
#endif

nonisolated struct EnhancementLiveStats: Sendable, Equatable, Codable {
    var strategy: String
    var detail: String
    var inputWidth: Int
    var inputHeight: Int
    var outputWidth: Int
    var outputHeight: Int
    var inputFrames: Int
    var outputFrames: Int
    var passthroughFrames: Int
    var replacedFrames: Int
    var bypassEvents: Int
    var timeoutEvents: Int
    var errorEvents: Int
    var measuredInputFPS: Double
    var measuredOutputFPS: Double
    var avgFrameTimeMs: Double
    var lastFrameTimeMs: Double
    var thermalState: String
    var downgradeReason: String

    var isActive: Bool {
        replacedFrames > 0
    }

    var localizedThermalText: String {
        switch thermalState {
        case "nominal": "正常"
        case "fair": "温热"
        case "serious": "偏热"
        case "critical": "过热"
        default: thermalState
        }
    }

    var localizedStrategyText: String {
        let base: String
        switch strategy {
        case "off": base = "关闭"
        case "rife": base = "RIFE 补帧"
        case "opticalFlow": base = "光流补帧"
        case "anime4k": base = "Anime4K 超分"
        case "metalFX": base = "MetalFX 超分"
        case "systemML-sr", "systemMLSR": base = "系统超分"
        case "systemML-fi", "systemMLFI": base = "系统补帧"
        default: base = strategy
        }
        guard !detail.isEmpty else { return base }
        let localizedDetail: String
        switch detail {
        case "hq": localizedDetail = "HQ"
        case "balanced": localizedDetail = "Balanced"
        case "fast": localizedDetail = "Fast"
        case "out-of-range": localizedDetail = "超出范围"
        case "init-failed": localizedDetail = "初始化失败"
        case "sim-unsupported": localizedDetail = "模拟器不支持"
        case "unsupported": localizedDetail = "设备不支持"
        default: localizedDetail = detail
        }
        return "\(base) (\(localizedDetail))"
    }

    static let idle = EnhancementLiveStats(
        strategy: "off",
        detail: "",
        inputWidth: 0,
        inputHeight: 0,
        outputWidth: 0,
        outputHeight: 0,
        inputFrames: 0,
        outputFrames: 0,
        passthroughFrames: 0,
        replacedFrames: 0,
        bypassEvents: 0,
        timeoutEvents: 0,
        errorEvents: 0,
        measuredInputFPS: 0,
        measuredOutputFPS: 0,
        avgFrameTimeMs: 0,
        lastFrameTimeMs: 0,
        thermalState: "nominal",
        downgradeReason: ""
    )
}

nonisolated final class EnhancementTelemetryCollector: @unchecked Sendable {
    static let shared = EnhancementTelemetryCollector()

    private let lock = NSLock()
    private let logger = Logger(subsystem: "com.glassmpv.cine", category: "EnhancementTelemetry")
    private var stats: EnhancementLiveStats = .idle
    private var totalFrameTimeMs: Double = 0
    private var lastPublishUptimeNs: UInt64 = 0
    private var windowStartUptimeNs: UInt64 = 0
    private var windowInputFrames: Int = 0
    private var windowOutputFrames: Int = 0
    private var lastInputFPS: Double = 0
    private var lastOutputFPS: Double = 0

    private init() {}

    func reset(strategy: String, detail: String) {
        lock.lock()
        var fresh = EnhancementLiveStats.idle
        fresh.strategy = strategy
        fresh.detail = detail
        fresh.thermalState = DiagnosticLogStore.currentThermalStateText()
        fresh.downgradeReason = ""
        stats = fresh
        totalFrameTimeMs = 0
        lastPublishUptimeNs = 0
        windowStartUptimeNs = 0
        windowInputFrames = 0
        windowOutputFrames = 0
        lastInputFPS = 0
        lastOutputFPS = 0
        let snapshot = stats
        lock.unlock()

        publish(snapshot)
    }

    func recordFrame(
        inputWidth: Int,
        inputHeight: Int,
        outputWidth: Int,
        outputHeight: Int,
        emittedCount: Int,
        didReplace: Bool,
        elapsedMs: Double
    ) {
        let nowNs = DispatchTime.now().uptimeNanoseconds

        lock.lock()
        stats.inputWidth = inputWidth
        stats.inputHeight = inputHeight
        stats.outputWidth = outputWidth
        stats.outputHeight = outputHeight
        stats.inputFrames += 1
        stats.outputFrames += emittedCount
        if didReplace {
            stats.replacedFrames += 1
        } else if emittedCount > 0 {
            stats.passthroughFrames += 1
        }
        stats.lastFrameTimeMs = elapsedMs
        totalFrameTimeMs += elapsedMs
        stats.avgFrameTimeMs = totalFrameTimeMs / Double(max(1, stats.inputFrames))

        if windowStartUptimeNs == 0 {
            windowStartUptimeNs = nowNs
        }
        windowInputFrames += 1
        windowOutputFrames += emittedCount
        let windowElapsedSec = Double(nowNs - windowStartUptimeNs) / 1_000_000_000.0
        if windowElapsedSec >= 0.5 {
            lastInputFPS = Double(windowInputFrames) / windowElapsedSec
            lastOutputFPS = Double(windowOutputFrames) / windowElapsedSec
            if windowElapsedSec >= 2.0 {
                windowStartUptimeNs = nowNs
                windowInputFrames = 0
                windowOutputFrames = 0
            }
        }
        stats.measuredInputFPS = lastInputFPS
        stats.measuredOutputFPS = lastOutputFPS

        let shouldPublish = lastPublishUptimeNs == 0 || (nowNs - lastPublishUptimeNs) >= 1_000_000_000
        let snapshot: EnhancementLiveStats?
        if shouldPublish {
            stats.thermalState = DiagnosticLogStore.currentThermalStateText()
            lastPublishUptimeNs = nowNs
            snapshot = stats
        } else {
            snapshot = nil
        }
        lock.unlock()

        if let snapshot {
            publish(snapshot)
        }
    }

    func recordEvent(_ event: FrameCallbackEvent) {
        var warnSummary: String?
        lock.lock()
        switch event {
        case .callbackTimeout:
            stats.timeoutEvents += 1
            warnSummary = describeEvent(event)
        case .callbackInvalidResult, .callbackError:
            stats.errorEvents += 1
            warnSummary = describeEvent(event)
        case .bypassStarted:
            stats.bypassEvents += 1
            warnSummary = describeEvent(event)
        case .bypassEnded, .warmupReady:
            break
        @unknown default:
            break
        }
        stats.thermalState = DiagnosticLogStore.currentThermalStateText()
        let snapshot = stats
        lastPublishUptimeNs = DispatchTime.now().uptimeNanoseconds
        lock.unlock()

        if let warnSummary {
            cinemoreLog(
                level: .warning,
                "[EnhancementEvent] \(warnSummary) strategy=\(snapshot.strategy) timeouts=\(snapshot.timeoutEvents) bypass=\(snapshot.bypassEvents)"
            )
        }
        publish(snapshot)
    }

    func recordDowngrade(reason: String, detail: String? = nil) {
        lock.lock()
        stats.downgradeReason = reason
        if let detail {
            stats.detail = detail
        }
        stats.thermalState = DiagnosticLogStore.currentThermalStateText()
        let snapshot = stats
        lastPublishUptimeNs = DispatchTime.now().uptimeNanoseconds
        lock.unlock()

        cinemoreLog(level: .warning, "[EnhancementGuard] \(reason)")
        publish(snapshot)
    }

    private func describeEvent(_ event: FrameCallbackEvent) -> String {
        switch event {
        case let .callbackTimeout(kind, elapsedMs):
            return "callbackTimeout(\(kind.rawValue), \(String(format: "%.1f", elapsedMs))ms)"
        case let .callbackInvalidResult(kind, message):
            return "callbackInvalidResult(\(kind.rawValue), \(message))"
        case let .callbackError(kind, message):
            return "callbackError(\(kind.rawValue), \(message))"
        case let .bypassStarted(kind):
            return "bypassStarted(\(kind.rawValue))"
        case let .bypassEnded(kind):
            return "bypassEnded(\(kind.rawValue))"
        case let .warmupReady(kind, elapsedMs):
            return "warmupReady(\(kind.rawValue), \(String(format: "%.1f", elapsedMs))ms)"
        @unknown default:
            return "unknown"
        }
    }

    func flush() {
        lock.lock()
        stats.thermalState = DiagnosticLogStore.currentThermalStateText()
        let snapshot = stats
        lastPublishUptimeNs = DispatchTime.now().uptimeNanoseconds
        lock.unlock()

        publish(snapshot)
    }

    private func publish(_ snapshot: EnhancementLiveStats) {
        Task { @MainActor in
            PlayerEnhancementModel.shared.liveStats = snapshot
        }

        let inFPS = String(format: "%.1f", snapshot.measuredInputFPS)
        let outFPS = String(format: "%.1f", snapshot.measuredOutputFPS)
        let avgMs = String(format: "%.2f", snapshot.avgFrameTimeMs)
        logger.notice(
            "[EnhancementStats] strategy=\(snapshot.strategy, privacy: .public) detail=\(snapshot.detail, privacy: .public) in=\(snapshot.inputWidth)x\(snapshot.inputHeight) out=\(snapshot.outputWidth)x\(snapshot.outputHeight) inFPS=\(inFPS, privacy: .public) outFPS=\(outFPS, privacy: .public) avgMs=\(avgMs, privacy: .public) inFrames=\(snapshot.inputFrames) outFrames=\(snapshot.outputFrames) replaced=\(snapshot.replacedFrames) passthrough=\(snapshot.passthroughFrames) bypass=\(snapshot.bypassEvents) timeout=\(snapshot.timeoutEvents) thermal=\(snapshot.thermalState, privacy: .public)"
        )

        #if DEBUG
        if let tag = UserDefaults.standard.string(forKey: "smokeTag"),
           !tag.isEmpty,
           let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        {
            let safeTag = tag.replacingOccurrences(of: "/", with: "_")
            let fileURL = docs.appendingPathComponent("smoke-telemetry-\(safeTag).json")
            if let data = try? JSONEncoder().encode(snapshot) {
                try? data.write(to: fileURL, options: .atomic)
            }
        }
        #endif
    }
}

nonisolated final class InstrumentedVideoFrameProcessor: VideoFrameProcessor, @unchecked Sendable {
    private let inner: any VideoFrameProcessor
    private let collector: EnhancementTelemetryCollector

    init(
        inner: any VideoFrameProcessor,
        collector: EnhancementTelemetryCollector = .shared
    ) {
        self.inner = inner
        self.collector = collector
    }

    func onFrame(_ ctx: VideoFrameContext) -> VideoFrameResult {
        let startNs = DispatchTime.now().uptimeNanoseconds
        let result = inner.onFrame(ctx)
        let elapsedMs = Double(DispatchTime.now().uptimeNanoseconds - startNs) / 1_000_000.0

        let inW = CVPixelBufferGetWidth(ctx.pixelBuffer)
        let inH = CVPixelBufferGetHeight(ctx.pixelBuffer)

        switch result {
        case .passthrough:
            collector.recordFrame(
                inputWidth: inW,
                inputHeight: inH,
                outputWidth: inW,
                outputHeight: inH,
                emittedCount: 1,
                didReplace: false,
                elapsedMs: elapsedMs
            )
        case let .replace(pb):
            let outW = CVPixelBufferGetWidth(pb)
            let outH = CVPixelBufferGetHeight(pb)
            collector.recordFrame(
                inputWidth: inW,
                inputHeight: inH,
                outputWidth: outW,
                outputHeight: outH,
                emittedCount: 1,
                didReplace: pb !== ctx.pixelBuffer,
                elapsedMs: elapsedMs
            )
        case let .replaceMany(frames):
            let firstPB = frames.first?.pixelBuffer
            let outW = firstPB.map { CVPixelBufferGetWidth($0) } ?? inW
            let outH = firstPB.map { CVPixelBufferGetHeight($0) } ?? inH
            let didReplace = frames.count > 1
                || (firstPB.map {
                    CVPixelBufferGetWidth($0) != inW || CVPixelBufferGetHeight($0) != inH
                } ?? false)
            collector.recordFrame(
                inputWidth: inW,
                inputHeight: inH,
                outputWidth: outW,
                outputHeight: outH,
                emittedCount: frames.count,
                didReplace: didReplace,
                elapsedMs: elapsedMs
            )
        @unknown default:
            collector.recordFrame(
                inputWidth: inW,
                inputHeight: inH,
                outputWidth: inW,
                outputHeight: inH,
                emittedCount: 1,
                didReplace: false,
                elapsedMs: elapsedMs
            )
        }

        return result
    }

    func onInvalidate(newGeneration: Int64) {
        inner.onInvalidate(newGeneration: newGeneration)
        collector.flush()
    }

    func drainPendingFrames() -> [GeneratedVideoFrame] {
        inner.drainPendingFrames()
    }

    func onDrain() {
        inner.onDrain()
        collector.flush()
    }

    var hasPendingFrames: Bool {
        inner.hasPendingFrames
    }
}

nonisolated enum VideoEnhancementStrategy: String, CaseIterable, Identifiable {
    case off
    case anime4k
    case systemML
    case opticalFlow
    case rife
    case metalFX

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .off: "关闭"
        case .anime4k: "Anime4K"
        case .systemML: "系统 VT"
        case .opticalFlow: "光流补帧"
        case .rife: "RIFE 补帧"
        case .metalFX: "MetalFX 超分"
        }
    }
}

nonisolated enum RifeTierPreference: String, CaseIterable, Identifiable {
    case auto
    case hq
    case balanced
    case fast

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .auto: "自动"
        case .hq: "HQ"
        case .balanced: "Balanced"
        case .fast: "Fast"
        }
    }
}

nonisolated enum Anime4KOutputResolution: String, CaseIterable, Identifiable {
    case resolution2K = "2K"
    case resolution4K = "4K"

    var id: String { rawValue }

    var displayName: String { rawValue }

    var maxWidth: Int {
        switch self {
        case .resolution2K: 2560
        case .resolution4K: 3840
        }
    }

    var maxHeight: Int {
        switch self {
        case .resolution2K: 1440
        case .resolution4K: 2160
        }
    }
}

nonisolated enum MetalFXOutputResolution: String, CaseIterable, Identifiable {
    case resolution2K = "2K"
    case resolution4K = "4K"

    var id: String { rawValue }

    var displayName: String { rawValue }

    var maxWidth: Int {
        switch self {
        case .resolution2K: 2560
        case .resolution4K: 3840
        }
    }

    var maxHeight: Int {
        switch self {
        case .resolution2K: 1440
        case .resolution4K: 2160
        }
    }
}

nonisolated enum InterpolationTargetFPS: String, CaseIterable, Identifiable, Sendable {
    case doubleSource = "2x"
    case fps60 = "60"
    case fps120 = "120"
    case matchScreen = "screen"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .doubleSource: "原帧 2×"
        case .fps60: "60 fps"
        case .fps120: "120 fps"
        case .matchScreen: "匹配屏幕刷新率"
        }
    }

    func shortDetail(screenMaxFPS: Int) -> String {
        switch self {
        case .doubleSource: "2x"
        case .fps60: "60fps"
        case .fps120: "120fps"
        case .matchScreen: "\(max(60, screenMaxFPS))fps"
        }
    }

    func resolvedTargetFPS(screenMaxFPS: Int) -> Double? {
        switch self {
        case .doubleSource: nil
        case .fps60: 60.0
        case .fps120: 120.0
        case .matchScreen: Double(max(60, screenMaxFPS))
        }
    }
}

@MainActor
final class PlayerEnhancementModel: ObservableObject {
    static let shared = PlayerEnhancementModel()

    var onRuntimeConfigChanged: ((Bool) -> Void)?
    var onDynamicRangeReloadRequested: (() -> Void)?
    private var suppressRuntimeCallback = true

    private init() {
        videoEnhancementStrategy = Self.loadVideoEnhancementStrategy()
        systemMLSuperResolutionEnabled = Self.loadBool(
            forKey: StorageKey.systemMLSuperResolutionEnabled,
            defaultValue: true
        )
        let storedScale = Self.loadDouble(
            forKey: StorageKey.systemMLSuperResolutionScale,
            defaultValue: 2.0
        )
        systemMLSuperResolutionScale = Self.systemMLSupportedScaleFactors.min(by: {
            abs($0 - storedScale) < abs($1 - storedScale)
        }) ?? 2.0
        systemMLFrameInterpolationEnabled = Self.loadBool(
            forKey: StorageKey.systemMLFrameInterpolationEnabled,
            defaultValue: false
        )
        systemMLInterpolatedFrames = max(1, min(3, Self.loadInt(
            forKey: StorageKey.systemMLInterpolatedFrames,
            defaultValue: 1
        )))
        systemMLABCompare = Self.loadBool(
            forKey: StorageKey.systemMLABCompare,
            defaultValue: false
        )
        metalFXSuperResolutionEnabled = Self.loadBool(
            forKey: StorageKey.metalFXSuperResolutionEnabled,
            defaultValue: false
        )
        metalFXOutputResolution = Self.loadMetalFXOutputResolution()
        metalFXABCompare = Self.loadBool(
            forKey: StorageKey.metalFXABCompare,
            defaultValue: false
        )
        rifeTierPreference = Self.loadRifeTierPreference()
        forceSDRForEnhancement = Self.loadBool(
            forKey: StorageKey.forceSDRForEnhancement,
            defaultValue: false
        )
        interpolationTargetFPS = Self.loadInterpolationTargetFPS()
        suppressRuntimeCallback = false
    }

    @Published var anime4kSectionVisible: Bool = false
    @Published var opticalFlowSectionVisible: Bool = false
    @Published var metalFXSectionVisible: Bool = false
    @Published var rifeSectionVisible: Bool = false
    @Published var currentVideoIsHDR: Bool = false
    @Published var currentVideoIsDolbyVision: Bool = false
    @Published var currentVideoNominalFPS: Double = 0
    @Published var forceSDRForEnhancement: Bool = false {
        didSet {
            UserDefaults.standard.set(
                forceSDRForEnhancement,
                forKey: StorageKey.forceSDRForEnhancement
            )
            if let width = systemMLCurrentVideoWidth,
               let height = systemMLCurrentVideoHeight,
               width > 0, height > 0
            {
                rifeSectionVisible = (!currentVideoIsHDR || forceSDRForEnhancement)
                    && Self.isVideoResolutionInRifeRange(width: width, height: height)
                let clamped = clampStrategyToAvailability(videoEnhancementStrategy)
                if clamped != videoEnhancementStrategy {
                    let prev = suppressRuntimeCallback
                    suppressRuntimeCallback = true
                    videoEnhancementStrategy = clamped
                    suppressRuntimeCallback = prev
                }
            }
            if !suppressRuntimeCallback {
                onDynamicRangeReloadRequested?()
            }
        }
    }
    @Published var interpolationTargetFPS: InterpolationTargetFPS = .doubleSource {
        didSet {
            UserDefaults.standard.set(
                interpolationTargetFPS.rawValue,
                forKey: StorageKey.interpolationTargetFPS
            )
            notifyRuntimeConfigChanged(resetPipeline: true)
        }
    }
    @Published var liveStats: EnhancementLiveStats = .idle
    @Published var rifeTierPreference: RifeTierPreference = .auto {
        didSet {
            UserDefaults.standard.set(
                rifeTierPreference.rawValue,
                forKey: StorageKey.rifeTierPreference
            )
            // Tier change requires graph rebuild; resetPipeline: true triggers that.
            notifyRuntimeConfigChanged(resetPipeline: true)
        }
    }
    @Published var anime4kEnabled: Bool = false {
        didSet { notifyRuntimeConfigChanged(resetPipeline: false) }
    }
    @Published var anime4kPreset: Anime4KPreset = .modeAFast {
        didSet { notifyRuntimeConfigChanged(resetPipeline: false) }
    }
    @Published var anime4kOutputResolution: Anime4KOutputResolution = .resolution2K {
        didSet { notifyRuntimeConfigChanged(resetPipeline: true) }
    }
    @Published var anime4kABCompare: Bool = false {
        didSet { notifyRuntimeConfigChanged(resetPipeline: false) }
    }

    @Published var videoEnhancementStrategy: VideoEnhancementStrategy = .off {
        didSet {
            let clamped = clampStrategyToAvailability(videoEnhancementStrategy)
            if clamped != videoEnhancementStrategy {
                videoEnhancementStrategy = clamped
                return
            }
            UserDefaults.standard.set(
                videoEnhancementStrategy.rawValue,
                forKey: StorageKey.videoEnhancementStrategy
            )
            applyMutualExclusion(for: videoEnhancementStrategy)
            notifyRuntimeConfigChanged(resetPipeline: true)
        }
    }

    @Published var systemMLSuperResolutionEnabled: Bool = true {
        didSet {
            if systemMLSuperResolutionEnabled, !systemMLSuperResolutionSupported {
                systemMLSuperResolutionEnabled = false
                return
            }
            if systemMLSuperResolutionEnabled, systemMLFrameInterpolationEnabled {
                systemMLFrameInterpolationEnabled = false
            }
            UserDefaults.standard.set(
                systemMLSuperResolutionEnabled,
                forKey: StorageKey.systemMLSuperResolutionEnabled
            )
            notifyRuntimeConfigChanged(resetPipeline: false)
        }
    }

    @Published var systemMLSuperResolutionScale: Double = 2.0 {
        didSet {
            let supported = Self.systemMLSupportedScaleFactors(
                forWidth: systemMLCurrentVideoWidth,
                height: systemMLCurrentVideoHeight
            )
            if supported.contains(where: { abs($0 - systemMLSuperResolutionScale) < 0.001 }) {
                UserDefaults.standard.set(
                    systemMLSuperResolutionScale,
                    forKey: StorageKey.systemMLSuperResolutionScale
                )
                notifyRuntimeConfigChanged(resetPipeline: false)
            } else if let nearest = supported.min(by: {
                abs($0 - systemMLSuperResolutionScale) < abs($1 - systemMLSuperResolutionScale)
            }) {
                systemMLSuperResolutionScale = nearest
            }
        }
    }

    @Published var systemMLFrameInterpolationEnabled: Bool = false {
        didSet {
            if systemMLFrameInterpolationEnabled, !systemMLFrameInterpolationSupported {
                systemMLFrameInterpolationEnabled = false
                return
            }
            if systemMLFrameInterpolationEnabled, systemMLSuperResolutionEnabled {
                systemMLSuperResolutionEnabled = false
            }
            UserDefaults.standard.set(
                systemMLFrameInterpolationEnabled,
                forKey: StorageKey.systemMLFrameInterpolationEnabled
            )
            notifyRuntimeConfigChanged(resetPipeline: false)
        }
    }

    @Published var systemMLInterpolatedFrames: Int = 1 {
        didSet {
            let clamped = max(1, min(3, systemMLInterpolatedFrames))
            if clamped != systemMLInterpolatedFrames {
                systemMLInterpolatedFrames = clamped
                return
            }
            UserDefaults.standard.set(
                systemMLInterpolatedFrames,
                forKey: StorageKey.systemMLInterpolatedFrames
            )
            notifyRuntimeConfigChanged(resetPipeline: false)
        }
    }

    @Published var systemMLABCompare: Bool = false {
        didSet {
            UserDefaults.standard.set(systemMLABCompare, forKey: StorageKey.systemMLABCompare)
            notifyRuntimeConfigChanged(resetPipeline: false)
        }
    }

    @Published var metalFXSuperResolutionEnabled: Bool = false {
        didSet {
            if metalFXSuperResolutionEnabled, !metalFXSuperResolutionSupported {
                metalFXSuperResolutionEnabled = false
                return
            }
            UserDefaults.standard.set(
                metalFXSuperResolutionEnabled,
                forKey: StorageKey.metalFXSuperResolutionEnabled
            )
            notifyRuntimeConfigChanged(resetPipeline: false)
        }
    }

    @Published var metalFXOutputResolution: MetalFXOutputResolution = .resolution2K {
        didSet {
            let supported = metalFXSupportedOutputResolutionsForCurrentVideo
            if supported.isEmpty || supported.contains(metalFXOutputResolution) {
                UserDefaults.standard.set(
                    metalFXOutputResolution.rawValue,
                    forKey: StorageKey.metalFXOutputResolution
                )
                notifyRuntimeConfigChanged(resetPipeline: true)
            } else if let fallback = supported.first {
                metalFXOutputResolution = fallback
            }
        }
    }

    @Published var metalFXABCompare: Bool = false {
        didSet {
            UserDefaults.standard.set(metalFXABCompare, forKey: StorageKey.metalFXABCompare)
            notifyRuntimeConfigChanged(resetPipeline: false)
        }
    }

    var systemMLFrameInterpolationSupported: Bool {
        #if targetEnvironment(simulator)
        return false
        #else
        if #available(iOS 26.0, macOS 26.0, tvOS 26.0, visionOS 26.0, *) {
            return VTLowLatencyFrameInterpolationConfiguration.isSupported
        }
        return false
        #endif
    }

    var systemMLSuperResolutionSupported: Bool {
        #if targetEnvironment(simulator)
        return false
        #else
        if #available(iOS 26.0, macOS 26.0, tvOS 26.0, visionOS 26.0, *) {
            return VTLowLatencySuperResolutionScalerConfiguration.isSupported
        }
        return false
        #endif
    }

    var systemMLEnhancementSupported: Bool {
        systemMLFrameInterpolationSupported || systemMLSuperResolutionSupported
    }

    var metalFXSuperResolutionSupported: Bool {
        #if canImport(MetalFX)
        guard #available(iOS 16.0, macOS 13.0, *) else {
            return false
        }
        guard let device = MTLCreateSystemDefaultDevice() else {
            return false
        }
        return MTLFXSpatialScalerDescriptor.supportsDevice(device)
        #else
        return false
        #endif
    }

    @Published var systemMLCurrentVideoInRange: Bool = false
    @Published var systemMLCurrentVideoWidth: Int?
    @Published var systemMLCurrentVideoHeight: Int?

    var systemMLCurrentVideoSupportsFrameInterpolation: Bool {
        guard let width = systemMLCurrentVideoWidth,
              let height = systemMLCurrentVideoHeight
        else {
            return false
        }
        return Self.isVideoResolutionInVTFrameInterpolationRange(width: width, height: height)
    }

    var systemMLCurrentVideoSupportsSuperResolution: Bool {
        guard let width = systemMLCurrentVideoWidth,
              let height = systemMLCurrentVideoHeight
        else {
            return false
        }
        return Self.isVideoResolutionInVTSuperResolutionRange(width: width, height: height)
    }

    var systemMLSupportedScaleFactorsForPicker: [Double] {
        Self.systemMLSupportedScaleFactors(
            forWidth: systemMLCurrentVideoWidth,
            height: systemMLCurrentVideoHeight
        )
    }

    var metalFXSupportedOutputResolutionsForCurrentVideo: [MetalFXOutputResolution] {
        Self.metalFXSupportedOutputResolutions(
            forWidth: systemMLCurrentVideoWidth,
            height: systemMLCurrentVideoHeight
        )
    }

    var currentScreenMaxFPS: Int {
        #if os(iOS)
        return UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first?
            .screen
            .maximumFramesPerSecond ?? 60
        #else
        return 120
        #endif
    }

    var resolvedSystemMLInterpolatedFrames: Int {
        let count = Self.resolveInterpolatedFrameCount(
            sourceFPS: currentVideoNominalFPS,
            target: interpolationTargetFPS,
            screenMaxFPS: currentScreenMaxFPS,
            maxAllowedInsertedFrames: 3
        )
        return max(1, count)
    }

    func updateAvailabilityForCurrentVideo(
        width: Int?,
        height: Int?,
        isHDR: Bool = false,
        isDolbyVision: Bool = false,
        nominalFPS: Double = 0
    ) {
        guard let width, let height, width > 0, height > 0 else {
            anime4kSectionVisible = false
            opticalFlowSectionVisible = false
            metalFXSectionVisible = false
            rifeSectionVisible = false
            currentVideoIsHDR = false
            currentVideoIsDolbyVision = false
            currentVideoNominalFPS = 0
            systemMLCurrentVideoInRange = false
            setSystemMLCurrentVideoDimensions(width: nil, height: nil)
            if videoEnhancementStrategy != .off {
                videoEnhancementStrategy = .off
            }
            return
        }

        currentVideoIsHDR = isHDR
        currentVideoIsDolbyVision = isDolbyVision
        currentVideoNominalFPS = nominalFPS
        anime4kSectionVisible = Self.isVideoPixelCountInAnime4KRange(width: width, height: height)
        opticalFlowSectionVisible = Self.isVideoResolutionInOpticalFlowRange(width: width, height: height)
        systemMLCurrentVideoInRange = Self.isVideoResolutionInSystemMLRange(width: width, height: height)
        setSystemMLCurrentVideoDimensions(width: width, height: height)
        metalFXSectionVisible =
            metalFXSuperResolutionSupported
            && Self.isVideoResolutionInMetalFXRange(width: width, height: height)
        // RIFE pipeline is BGRA8 end-to-end; HDR sources require forced SDR reload
        // before RIFE can run without losing dynamic range unexpectedly.
        rifeSectionVisible = (!isHDR || forceSDRForEnhancement)
            && Self.isVideoResolutionInRifeRange(width: width, height: height)
        clampMetalFXOutputResolutionToCurrentVideoIfNeeded()

        let clamped = clampStrategyToAvailability(videoEnhancementStrategy)
        if clamped != videoEnhancementStrategy {
            videoEnhancementStrategy = clamped
        }
    }

    func setStrategy(_ strategy: VideoEnhancementStrategy) {
        let prev = suppressRuntimeCallback
        suppressRuntimeCallback = true
        videoEnhancementStrategy = strategy
        suppressRuntimeCallback = prev
        notifyRuntimeConfigChanged(resetPipeline: true)
    }

    func setSystemMLEnhancement(superResolution: Bool? = nil, frameInterpolation: Bool? = nil) {
        let prev = suppressRuntimeCallback
        suppressRuntimeCallback = true
        if let superResolution {
            systemMLSuperResolutionEnabled = superResolution
            if superResolution {
                systemMLFrameInterpolationEnabled = false
            }
        }
        if let frameInterpolation {
            systemMLFrameInterpolationEnabled = frameInterpolation
            if frameInterpolation {
                systemMLSuperResolutionEnabled = false
            }
        }
        if systemMLSuperResolutionEnabled || systemMLFrameInterpolationEnabled {
            videoEnhancementStrategy = .systemML
        } else if videoEnhancementStrategy == .systemML {
            videoEnhancementStrategy = .off
        }
        suppressRuntimeCallback = prev
        notifyRuntimeConfigChanged(resetPipeline: true)
    }

    func setSystemMLCurrentVideoDimensions(width: Int?, height: Int?) {
        systemMLCurrentVideoWidth = width
        systemMLCurrentVideoHeight = height
        let supported = Self.systemMLSupportedScaleFactors(forWidth: width, height: height)
        if !supported.contains(where: { abs($0 - systemMLSuperResolutionScale) < 0.001 }),
           let nearest = supported.min(by: {
               abs($0 - systemMLSuperResolutionScale) < abs($1 - systemMLSuperResolutionScale)
           })
        {
            systemMLSuperResolutionScale = nearest
        }
    }

    func resetVideoEnhancementForNewVideoSession() {
        let previousSuppressState = suppressRuntimeCallback
        suppressRuntimeCallback = true
        defer { suppressRuntimeCallback = previousSuppressState }

        anime4kSectionVisible = false
        systemMLCurrentVideoInRange = false
        opticalFlowSectionVisible = false
        metalFXSectionVisible = false
        rifeSectionVisible = false
        currentVideoIsHDR = false
        currentVideoIsDolbyVision = false
        currentVideoNominalFPS = 0
        currentRifeTier = nil
        systemMLCurrentVideoWidth = nil
        systemMLCurrentVideoHeight = nil

        anime4kABCompare = false
        anime4kPreset = .modeAFast
        anime4kOutputResolution = .resolution2K

        systemMLABCompare = false
        systemMLInterpolatedFrames = 1
        metalFXOutputResolution = .resolution2K
        metalFXABCompare = false

        videoEnhancementStrategy = .off
        liveStats = .idle
        EnhancementTelemetryCollector.shared.reset(strategy: "off", detail: "")
    }

    static let anime4KMaxInputPixels: Int = 1920 * 1080

    static func isVideoPixelCountInAnime4KRange(width: Int, height: Int) -> Bool {
        guard width > 0, height > 0 else {
            return false
        }
        return width * height <= anime4KMaxInputPixels
    }

    nonisolated static func resolveInterpolatedFrameCount(
        sourceFPS: Double,
        target: InterpolationTargetFPS,
        screenMaxFPS: Int,
        maxAllowedInsertedFrames: Int,
        thermalState: ProcessInfo.ThermalState = ProcessInfo.processInfo.thermalState
    ) -> Int {
        guard maxAllowedInsertedFrames > 0 else { return 0 }
        if thermalState == .critical {
            return 0
        }
        let thermalCap: Int
        switch thermalState {
        case .serious:
            thermalCap = 1
        case .fair:
            thermalCap = min(maxAllowedInsertedFrames, 2)
        default:
            thermalCap = maxAllowedInsertedFrames
        }

        if target == .doubleSource {
            return min(thermalCap, 1)
        }
        let desiredFPS = target.resolvedTargetFPS(screenMaxFPS: screenMaxFPS) ?? 60.0
        if sourceFPS <= 0.5 {
            return min(thermalCap, 1)
        }
        if sourceFPS >= desiredFPS - 1.0 {
            return 0
        }
        let multiplier = Int(ceil(desiredFPS / sourceFPS))
        let needed = max(1, multiplier - 1)
        return min(thermalCap, needed)
    }

    nonisolated static func splitSegmentDurations(totalDuration: Int64, segmentCount: Int) -> [Int64] {
        guard segmentCount > 0 else { return [] }
        let count64 = Int64(segmentCount)
        let base = totalDuration / count64
        let rem = Int(totalDuration % count64)
        var result: [Int64] = []
        result.reserveCapacity(segmentCount)
        for idx in 0..<segmentCount {
            result.append(base + (idx < rem ? 1 : 0))
        }
        return result
    }

    static func isVideoResolutionInOpticalFlowRange(width: Int, height: Int) -> Bool {
        guard width > 0, height > 0 else {
            return false
        }
        return width <= 1920 && height <= 1080
    }

    static func isVideoResolutionInRifeRange(width: Int, height: Int) -> Bool {
        guard width > 0, height > 0 else { return false }
        return width * height <= 3840 * 2160
    }

    static func isVideoResolutionInMetalFXRange(width: Int, height: Int) -> Bool {
        guard width > 0, height > 0 else {
            return false
        }
        return !metalFXSupportedOutputResolutions(forWidth: width, height: height).isEmpty
    }

    static func isVideoResolutionInSystemMLRange(width: Int, height: Int) -> Bool {
        isVideoResolutionInVTFrameInterpolationRange(width: width, height: height)
            || isVideoResolutionInVTSuperResolutionRange(width: width, height: height)
    }

    static func isVideoResolutionInVTSuperResolutionRange(width: Int, height: Int) -> Bool {
        #if targetEnvironment(simulator)
        return false
        #else
        guard #available(iOS 26.0, macOS 26.0, tvOS 26.0, visionOS 26.0, *) else {
            return false
        }
        guard let minDim = VTLowLatencySuperResolutionScalerConfiguration.minimumDimensions,
              let maxDim = VTLowLatencySuperResolutionScalerConfiguration.maximumDimensions
        else {
            return false
        }
        let w = Int32(width)
        let h = Int32(height)
        return w >= minDim.width && h >= minDim.height && w <= maxDim.width && h <= maxDim.height
        #endif
    }

    static func isVideoResolutionInVTFrameInterpolationRange(width: Int, height: Int) -> Bool {
        #if targetEnvironment(simulator)
        return false
        #else
        guard #available(iOS 26.0, macOS 26.0, tvOS 26.0, visionOS 26.0, *) else {
            return false
        }
        guard VTLowLatencyFrameInterpolationConfiguration.isSupported else {
            return false
        }
        return width > 0 && height > 0
        #endif
    }

    static var systemMLSupportedScaleFactors: [Double] {
        systemMLSupportedScaleFactors(forWidth: nil, height: nil)
    }

    static func metalFXResolvedOutputSize(
        width: Int,
        height: Int,
        targetResolution: MetalFXOutputResolution
    ) -> (width: Int, height: Int) {
        guard width > 0, height > 0 else {
            return (0, 0)
        }
        let ratio = min(
            Double(targetResolution.maxWidth) / Double(width),
            Double(targetResolution.maxHeight) / Double(height)
        )
        guard ratio > 1.0 else {
            return (width, height)
        }
        return (
            width: Int((Double(width) * ratio).rounded(.down)),
            height: Int((Double(height) * ratio).rounded(.down))
        )
    }

    static func metalFXSupportedOutputResolutions(
        forWidth width: Int?,
        height: Int?
    ) -> [MetalFXOutputResolution] {
        guard let width, let height, width > 0, height > 0 else {
            return MetalFXOutputResolution.allCases
        }
        return MetalFXOutputResolution.allCases.filter { resolution in
            let output = metalFXResolvedOutputSize(
                width: width,
                height: height,
                targetResolution: resolution
            )
            return output.width > width || output.height > height
        }
    }

    func clampMetalFXOutputResolutionToCurrentVideoIfNeeded() {
        let supported = metalFXSupportedOutputResolutionsForCurrentVideo
        guard !supported.isEmpty else {
            return
        }
        if !supported.contains(metalFXOutputResolution) {
            metalFXOutputResolution = supported.first ?? .resolution2K
        }
    }

    static func systemMLSupportedScaleFactors(forWidth width: Int?, height: Int?) -> [Double] {
        #if targetEnvironment(simulator)
        return [2.0]
        #else
        guard #available(iOS 26.0, macOS 26.0, tvOS 26.0, visionOS 26.0, *) else {
            return [2.0]
        }
        if let w = width, let h = height, w > 0, h > 0 {
            let supported = VTLowLatencySuperResolutionScalerConfiguration.supportedScaleFactors(
                frameWidth: w,
                frameHeight: h
            )
            return supported.isEmpty ? [2.0] : supported.sorted().map { Double($0) }
        }
        guard let minDim = VTLowLatencySuperResolutionScalerConfiguration.minimumDimensions,
              let maxDim = VTLowLatencySuperResolutionScalerConfiguration.maximumDimensions
        else {
            return [2.0]
        }
        let atMin = Set(
            VTLowLatencySuperResolutionScalerConfiguration.supportedScaleFactors(
                frameWidth: Int(minDim.width),
                frameHeight: Int(minDim.height)
            )
        )
        let atMax = Set(
            VTLowLatencySuperResolutionScalerConfiguration.supportedScaleFactors(
                frameWidth: Int(maxDim.width),
                frameHeight: Int(maxDim.height)
            )
        )
        let intersection = atMin.intersection(atMax).sorted()
        if intersection.isEmpty {
            return atMin.isEmpty ? [2.0] : atMin.sorted().map { Double($0) }
        }
        return intersection.map { Double($0) }
        #endif
    }

    private func notifyRuntimeConfigChanged(resetPipeline: Bool) {
        guard !suppressRuntimeCallback else {
            return
        }
        onRuntimeConfigChanged?(resetPipeline)
    }

    private enum StorageKey {
        static let videoEnhancementStrategy = "videoEnhancementStrategy"
        static let systemMLSuperResolutionEnabled = "systemMLSuperResolutionEnabled"
        static let systemMLSuperResolutionScale = "systemMLSuperResolutionScale"
        static let systemMLFrameInterpolationEnabled = "systemMLFrameInterpolationEnabled"
        static let systemMLInterpolatedFrames = "systemMLInterpolatedFrames"
        static let systemMLABCompare = "systemMLABCompare"
        static let metalFXSuperResolutionEnabled = "metalFXSuperResolutionEnabled"
        static let metalFXOutputResolution = "metalFXOutputResolution"
        static let metalFXABCompare = "metalFXABCompare"
        static let rifeTierPreference = "rifeTierPreference"
        static let forceSDRForEnhancement = "forceSDRForEnhancement"
        static let interpolationTargetFPS = "interpolationTargetFPS"
    }

    private static func loadInterpolationTargetFPS() -> InterpolationTargetFPS {
        let raw = UserDefaults.standard.string(forKey: StorageKey.interpolationTargetFPS)
        return InterpolationTargetFPS(rawValue: raw ?? InterpolationTargetFPS.doubleSource.rawValue) ?? .doubleSource
    }

    private static func loadRifeTierPreference() -> RifeTierPreference {
        let raw = UserDefaults.standard.string(forKey: StorageKey.rifeTierPreference)
        return RifeTierPreference(rawValue: raw ?? RifeTierPreference.auto.rawValue) ?? .auto
    }

    private static func loadVideoEnhancementStrategy() -> VideoEnhancementStrategy {
        let raw = UserDefaults.standard.string(forKey: StorageKey.videoEnhancementStrategy)
        let loaded =
            VideoEnhancementStrategy(rawValue: raw ?? VideoEnhancementStrategy.off.rawValue) ?? .off
        return loaded
    }

    private static func loadBool(forKey key: String, defaultValue: Bool) -> Bool {
        if let stored = UserDefaults.standard.object(forKey: key) as? Bool {
            return stored
        }
        return defaultValue
    }

    private static func loadDouble(forKey key: String, defaultValue: Double) -> Double {
        if let stored = UserDefaults.standard.object(forKey: key) as? Double {
            return stored
        }
        return defaultValue
    }

    private static func loadInt(forKey key: String, defaultValue: Int) -> Int {
        if let stored = UserDefaults.standard.object(forKey: key) as? Int {
            return stored
        }
        return defaultValue
    }

    private func clampStrategyToAvailability(_ strategy: VideoEnhancementStrategy) -> VideoEnhancementStrategy {
        switch strategy {
        case .anime4k where !anime4kSectionVisible:
            return .off
        case .systemML where !systemMLEnhancementSupported:
            return .off
        case .systemML where !systemMLCurrentVideoInRange:
            return .off
        case .opticalFlow where !opticalFlowSectionVisible:
            return .off
        case .rife where !rifeSectionVisible:
            return .off
        case .metalFX where !metalFXSectionVisible:
            return .off
        default:
            return strategy
        }
    }

    private func applyMutualExclusion(for strategy: VideoEnhancementStrategy) {
        let previousSuppress = suppressRuntimeCallback
        suppressRuntimeCallback = true
        defer { suppressRuntimeCallback = previousSuppress }

        switch strategy {
        case .anime4k:
            metalFXSuperResolutionEnabled = false
            systemMLSuperResolutionEnabled = false
            systemMLFrameInterpolationEnabled = false
            anime4kEnabled = true
        case .systemML:
            anime4kEnabled = false
            metalFXSuperResolutionEnabled = false
            if !systemMLSuperResolutionEnabled, !systemMLFrameInterpolationEnabled {
                if systemMLCurrentVideoSupportsFrameInterpolation {
                    systemMLFrameInterpolationEnabled = true
                } else if systemMLCurrentVideoSupportsSuperResolution {
                    systemMLSuperResolutionEnabled = true
                }
            }
        case .opticalFlow:
            anime4kEnabled = false
            metalFXSuperResolutionEnabled = false
            systemMLSuperResolutionEnabled = false
            systemMLFrameInterpolationEnabled = false
        case .rife:
            anime4kEnabled = false
            metalFXSuperResolutionEnabled = false
            systemMLSuperResolutionEnabled = false
            systemMLFrameInterpolationEnabled = false
        case .metalFX:
            anime4kEnabled = false
            systemMLSuperResolutionEnabled = false
            systemMLFrameInterpolationEnabled = false
            metalFXSuperResolutionEnabled = true
        case .off:
            anime4kEnabled = false
            metalFXSuperResolutionEnabled = false
            systemMLSuperResolutionEnabled = false
            systemMLFrameInterpolationEnabled = false
        }
    }

    private static func loadMetalFXOutputResolution() -> MetalFXOutputResolution {
        let raw = UserDefaults.standard.string(forKey: StorageKey.metalFXOutputResolution)
        return MetalFXOutputResolution(
            rawValue: raw ?? MetalFXOutputResolution.resolution2K.rawValue
        ) ?? .resolution2K
    }

    /// Initial tier picked from current video resolution. The adapter may downgrade
    /// at runtime if measured inference time exceeds the source-fps budget; the
    /// active tier is reflected in `currentRifeTier` (published by the adapter
    /// callback).
    var rifeAutoTier: RifeQualityTier {
        #if os(iOS)
        // iOS real-time playback always starts at `.fast` to prevent frame budget stalls.
        return .fast
        #else
        guard let w = systemMLCurrentVideoWidth,
              let h = systemMLCurrentVideoHeight else {
            return .balanced
        }
        let pixels = w * h
        // Conservative initial picks calibrated for 30 fps real-time on M-series
        // Mac. The adapter's runtime downgrade catches devices/content where these
        // are still too aggressive (e.g., M1 base, 60 fps source).
        if pixels <= 1280 * 720 { return .hq }
        else if pixels <= 2560 * 1440 { return .balanced }
        else { return .fast }
        #endif
    }

    var liveStatsSummaryText: String {
        let s = liveStats
        let detailSuffix = s.detail.isEmpty ? "" : " (\(s.detail))"
        let res = (s.inputWidth > 0 && s.outputWidth > 0)
            ? "\(s.inputWidth)x\(s.inputHeight)->\(s.outputWidth)x\(s.outputHeight)"
            : "--"
        let fpsPart = String(
            format: "%.1f->%.1f fps, avg=%.2fms, last=%.2fms",
            s.measuredInputFPS,
            s.measuredOutputFPS,
            s.avgFrameTimeMs,
            s.lastFrameTimeMs
        )
        let counts = "in=\(s.inputFrames) out=\(s.outputFrames) replaced=\(s.replacedFrames) pass=\(s.passthroughFrames) bypass=\(s.bypassEvents) timeout=\(s.timeoutEvents) error=\(s.errorEvents)"
        let guardPart = s.downgradeReason.isEmpty ? "" : " guard=\(s.downgradeReason)"
        return "strategy=\(s.strategy)\(detailSuffix) res=\(res) \(fpsPart) \(counts) thermal=\(s.thermalState)\(guardPart)"
    }

    /// Tier currently in use by the adapter. In `.auto` preference mode this
    /// mirrors the (possibly auto-downgraded) tier the adapter actually picked.
    /// In manual modes this just echoes the user's choice. `nil` until the first
    /// frame is processed.
    @Published var currentRifeTier: RifeQualityTier?

    /// Tier the adapter should start with. In `.auto` mode this is the
    /// resolution-derived `rifeAutoTier`; otherwise it's the user's explicit pick.
    var resolvedRifeTier: RifeQualityTier {
        switch rifeTierPreference {
        case .auto: return rifeAutoTier
        case .hq: return .hq
        case .balanced: return .balanced
        case .fast: return .fast
        }
    }

    /// Whether runtime auto-downgrade is allowed. Only enabled when user picks
    /// `.auto` — explicit picks are honored as-is, even if the device can't
    /// keep up.
    var rifeAdaptiveEnabled: Bool {
        rifeTierPreference == .auto
    }

    var rifeAutoTierDisplayName: String {
        let tier = currentRifeTier ?? resolvedRifeTier
        switch tier {
        case .hq: return "HQ"
        case .balanced: return "Balanced"
        case .fast: return "Fast"
        }
    }
}
#endif
