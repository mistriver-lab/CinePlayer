import Anime4KMetal
import CinePlayerSDK
import SwiftUI
import UniformTypeIdentifiers
#if canImport(CoreTransferable)
    import CoreTransferable
#endif
#if canImport(UIKit)
    import UIKit
#elseif canImport(AppKit)
    import AppKit
#endif

#if !os(tvOS)

/// 侧边弹出窗口 - 视频增强
struct SiderEnhancementView: View {
    @EnvironmentObject private var playerCoordinator: CinePlayer.Coordinator
    @ObservedObject private var enhancementModel = PlayerEnhancementModel.shared
    @State private var showLogSheet = false

    private var currentVideoSummary: String? {
        guard let track = playerCoordinator.controller?.videoTracks.first(where: { $0.isEnabled })
                ?? playerCoordinator.controller?.videoTrack
        else {
            return nil
        }
        return "\(track.codecName) \(Int(track.naturalSize.width))x\(Int(track.naturalSize.height)) @ \(String(format: "%.2f", track.nominalFrameRate))fps \(track.bitDepth)bit \(track.dynamicRange.description)"
    }

    private var reportDocument: DiagnosticReportDocument {
        DiagnosticReportDocument(
            videoSummary: currentVideoSummary,
            statsSummary: enhancementModel.liveStatsSummaryText
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("视频增强（实验）")
                .f17s()
                .padding()

            Form {
                Section(header: Text("实时状态")) {
                    let stats = enhancementModel.liveStats
                    HStack {
                        Text("当前策略")
                        Spacer()
                        Text(stats.localizedStrategyText)
                            .foregroundStyle(stats.isActive ? .green : .secondary)
                    }
                    HStack {
                        Text("分辨率变换")
                        Spacer()
                        if stats.inputWidth > 0, stats.outputWidth > 0 {
                            Text("\(stats.inputWidth)×\(stats.inputHeight) → \(stats.outputWidth)×\(stats.outputHeight)")
                                .foregroundStyle(.secondary)
                        } else {
                            Text("--")
                                .foregroundStyle(.secondary)
                        }
                    }
                    HStack {
                        Text("实测帧率 / 耗时")
                        Spacer()
                        Text(String(
                            format: "%.1f → %.1f fps · %.2f ms",
                            stats.measuredInputFPS,
                            stats.measuredOutputFPS,
                            stats.avgFrameTimeMs
                        ))
                        .foregroundStyle(.secondary)
                    }
                    HStack {
                        Text("已增强 / 旁路")
                        Spacer()
                        Text("\(stats.replacedFrames) / \(stats.passthroughFrames) (跳过 \(stats.bypassEvents))")
                            .foregroundStyle(.secondary)
                    }
                    HStack {
                        Text("超时 / 错误")
                        Spacer()
                        Text("\(stats.timeoutEvents) / \(stats.errorEvents)")
                            .foregroundStyle((stats.timeoutEvents > 0 || stats.errorEvents > 0) ? .orange : .secondary)
                    }
                    HStack {
                        Text("设备温控")
                        Spacer()
                        Text(stats.localizedThermalText)
                            .foregroundStyle(thermalStateColor(stats.thermalState))
                    }
                    if !stats.downgradeReason.isEmpty {
                        HStack {
                            Text("降档/保护")
                            Spacer()
                            Text(stats.downgradeReason)
                                .foregroundStyle(.orange)
                                .multilineTextAlignment(.trailing)
                        }
                    }
                }

                Section(
                    header: Text("RIFE 补帧"),
                    footer: Text("Apple 原生 ML 补帧（4K 以内，仅 SDR）。iOS 端 4K 片源将自动采用高速工作分辨率推理并硬件放大，超负荷时自动降档保护；与光流补帧互斥。")
                ) {
                    let isAvailable = enhancementModel.rifeSectionVisible

                    Toggle(
                        "开启",
                        isOn: Binding(
                            get: {
                                enhancementModel.videoEnhancementStrategy == .rife
                            },
                            set: { newValue in
                                if newValue {
                                    enhancementModel.videoEnhancementStrategy = .rife
                                } else if enhancementModel.videoEnhancementStrategy == .rife {
                                    enhancementModel.videoEnhancementStrategy = .off
                                }
                            }
                        )
                    )
                    .disabled(!isAvailable)

                    if !isAvailable {
                        Text("当前视频不在 RIFE 支持范围（最大 4K，仅 SDR）")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    } else {
                        if enhancementModel.videoEnhancementStrategy == .rife {
                            Picker("档位", selection: $enhancementModel.rifeTierPreference) {
                                ForEach(RifeTierPreference.allCases) { tier in
                                    Text(tier.displayName).tag(tier)
                                }
                            }
                            if enhancementModel.rifeTierPreference == .auto {
                                Text("当前档位：\(enhancementModel.rifeAutoTierDisplayName)（按设备性能自适应降档）")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        if let rifeURL = URL(string: "https://github.com/hzwer/Practical-RIFE") {
                            Link("了解 RIFE 详情", destination: rifeURL)
                        }
                    }
                }

                Section(
                    header: Text("Anime4K 超分"),
                    footer: Text("仅对低像素的视频开启，为实验功能，会增加耗电与发热。")
                ) {
                    let isAvailable = enhancementModel.anime4kSectionVisible

                    Toggle(
                        "开启",
                        isOn: Binding(
                            get: {
                                enhancementModel.videoEnhancementStrategy == .anime4k
                                    && enhancementModel.anime4kEnabled
                            },
                            set: { newValue in
                                if newValue {
                                    enhancementModel.videoEnhancementStrategy = .anime4k
                                    enhancementModel.anime4kEnabled = true
                                } else {
                                    enhancementModel.anime4kEnabled = false
                                    if enhancementModel.videoEnhancementStrategy == .anime4k {
                                        enhancementModel.videoEnhancementStrategy = .off
                                    }
                                }
                            }
                        )
                    )
                    .disabled(!isAvailable)

                    if isAvailable {
                        Picker(
                            "档位",
                            selection: Binding(
                                get: {
                                    let preset = enhancementModel.anime4kPreset
                                    return Anime4KPreset.availablePresets.contains(preset)
                                        ? preset : .modeAFast
                                },
                                set: { enhancementModel.anime4kPreset = $0 }
                            )
                        ) {
                            ForEach(Anime4KPreset.availablePresets) { preset in
                                Text(preset.displayName).tag(preset)
                            }
                        }
                        .onAppear {
                            if !Anime4KPreset.availablePresets.contains(enhancementModel.anime4kPreset) {
                                enhancementModel.anime4kPreset = .modeAFast
                            }
                        }

                        Picker("输出分辨率", selection: $enhancementModel.anime4kOutputResolution) {
                            ForEach(Anime4KOutputResolution.allCases) { resolution in
                                Text(resolution.displayName).tag(resolution)
                            }
                        }

                        Toggle(isOn: $enhancementModel.anime4kABCompare) {
                            Text("A/B 对比（左原图，右超分）")
                        }

                        if let anime4kURL = URL(string: "https://github.com/bloc97/Anime4K") {
                            Link("了解 Anime4K 详情", destination: anime4kURL)
                        }
                    } else {
                        Text("当前视频像素数不在 Anime4K 适配范围内")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }

                Section(
                    header: Text("MetalFX 超分"),
                    footer: Text("使用系统 MetalFX Spatial Scaler 做单帧超分。输出将按视频原始比例等比放大到目标 2K 或 4K 边界内。")
                ) {
                    let isAvailable = enhancementModel.metalFXSectionVisible

                    Toggle(
                        "开启",
                        isOn: Binding(
                            get: {
                                enhancementModel.videoEnhancementStrategy == .metalFX
                                    && enhancementModel.metalFXSuperResolutionEnabled
                            },
                            set: { newValue in
                                if newValue {
                                    enhancementModel.videoEnhancementStrategy = .metalFX
                                    enhancementModel.metalFXSuperResolutionEnabled = true
                                } else {
                                    enhancementModel.metalFXSuperResolutionEnabled = false
                                    if enhancementModel.videoEnhancementStrategy == .metalFX {
                                        enhancementModel.videoEnhancementStrategy = .off
                                    }
                                }
                            }
                        )
                    )
                    .disabled(!isAvailable)

                    if isAvailable {
                        Picker(
                            "目标输出",
                            selection: $enhancementModel.metalFXOutputResolution
                        ) {
                            ForEach(
                                enhancementModel.metalFXSupportedOutputResolutionsForCurrentVideo,
                                id: \.self
                            ) { resolution in
                                Text(resolution.displayName).tag(resolution)
                            }
                        }

                        Toggle(isOn: $enhancementModel.metalFXABCompare) {
                            Text("A/B 对比（左原图，右超分）")
                        }

                        if let metalFXURL = URL(string: "https://developer.apple.com/documentation/metalfx") {
                            Link("了解 MetalFX 详情", destination: metalFXURL)
                        }
                    } else if !enhancementModel.metalFXSuperResolutionSupported {
                        Text("当前设备不支持 MetalFX 超分")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("当前视频暂不支持 MetalFX 超分")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }

                Section(
                    header: Text("VT 超分"),
                    footer: Text("依赖系统 VideoToolbox 低延迟超分能力。与 VT 插帧互斥：开启一项会关闭另一项。")
                ) {
                    let srAvailable =
                        enhancementModel.systemMLEnhancementSupported
                            && enhancementModel.systemMLCurrentVideoSupportsSuperResolution

                    Toggle(
                        "开启 VT 超分",
                        isOn: Binding(
                            get: {
                                enhancementModel.videoEnhancementStrategy == .systemML
                                    && enhancementModel.systemMLSuperResolutionEnabled
                            },
                            set: { newValue in
                                if newValue {
                                    enhancementModel.videoEnhancementStrategy = .systemML
                                    enhancementModel.systemMLSuperResolutionEnabled = true
                                    enhancementModel.systemMLFrameInterpolationEnabled = false
                                } else {
                                    enhancementModel.systemMLSuperResolutionEnabled = false
                                    if enhancementModel.videoEnhancementStrategy == .systemML,
                                       !enhancementModel.systemMLFrameInterpolationEnabled
                                    {
                                        enhancementModel.videoEnhancementStrategy = .off
                                    }
                                }
                            }
                        )
                    )
                    .disabled(!srAvailable)

                    if srAvailable {
                        if enhancementModel.systemMLSuperResolutionEnabled {
                            Picker(
                                "超分倍率",
                                selection: $enhancementModel.systemMLSuperResolutionScale
                            ) {
                                ForEach(
                                    enhancementModel.systemMLSupportedScaleFactorsForPicker,
                                    id: \.self
                                ) { scale in
                                    Text("\(scale, specifier: "%.2f")x").tag(scale)
                                }
                            }
                            Toggle(
                                "A/B 对比（左原图，右超分）",
                                isOn: $enhancementModel.systemMLABCompare
                            )
                        }
                    } else if !enhancementModel.systemMLEnhancementSupported {
                        Text("当前设备不支持 VT 超分")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("当前视频分辨率不支持 VT 超分")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }

                Section(
                    header: Text("VT 插帧"),
                    footer: Text("依赖系统 VideoToolbox 低延迟插帧能力。")
                ) {
                    let fiAvailable =
                        enhancementModel.systemMLEnhancementSupported
                            && enhancementModel.systemMLCurrentVideoSupportsFrameInterpolation

                    Toggle(
                        "开启 VT 插帧",
                        isOn: Binding(
                            get: {
                                enhancementModel.videoEnhancementStrategy == .systemML
                                    && enhancementModel.systemMLFrameInterpolationEnabled
                            },
                            set: { newValue in
                                if newValue {
                                    enhancementModel.videoEnhancementStrategy = .systemML
                                    enhancementModel.systemMLFrameInterpolationEnabled = true
                                    enhancementModel.systemMLSuperResolutionEnabled = false
                                } else {
                                    enhancementModel.systemMLFrameInterpolationEnabled = false
                                    if enhancementModel.videoEnhancementStrategy == .systemML,
                                       !enhancementModel.systemMLSuperResolutionEnabled
                                    {
                                        enhancementModel.videoEnhancementStrategy = .off
                                    }
                                }
                            }
                        )
                    )
                    .disabled(!fiAvailable)

                    if fiAvailable {
                        if enhancementModel.systemMLFrameInterpolationEnabled {
                            Picker(
                                "Frames added",
                                selection: $enhancementModel.systemMLInterpolatedFrames
                            ) {
                                Text("1").tag(1)
                                Text("2").tag(2)
                                Text("3").tag(3)
                            }
                        }
                    } else if !enhancementModel.systemMLEnhancementSupported {
                        Text("当前设备不支持 VT 插帧")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("当前视频分辨率不支持 VT 插帧")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }

                Section(
                    header: Text("光流补帧"),
                    footer: Text("仅在 1080p 及以下分辨率开放，适合低帧率内容插帧。")
                ) {
                    let isAvailable = enhancementModel.opticalFlowSectionVisible

                    Toggle(
                        "开启",
                        isOn: Binding(
                            get: {
                                enhancementModel.videoEnhancementStrategy == .opticalFlow
                            },
                            set: { newValue in
                                if newValue {
                                    enhancementModel.videoEnhancementStrategy = .opticalFlow
                                } else if enhancementModel.videoEnhancementStrategy == .opticalFlow {
                                    enhancementModel.videoEnhancementStrategy = .off
                                }
                            }
                        )
                    )
                    .disabled(!isAvailable)

                    if !isAvailable {
                        Text("当前视频分辨率不在光流补帧支持范围内")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }

                Section(
                    header: Text("运行日志与诊断"),
                    footer: Text("Release 构建同样记录内存环形日志与系统 OSLog，支持直接分享 .txt 诊断包排查插帧卡顿。")
                ) {
                    Button {
                        showLogSheet = true
                    } label: {
                        Label("查看运行日志", systemImage: "doc.text.magnifyingglass")
                    }

                    ShareLink(
                        item: reportDocument,
                        preview: SharePreview("GlassMPV-Diagnostics.txt")
                    ) {
                        Label("生成并分享诊断包 (.txt)", systemImage: "square.and.arrow.up")
                    }
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
        }
        .sheet(isPresented: $showLogSheet) {
            EnhancementDiagnosticLogSheet(
                videoSummary: currentVideoSummary,
                statsSummary: enhancementModel.liveStatsSummaryText
            )
        }
    }

    private func thermalStateColor(_ state: String) -> Color {
        switch state {
        case "nominal": .green
        case "fair": .yellow
        case "serious": .orange
        case "critical": .red
        default: .secondary
        }
    }
}

nonisolated private struct DiagnosticReportDocument: Transferable, Sendable {
    let videoSummary: String?
    let statsSummary: String?

    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(exportedContentType: .plainText) { doc in
            let report = DiagnosticLogStore.shared.buildDiagnosticReport(
                videoSummary: doc.videoSummary,
                statsSummary: doc.statsSummary
            )
            return Data(report.utf8)
        }
        .suggestedFileName("GlassMPV-Diagnostics.txt")
    }
}

private struct EnhancementDiagnosticLogSheet: View {
    @Environment(\.dismiss) private var dismiss
    let videoSummary: String?
    let statsSummary: String?

    @State private var entries: [DiagnosticLogEntry] = DiagnosticLogStore.shared.recentEntries(limit: 300)
    @State private var exportedFileURL: URL?
    @State private var statusBanner: String?

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 8) {
                if let statusBanner {
                    Text(statusBanner)
                        .font(.caption)
                        .foregroundStyle(.green)
                        .padding(.horizontal)
                }

                if let exportedFileURL {
                    HStack {
                        ShareLink(item: exportedFileURL) {
                            Label("分享已生成的 \(exportedFileURL.lastPathComponent)", systemImage: "square.and.arrow.up")
                                .font(.subheadline)
                        }
                        Spacer()
                    }
                    .padding(.horizontal)
                }

                if entries.isEmpty {
                    ContentUnavailableView(
                        "暂无运行日志",
                        systemImage: "text.alignleft",
                        description: Text("播放或开启视频增强后，耗时、降档与温控事件会记录在此。")
                    )
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 6) {
                            ForEach(entries.reversed()) { entry in
                                Text(entry.formattedLine)
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(color(for: entry.level))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .textSelection(.enabled)
                                Divider()
                            }
                        }
                        .padding(.horizontal)
                        .padding(.vertical, 8)
                    }
                }
            }
            .navigationTitle("运行日志 (\(entries.count))")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItemGroup(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
                ToolbarItemGroup(placement: .primaryAction) {
                    Button {
                        entries = DiagnosticLogStore.shared.recentEntries(limit: 300)
                        statusBanner = "已刷新（\(entries.count) 条）"
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .accessibilityLabel("刷新")

                    Button {
                        copyFullReport()
                    } label: {
                        Image(systemName: "doc.on.doc")
                    }
                    .accessibilityLabel("复制诊断全文")

                    Button {
                        exportDiagnosticFile()
                    } label: {
                        Image(systemName: "square.and.arrow.up")
                    }
                    .accessibilityLabel("导出 .txt")

                    Button(role: .destructive) {
                        DiagnosticLogStore.shared.clear()
                        entries = []
                        exportedFileURL = nil
                        statusBanner = "已清空内存日志"
                    } label: {
                        Image(systemName: "trash")
                    }
                    .accessibilityLabel("清空")
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 560, minHeight: 420)
        #endif
    }

    private func color(for level: CinemoreLogLevel) -> Color {
        switch level {
        case .error: .red
        case .warning: .orange
        case .debug: .secondary
        }
    }

    private func copyFullReport() {
        let report = DiagnosticLogStore.shared.buildDiagnosticReport(
            videoSummary: videoSummary,
            statsSummary: statsSummary
        )
        #if canImport(UIKit)
            UIPasteboard.general.string = report
        #elseif canImport(AppKit)
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(report, forType: .string)
        #endif
        statusBanner = "已复制完整诊断报告到剪贴板"
    }

    private func exportDiagnosticFile() {
        if let url = DiagnosticLogStore.shared.writeDiagnosticReportFile(
            videoSummary: videoSummary,
            statsSummary: statsSummary
        ) {
            exportedFileURL = url
            statusBanner = "已生成 \(url.lastPathComponent)"
        } else {
            statusBanner = "导出诊断文件失败"
        }
    }
}

#else

struct SiderEnhancementView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("视频增强（实验）")
                .f17s()
            Text("tvOS 暂不提供增强策略配置")
                .f12r()
                .foregroundStyle(.white.opacity(0.65))
        }
        .padding()
    }
}

#endif
