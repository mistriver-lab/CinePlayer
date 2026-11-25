import Anime4KMetal
import CinePlayerSDK
import Combine
import Foundation
import SwiftUI
#if !os(tvOS)
import RifeMetal
#endif

@MainActor
final class VideoPlayerModel: ObservableObject {
    let translationRuntime = SubtitleTranslationRuntime()
    let translationRouter: SubtitleTranslationRouter

    @Published var playerCoordinator = CinePlayer.Coordinator()
    @Published var config: CinePlayerConfig = .init()

    private(set) var sourceURL: URL?

    #if !os(tvOS)
        private var lastFrameCallbackConfigLog: String?
    #endif

    init() {
        translationRouter = SubtitleTranslationRouter(runtime: translationRuntime)

        #if !os(tvOS)
            PlayerEnhancementModel.shared.onRuntimeConfigChanged = { [weak self] resetPipeline in
                Task { @MainActor [weak self] in
                    self?.applyFrameCallbackConfigurationToActivePlayer(
                        resetPipeline: resetPipeline)
                }
            }
            PlayerEnhancementModel.shared.onDynamicRangeReloadRequested = { [weak self] in
                Task { @MainActor [weak self] in
                    self?.reloadCurrentVideoForDynamicRangeChange()
                }
            }
        #endif
    }

    func open(url: URL, startTime: TimeInterval = 0, controlConfig: PlayerControlConfig) {
        sourceURL = url
        let newConfig = CinePlayerConfig()

        #if !os(tvOS)
            PlayerEnhancementModel.shared.resetVideoEnhancementForNewVideoSession()
            newConfig.dynamicRange = PlayerEnhancementModel.shared.forceSDRForEnhancement ? .sdr : nil
        #endif

        newConfig.url = url
        newConfig.startTime = max(0, startTime)
        newConfig.autoPlay = true
        configureSubtitleTranslate(for: newConfig, mode: controlConfig.subtitleTranslateMode)
        configureFrameCallback(for: newConfig)

        // SDK 是 imperative 模型：CinePlayer.updateView 不监听 config 变化，
        // 已有 controller 时必须显式调 replace 才能切源并触发 .ready 状态流。
        // 首次播放（controller 为 nil）由 SwiftUI 的 makeView 创建 controller。
        if let controller = playerCoordinator.controller {
            newConfig.subtitleStyle = config.subtitleStyle
            controller.replace(config: newConfig)
        }
        config = newConfig
    }

    func close() {
        playerCoordinator.controller?.shutdown()
        playerCoordinator.resetPlayer()
        sourceURL = nil
        translationRuntime.desiredApplePair = nil
        Task { [translationRouter] in
            await translationRouter.applySettings(mode: .off)
        }

        #if !os(tvOS)
            Anime4KHostBridge.reset()
            #if !targetEnvironment(simulator)
                if #available(iOS 26.0, macOS 26.0, tvOS 26.0, visionOS 26.0, *) {
                    SystemVideoEnhancementAdapter.shared.endSession()
                }
            #endif
            MetalFXSuperResolutionAdapter.shared.endSession()
            OpticalFlowFrameInterpolationAdapter.shared.endSession()
            RifeFrameInterpolationAdapter.shared.endSession()
            PlayerEnhancementModel.shared.resetVideoEnhancementForNewVideoSession()
        #endif

        config = .init()
    }

    func applySubtitleTranslationSettings(mode: SubtitleTranslateMode) {
        config.subtitleTranslateMode = mode
        Task { [translationRouter] in
            await translationRouter.applySettings(mode: mode)
        }
    }

    func restartSubtitleTranslationService() {
        Task { [translationRouter] in
            await translationRouter.restartTranslationService()
        }
    }

    private func configureSubtitleTranslate(
        for options: CinePlayerConfig, mode: SubtitleTranslateMode
    ) {
        options.subtitleTranslateMode = mode
        let router = translationRouter
        options.subtitleTranslate = { text, from, to in
            try await router.translate(text: text, from: from, to: to)
        }
        Task { [translationRouter] in
            await translationRouter.applySettings(mode: mode)
        }
    }

    func configureFrameCallback(for options: CinePlayerConfig) {
        let callbackConfig = makeFrameCallbackConfiguration()
        options.frameCallbackPolicy = callbackConfig.policy
        options.onAudioFrame = nil
        options.onFrameCallbackEvent = callbackConfig.onFrameCallbackEvent
    }

    #if !os(tvOS)
        func reloadCurrentVideoForDynamicRangeChange() {
            guard let url = sourceURL,
                  let controller = playerCoordinator.controller
            else {
                return
            }
            let resumeTime = max(0, controller.currentPlaybackTime)
            let newConfig = CinePlayerConfig()
            newConfig.url = url
            newConfig.startTime = resumeTime
            newConfig.autoPlay = true
            newConfig.dynamicRange = PlayerEnhancementModel.shared.forceSDRForEnhancement ? .sdr : nil
            newConfig.subtitleStyle = config.subtitleStyle
            newConfig.subtitleTranslateMode = config.subtitleTranslateMode
            newConfig.subtitleTranslate = config.subtitleTranslate
            configureFrameCallback(for: newConfig)
            controller.replace(config: newConfig)
            config = newConfig
        }
    #endif

    /// 热更新当前活跃播放器的帧回调配置。
    func applyFrameCallbackConfigurationToActivePlayer(resetPipeline: Bool) {
        guard let controller = playerCoordinator.controller else {
            return
        }

        let callbackConfig = makeFrameCallbackConfiguration()
        config.frameCallbackPolicy = callbackConfig.policy
        config.onAudioFrame = nil
        config.onFrameCallbackEvent = callbackConfig.onFrameCallbackEvent

        controller.setFrameCallbackConfiguration(
            policy: callbackConfig.policy,
            onAudioFrame: nil,
            onFrameCallbackEvent: callbackConfig.onFrameCallbackEvent,
            resetPipeline: resetPipeline
        )
    }

    private typealias EventCallback = (@Sendable (FrameCallbackEvent) -> Void)?

    private func makeFrameCallbackConfiguration()
        -> (
            policy: FrameCallbackPolicy,
            onFrameCallbackEvent: EventCallback
        )
    {
        var policy = FrameCallbackPolicy()

        #if !os(tvOS)
            let enhancementModel = PlayerEnhancementModel.shared
            let strategy: VideoEnhancementStrategy
            strategy = enhancementModel.videoEnhancementStrategy
            let targetFPS = enhancementModel.interpolationTargetFPS
            let screenMaxFPS = enhancementModel.currentScreenMaxFPS
            let targetFPSDetail = targetFPS.shortDetail(screenMaxFPS: screenMaxFPS)

            cinemoreLog(
                level: .debug,
                "VideoEnhance makeFrameCallbackConfiguration strategy=\(strategy.rawValue) systemMLSupported=\(enhancementModel.systemMLEnhancementSupported) systemMLFIEnabled=\(enhancementModel.systemMLFrameInterpolationEnabled) systemMLSREnabled=\(enhancementModel.systemMLSuperResolutionEnabled) systemMLSRScale=\(enhancementModel.systemMLSuperResolutionScale) systemMLFramesAdded=\(enhancementModel.systemMLInterpolatedFrames) systemMLCurrentVideoInRange=\(enhancementModel.systemMLCurrentVideoInRange)"
            )

            switch strategy {
            case .off:
                logFrameCallbackConfigurationOnce("Video enhancement disabled")
                EnhancementTelemetryCollector.shared.reset(strategy: "off", detail: "")
                Anime4KHostBridge.reset()
                #if !targetEnvironment(simulator)
                    if #available(iOS 26.0, macOS 26.0, tvOS 26.0, visionOS 26.0, *) {
                        SystemVideoEnhancementAdapter.shared.endSession()
                    }
                #endif
                MetalFXSuperResolutionAdapter.shared.endSession()
                OpticalFlowFrameInterpolationAdapter.shared.endSession()
                RifeFrameInterpolationAdapter.shared.endSession()
                return (policy, nil)

            case .anime4k:
                #if !targetEnvironment(simulator)
                    if #available(iOS 26.0, macOS 26.0, tvOS 26.0, visionOS 26.0, *) {
                        SystemVideoEnhancementAdapter.shared.endSession()
                    }
                #endif
                MetalFXSuperResolutionAdapter.shared.endSession()
                OpticalFlowFrameInterpolationAdapter.shared.endSession()
                RifeFrameInterpolationAdapter.shared.endSession()

                let anime4kEnabled = enhancementModel.anime4kEnabled
                let preset = enhancementModel.anime4kPreset
                let abCompareEnabled = enhancementModel.anime4kABCompare
                let resolution = enhancementModel.anime4kOutputResolution
                guard anime4kEnabled else {
                    logFrameCallbackConfigurationOnce("Anime4K frame callback disabled")
                    EnhancementTelemetryCollector.shared.reset(strategy: "off", detail: "")
                    Anime4KHostBridge.reset()
                    return (policy, nil)
                }

                let maxOutputWidth = resolution.maxWidth
                let maxOutputHeight = resolution.maxHeight
                let interpolator: Anime4KInterpolator
                do {
                    let engine = try Anime4KHostBridge.makeEngine()
                    interpolator = try Anime4KInterpolator(
                        configuration: .init(
                            preset: preset,
                            maxOutputWidth: maxOutputWidth,
                            maxOutputHeight: maxOutputHeight,
                            abCompareEnabled: abCompareEnabled
                        ),
                        engine: engine
                    )
                } catch {
                    logFrameCallbackConfigurationOnce(
                        "Anime4K unavailable: \(error.localizedDescription)"
                    )
                    EnhancementTelemetryCollector.shared.reset(strategy: "off", detail: "init-failed")
                    return (policy, nil)
                }
                EnhancementTelemetryCollector.shared.reset(
                    strategy: "anime4k",
                    detail: "\(preset)-\(resolution.rawValue)"
                )
                policy = FrameCallbackPolicy(
                    enabled: true,
                    mode: .asyncSingle(
                        .init(
                            processorFactory: {
                                InstrumentedVideoFrameProcessor(
                                    inner: Anime4KSingleFrameProcessor(
                                        interpolator: interpolator,
                                        preset: preset,
                                        abCompareEnabled: abCompareEnabled,
                                        maxOutputWidth: maxOutputWidth,
                                        maxOutputHeight: maxOutputHeight
                                    )
                                )
                            }
                        )
                    )
                )
                logFrameCallbackConfigurationOnce(
                    "Anime4K frame callback enabled mode=\(policy.mode.kind.rawValue) preset=\(preset) outputResolution=\(resolution.rawValue) abCompare=\(abCompareEnabled)"
                )
                let onEvent = makeFrameCallbackEventLogger(tag: "VFI")
                return (policy, onEvent)

            case .systemML:
                #if targetEnvironment(simulator)
                    logFrameCallbackConfigurationOnce("System VT unavailable on simulator")
                    EnhancementTelemetryCollector.shared.reset(strategy: "off", detail: "sim-unsupported")
                    return (policy, nil)
                #else
                    guard #available(iOS 26.0, macOS 26.0, tvOS 26.0, visionOS 26.0, *) else {
                        logFrameCallbackConfigurationOnce("System VT unavailable on this OS")
                        return (policy, nil)
                    }
                    guard enhancementModel.systemMLEnhancementSupported else {
                        logFrameCallbackConfigurationOnce("System VT not supported on device")
                        return (policy, nil)
                    }
                    guard enhancementModel.systemMLCurrentVideoInRange else {
                        logFrameCallbackConfigurationOnce(
                            "System VT current video resolution out of supported range")
                        return (policy, nil)
                    }
                    MetalFXSuperResolutionAdapter.shared.endSession()
                    OpticalFlowFrameInterpolationAdapter.shared.endSession()
                    RifeFrameInterpolationAdapter.shared.endSession()

                    let adapter = SystemVideoEnhancementAdapter.shared
                    let frameInterpolationEnabled =
                        enhancementModel.systemMLFrameInterpolationEnabled
                        && enhancementModel.systemMLCurrentVideoSupportsFrameInterpolation
                    let superResolutionEnabled =
                        enhancementModel.systemMLSuperResolutionEnabled
                        && enhancementModel.systemMLCurrentVideoSupportsSuperResolution
                    guard frameInterpolationEnabled || superResolutionEnabled else {
                        logFrameCallbackConfigurationOnce(
                            "System VT disabled: no active VT feature")
                        EnhancementTelemetryCollector.shared.reset(strategy: "off", detail: "")
                        return (policy, nil)
                    }

                    let onEvent = makeFrameCallbackEventLogger(tag: "VFI")
                    if frameInterpolationEnabled {
                        let scalar = 1
                        let warmupNumFrames = max(
                            1, min(3, enhancementModel.resolvedSystemMLInterpolatedFrames))
                        logFrameCallbackConfigurationOnce(
                            "System VT frame interpolation enabled mode=temporal scalar=\(scalar) targetFPS=\(targetFPS.rawValue) screenMaxFPS=\(screenMaxFPS) warmupNumFrames=\(warmupNumFrames)"
                        )
                        EnhancementTelemetryCollector.shared.reset(
                            strategy: "systemML-fi",
                            detail: targetFPSDetail
                        )
                        policy = FrameCallbackPolicy(
                            enabled: true,
                            mode: .temporal(
                                .init(
                                    processorFactory: {
                                        InstrumentedVideoFrameProcessor(
                                            inner: adapter.makeTemporalProcessor(
                                                scalar: scalar,
                                                targetFPS: targetFPS,
                                                screenMaxFPS: screenMaxFPS
                                            )
                                        )
                                    },
                                    warmup: { dims in
                                        await adapter.warmup(
                                            dimensions: dims,
                                            scalar: scalar,
                                            numFrames: warmupNumFrames
                                        )
                                    }
                                )
                            )
                        )
                        return (policy, onEvent)
                    }

                    let scale = enhancementModel.systemMLSuperResolutionScale
                    let abCompareEnabled = enhancementModel.systemMLABCompare
                    logFrameCallbackConfigurationOnce(
                        "System VT super resolution enabled mode=asyncSingle scale=\(scale) abCompare=\(abCompareEnabled)"
                    )
                    EnhancementTelemetryCollector.shared.reset(
                        strategy: "systemML-sr",
                        detail: String(format: "%.2fx", scale)
                    )
                    policy = FrameCallbackPolicy(
                        enabled: true,
                        mode: .asyncSingle(
                            .init(
                                processorFactory: {
                                    InstrumentedVideoFrameProcessor(
                                        inner: SystemVideoEnhancementSuperResolutionProcessor(
                                            adapter: adapter,
                                            scale: scale,
                                            abCompareEnabled: abCompareEnabled
                                        )
                                    )
                                },
                                preset: .aggressive
                            )
                        )
                    )
                    return (policy, onEvent)
                #endif

            case .opticalFlow:
                MetalFXSuperResolutionAdapter.shared.endSession()
                RifeFrameInterpolationAdapter.shared.endSession()
                guard enhancementModel.opticalFlowSectionVisible else {
                    logFrameCallbackConfigurationOnce(
                        "Optical flow not available: video not 1080p or below"
                    )
                    EnhancementTelemetryCollector.shared.reset(strategy: "off", detail: "out-of-range")
                    return (policy, nil)
                }
                logFrameCallbackConfigurationOnce(
                    "Optical flow frame callback enabled mode=temporal targetFPS=\(targetFPS.rawValue) screenMaxFPS=\(screenMaxFPS)")
                EnhancementTelemetryCollector.shared.reset(
                    strategy: "opticalFlow",
                    detail: targetFPSDetail
                )
                let adapter = OpticalFlowFrameInterpolationAdapter.shared
                policy = FrameCallbackPolicy(
                    enabled: true,
                    mode: .temporal(
                        .init(
                            processorFactory: {
                                InstrumentedVideoFrameProcessor(
                                    inner: adapter.makeTemporalProcessor(
                                        targetFPS: targetFPS,
                                        screenMaxFPS: screenMaxFPS
                                    )
                                )
                            },
                            warmup: { dims in
                                await adapter.warmup(dimensions: dims)
                            }
                        )
                    )
                )
                let onEvent = makeFrameCallbackEventLogger(tag: "VFI")
                return (policy, onEvent)

            case .rife:
                Anime4KHostBridge.reset()
                #if !targetEnvironment(simulator)
                    if #available(iOS 26.0, macOS 26.0, tvOS 26.0, visionOS 26.0, *) {
                        SystemVideoEnhancementAdapter.shared.endSession()
                    }
                #endif
                MetalFXSuperResolutionAdapter.shared.endSession()
                OpticalFlowFrameInterpolationAdapter.shared.endSession()

                guard enhancementModel.rifeSectionVisible else {
                    logFrameCallbackConfigurationOnce(
                        "RIFE not available: video out of supported range")
                    EnhancementTelemetryCollector.shared.reset(strategy: "off", detail: "out-of-range")
                    return (policy, nil)
                }

                let adapter = RifeFrameInterpolationAdapter.shared
                let tier = enhancementModel.resolvedRifeTier
                let adaptive = enhancementModel.rifeAdaptiveEnabled
                enhancementModel.currentRifeTier = tier
                adapter.setAdaptiveDowngradeEnabled(adaptive)
                adapter.onTierChanged = { newTier in
                    Task { @MainActor in
                        PlayerEnhancementModel.shared.currentRifeTier = newTier
                    }
                }
                logFrameCallbackConfigurationOnce(
                    "RIFE frame callback enabled mode=temporal tier=\(tier.rawValue) adaptive=\(adaptive) targetFPS=\(targetFPS.rawValue) screenMaxFPS=\(screenMaxFPS)")
                EnhancementTelemetryCollector.shared.reset(
                    strategy: "rife",
                    detail: "\(tier.rawValue)·\(targetFPSDetail)"
                )
                policy = FrameCallbackPolicy(
                    enabled: true,
                    mode: .temporal(
                        .init(
                            processorFactory: {
                                InstrumentedVideoFrameProcessor(
                                    inner: adapter.makeTemporalProcessor(
                                        tier: tier,
                                        targetFPS: targetFPS,
                                        screenMaxFPS: screenMaxFPS
                                    )
                                )
                            },
                            warmup: { dims in await adapter.warmup(dimensions: dims, tier: tier) }
                        )
                    )
                )
                let onEvent = makeFrameCallbackEventLogger(tag: "VFI-RIFE")
                return (policy, onEvent)

            case .metalFX:
                Anime4KHostBridge.reset()
                #if !targetEnvironment(simulator)
                    if #available(iOS 26.0, macOS 26.0, tvOS 26.0, visionOS 26.0, *) {
                        SystemVideoEnhancementAdapter.shared.endSession()
                    }
                #endif
                OpticalFlowFrameInterpolationAdapter.shared.endSession()
                RifeFrameInterpolationAdapter.shared.endSession()
                guard enhancementModel.metalFXSectionVisible else {
                    logFrameCallbackConfigurationOnce(
                        "MetalFX super resolution unavailable for current video"
                    )
                    EnhancementTelemetryCollector.shared.reset(strategy: "off", detail: "out-of-range")
                    return (policy, nil)
                }
                guard enhancementModel.metalFXSuperResolutionSupported else {
                    logFrameCallbackConfigurationOnce("MetalFX super resolution unsupported on device")
                    EnhancementTelemetryCollector.shared.reset(strategy: "off", detail: "unsupported")
                    return (policy, nil)
                }
                guard enhancementModel.metalFXSuperResolutionEnabled else {
                    logFrameCallbackConfigurationOnce("MetalFX super resolution disabled")
                    EnhancementTelemetryCollector.shared.reset(strategy: "off", detail: "")
                    return (policy, nil)
                }

                let outputResolution = enhancementModel.metalFXOutputResolution
                let abCompareEnabled = enhancementModel.metalFXABCompare
                let adapter = MetalFXSuperResolutionAdapter.shared
                EnhancementTelemetryCollector.shared.reset(
                    strategy: "metalFX",
                    detail: outputResolution.rawValue
                )
                policy = FrameCallbackPolicy(
                    enabled: true,
                    mode: .asyncSingle(
                        .init(
                            processorFactory: {
                                InstrumentedVideoFrameProcessor(
                                    inner: MetalFXSuperResolutionProcessor(
                                        adapter: adapter,
                                        targetOutputResolution: outputResolution,
                                        abCompareEnabled: abCompareEnabled
                                    )
                                )
                            },
                            preset: .aggressive
                        )
                    )
                )
                logFrameCallbackConfigurationOnce(
                    "MetalFX super resolution enabled mode=asyncSingle output=\(outputResolution.rawValue) abCompare=\(abCompareEnabled)"
                )
                let onEvent = makeFrameCallbackEventLogger(tag: "VFI")
                return (policy, onEvent)
            }
        #else
            return (policy, nil)
        #endif
    }

    #if !os(tvOS)
        private func makeFrameCallbackEventLogger(tag: String) -> EventCallback {
            { event in
                EnhancementTelemetryCollector.shared.recordEvent(event)
                switch event {
                case let .callbackTimeout(kind, elapsedMs):
                    cinemoreLog(
                        level: .warning,
                        "[\(tag)] Frame callback timeout kind=\(kind.rawValue) elapsed=\(String(format: "%.2f", elapsedMs))ms"
                    )
                case let .callbackInvalidResult(kind, message):
                    cinemoreLog(
                        level: .debug,
                        "[\(tag)] Frame callback invalid result kind=\(kind.rawValue) message=\(message)"
                    )
                case let .callbackError(kind, message):
                    cinemoreLog(
                        level: .debug,
                        "[\(tag)] Frame callback error kind=\(kind.rawValue) message=\(message)"
                    )
                case let .bypassStarted(kind):
                    cinemoreLog(
                        level: .warning,
                        "[\(tag)] Frame callback bypass started kind=\(kind.rawValue)"
                    )
                case let .bypassEnded(kind):
                    cinemoreLog(
                        level: .warning,
                        "[\(tag)] Frame callback bypass ended kind=\(kind.rawValue)"
                    )
                case let .warmupReady(kind, elapsedMs):
                    cinemoreLog(
                        level: .debug,
                        "[\(tag)] Frame callback warmup ready kind=\(kind.rawValue) elapsed=\(String(format: "%.2f", elapsedMs))ms"
                    )
                @unknown default:
                    cinemoreLog(level: .debug, "[\(tag)] Frame callback unknown event")
                }
            }
        }

        private func logFrameCallbackConfigurationOnce(_ message: String) {
            guard lastFrameCallbackConfigLog != message else {
                return
            }
            lastFrameCallbackConfigLog = message
            cinemoreLog(level: .debug, message)
        }
    #endif
}
