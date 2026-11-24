import Foundation
import SwiftUI
import UniformTypeIdentifiers

#if os(macOS)
    import AppKit
#else
    import UIKit
#endif
#if os(iOS)
    import CoreTransferable
    import PhotosUI
#endif

struct PlayerOpenView: View {
    private enum OpenRoute: Hashable {
        case history
    }

    @EnvironmentObject var sessionStore: PlayerSessionStore

    @State private var navigationPath: [OpenRoute] = []
    @State private var showFileImporter = false
    #if os(iOS)
        @State private var pendingPickedURL: URL?
        @State private var selectedPhotoItem: PhotosPickerItem?
        @State private var isImportingPhoto = false
        @State private var openErrorMessage: String?
    #endif
    @State private var urlInput = ""
    @State private var isDropTargeted = false
    @FocusState private var isURLFieldFocused: Bool

    private var hasURLInput: Bool {
        !urlInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var homeContentSpacing: CGFloat {
        #if os(tvOS) || os(visionOS)
            160
        #else
            32
        #endif
    }

    private var brandingSize: CGFloat {
        #if os(tvOS) || os(visionOS)
            128
        #else
            86
        #endif
    }

    private var openControlsMaxWidth: CGFloat {
        #if os(tvOS) || os(visionOS)
            980
        #else
            640
        #endif
    }

    private var urlRowSpacing: CGFloat {
        #if os(tvOS) || os(visionOS)
            12
        #else
            8
        #endif
    }

    var body: some View {
        NavigationStack(path: $navigationPath) {
            ZStack {
                #if !os(tvOS)
                    backgroundLayer
                #endif

                VStack(spacing: homeContentSpacing) {
                    topBranding
                    openControls
                }
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 16)

                #if os(macOS)
                    bottomHint
                #endif
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay {
                if isDropTargeted {
                    dropOverlay
                }
            }
            .navigationDestination(for: OpenRoute.self) { route in
                switch route {
                case .history:
                    PlaybackHistoryListView()
                }
            }
            .navigationTitle("")
            #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
            #endif
            #if os(macOS)
            .toolbar {
                ToolbarItem(placement: .automatic) {
                    historyButton
                }
            }
            #elseif !os(tvOS)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    historyButton
                }
            }
            #endif
        }
        #if !os(tvOS)
        .onDrop(
            of: [UTType.fileURL],
            isTargeted: $isDropTargeted,
            perform: handleDrop(providers:)
        )
        #if os(iOS)
        .sheet(isPresented: $showFileImporter, onDismiss: handlePendingPickedFile) {
            IOSDocumentPickerView(
                onPick: { pickedURL in
                    schedulePickedFileOpen(pickedURL)
                },
                onCancel: {
                    showFileImporter = false
                },
                onError: { message in
                    openErrorMessage = message
                    showFileImporter = false
                }
            )
            .ignoresSafeArea()
        }
        .compatibleOnChange(of: selectedPhotoItem) { newItem in
            guard let newItem else { return }
            selectedPhotoItem = nil
            importFromPhotosItem(newItem)
        }
        .alert(
            "无法打开视频",
            isPresented: Binding(
                get: { activeOpenErrorMessage != nil },
                set: { isPresented in
                    if !isPresented {
                        openErrorMessage = nil
                        sessionStore.lastOpenError = nil
                    }
                }
            )
        ) {
            Button("确定", role: .cancel) {}
        } message: {
            Text(activeOpenErrorMessage ?? "")
        }
        #else
        .fileImporter(
            isPresented: $showFileImporter,
            allowedContentTypes: [.movie, .video, .audiovisualContent, .data],
            allowsMultipleSelection: false
        ) { result in
            if case .success(let urls) = result, let url = urls.first {
                openMedia(url: url)
            }
        }
        #endif
        #endif
    }

    private var historyButton: some View {
        Button {
            navigationPath.append(.history)
        } label: {
            Image(systemName: "clock.arrow.trianglehead.counterclockwise.rotate.90")
        }
    }

    private var backgroundLayer: some View {
        Rectangle()
            .fill(systemBackgroundColor)
            .overlay {
                LinearGradient(
                    colors: [
                        Color.black.opacity(0.08),
                        .white.opacity(0.2),
                    ],
                    startPoint: .bottom,
                    endPoint: .top
                )
            }
            .ignoresSafeArea()
        #if os(iOS)
            .contentShape(Rectangle())
            .onTapGesture {
                isURLFieldFocused = false
            }
        #endif
    }

    private var systemBackgroundColor: Color {
        #if os(macOS)
            return Color(nsColor: .windowBackgroundColor)
        #elseif os(tvOS)
            return .black
        #else
            return Color(uiColor: .systemBackground)
        #endif
    }

    private var topBranding: some View {
        VStack(spacing: 12) {
            Image("CinePlayerIcon")
                .resizable()
                .scaledToFit()
                .frame(width: brandingSize, height: brandingSize)
                .clipShape(RoundedRectangle(cornerRadius: brandingSize * 0.22, style: .continuous))
                .shadow(color: Color.black.opacity(0.2), radius: 18, y: 8)

            Text(verbatim: "GlassMPV")
                .font(.system(size: 24, weight: .bold))
        }
    }

    private var openControls: some View {
        VStack(spacing: 32) {
            HStack(spacing: urlRowSpacing) {
                urlPlayContainer

                if hasURLInput {
                    playURLButton
                }
            }
            .animation(.snappy, value: hasURLInput)
            #if !os(tvOS)
                orDividerRow
                openFileButton
            #endif
        }
        .frame(maxWidth: openControlsMaxWidth)
    }

    private static let openControlCornerRadius: CGFloat = 16

    private var urlPlayContainer: some View {
        #if os(tvOS) || os(visionOS)
            urlTextField
                .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
        #else
            HStack(alignment: .center, spacing: 8) {
                urlTextField
                    .textFieldStyle(.plain)
                    .font(.system(size: 15, weight: .regular))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, 16)

                if hasURLInput {
                    Button {
                        urlInput = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 22, weight: .semibold))
                            .foregroundStyle(.opacity(0.7))
                    }
                    .buttonStyle(.plain)
                    .padding(.trailing, 8)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: 44)
            .modifier(
                GlassEffectModifier(
                    cornerRadius: Self.openControlCornerRadius,
                    useCapsule: true,
                    clipsContent: true
                )
            )
        #endif
    }

    private var urlTextField: some View {
        TextField("输入视频 URL", text: $urlInput)
            .focused($isURLFieldFocused)
            .submitLabel(.go)
            .onSubmit {
                guard let url = resolveInputURL(urlInput) else {
                    return
                }
                openMedia(url: url)
            }
    }

    private var playURLButton: some View {
        #if os(tvOS) || os(visionOS)
            Button(action: {
                guard let url = resolveInputURL(urlInput) else { return }
                openMedia(url: url)
            }) {
                Image(systemName: "play.fill")
                    .font(.system(size: 24, weight: .bold))
                    .frame(width: 56, height: 56)
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.circle)
            .tint(Color(red: 0.08, green: 0.5, blue: 0.97))
        #else
            Button(action: {
                guard let url = resolveInputURL(urlInput) else { return }
                openMedia(url: url)
            }) {
                ZStack {
                    Color(red: 0.08, green: 0.5, blue: 0.97)
                    Image(systemName: "play.fill")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                }
                .frame(width: 44, height: 44)
                .modifier(
                    GlassEffectModifier(
                        cornerRadius: Self.openControlCornerRadius,
                        useCapsule: true,
                        clipsContent: true
                    )
                )
            }
            .buttonStyle(.plain)
        #endif
    }

    private var orDividerRow: some View {
        HStack(spacing: 12) {
            Capsule()
                .fill(Color.primary.opacity(0.2))
                .frame(height: 1)
            Text("或")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.primary.opacity(0.72))
            Capsule()
                .fill(Color.primary.opacity(0.2))
                .frame(height: 1)
        }
        .frame(alignment: .center)
        .padding(.horizontal, 4)
    }

    private var openFileButton: some View {
        VStack(spacing: 12) {
            Button(action: {
                showFileImporter = true
            }) {
                ZStack {
                    Color.blue
                    Text(verbatim: "打开本地文件")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                }
                .frame(width: 240, height: 44)
                .modifier(
                    GlassEffectModifier(
                        cornerRadius: Self.openControlCornerRadius,
                        useCapsule: true,
                        clipsContent: true
                    )
                )
            }
            .buttonStyle(.plain)

            #if os(iOS)
                let importingPhoto = isImportingPhoto
                let controlCornerRadius = Self.openControlCornerRadius
                PhotosPicker(
                    selection: $selectedPhotoItem,
                    matching: .videos,
                    preferredItemEncoding: .current
                ) {
                    PhotosPickerLabelView(
                        isImporting: importingPhoto,
                        cornerRadius: controlCornerRadius
                    )
                }
                .buttonStyle(.plain)
                .disabled(isImportingPhoto)
            #endif
        }
    }

    private var bottomHint: some View {
        VStack {
            Spacer()
            Text("拖动视频文件到窗口播放")
                .font(.system(size: 12, weight: .regular))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .padding(.horizontal, 16)
                .padding(.bottom, 14)
        }
        .allowsHitTesting(false)
    }

    private var dropOverlay: some View {
        RoundedRectangle(cornerRadius: 0)
            .fill(Color.white.opacity(0.06))
            .overlay {
                RoundedRectangle(cornerRadius: 0)
                    .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [7, 6]))
                    .foregroundStyle(Color.white.opacity(0.38))
            }
            .ignoresSafeArea()
            .allowsHitTesting(false)
    }

    #if !os(tvOS)
        private func handleDrop(providers: [NSItemProvider]) -> Bool {
            guard
                let fileProvider = providers.first(where: {
                    $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier)
                })
            else {
                return false
            }

            fileProvider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) {
                item, _ in
                if let data = item as? Data,
                   let url = URL(dataRepresentation: data, relativeTo: nil)
                {
                    Task { @MainActor in
                        openMedia(url: url)
                    }
                    return
                }

                if let url = item as? URL {
                    Task { @MainActor in
                        openMedia(url: url)
                    }
                    return
                }

                if let path = item as? String {
                    let sanitized = path.trimmingCharacters(in: .whitespacesAndNewlines)
                    if let url = URL(string: sanitized) {
                        Task { @MainActor in
                            openMedia(url: url)
                        }
                    }
                }
            }

            return true
        }
    #endif

    #if os(iOS)
        private var activeOpenErrorMessage: String? {
            openErrorMessage ?? sessionStore.lastOpenError
        }

        private func schedulePickedFileOpen(_ pickedURL: URL) {
            pendingPickedURL = pickedURL
            let wasPresenting = showFileImporter
            showFileImporter = false
            if !wasPresenting {
                handlePendingPickedFile()
            } else {
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(500))
                    handlePendingPickedFile()
                }
            }
        }

        private func handlePendingPickedFile() {
            guard let pickedURL = pendingPickedURL else { return }
            pendingPickedURL = nil
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(150))
                do {
                    let stagedURL = try stageGlassMPVImportedFile(from: pickedURL)
                    openMedia(url: stagedURL)
                } catch {
                    openErrorMessage = "无法读取本地视频：\(error.localizedDescription)"
                }
            }
        }

        private func importFromPhotosItem(_ item: PhotosPickerItem) {
            guard !isImportingPhoto else { return }
            isImportingPhoto = true
            openErrorMessage = nil
            Task { @MainActor in
                defer { isImportingPhoto = false }
                do {
                    guard let movie = try await item.loadTransferable(type: GlassMPVMovieTransferable.self) else {
                        openErrorMessage = "未能从系统相册读取该视频（请确认 iCloud 原片已下载到本地）。"
                        return
                    }
                    try? await Task.sleep(for: .milliseconds(150))
                    openMedia(url: movie.url)
                } catch {
                    openErrorMessage = "相册视频导入失败：\(error.localizedDescription)"
                }
            }
        }
    #endif

    private func openMedia(url: URL) {
        #if os(tvOS)
            isURLFieldFocused = false
        #endif
        sessionStore.open(url: url)
    }

    private func resolveInputURL(_ rawInput: String) -> URL? {
        let text = rawInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            return nil
        }

        if let url = URL(string: text), url.scheme != nil {
            return url
        }

        let expandedPath = (text as NSString).expandingTildeInPath
        if expandedPath.hasPrefix("/") {
            return URL(fileURLWithPath: expandedPath)
        }

        return URL(string: text)
    }
}

#if os(iOS)
private struct PhotosPickerLabelView: View {
    let isImporting: Bool
    let cornerRadius: CGFloat

    nonisolated init(isImporting: Bool, cornerRadius: CGFloat) {
        self.isImporting = isImporting
        self.cornerRadius = cornerRadius
    }

    var body: some View {
        ZStack {
            Color.indigo
            if isImporting {
                HStack(spacing: 8) {
                    ProgressView()
                        .tint(.white)
                    Text("正在导入相册视频…")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                }
            } else {
                Label("从相册选择", systemImage: "photo.on.rectangle.angled")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
            }
        }
        .frame(width: 240, height: 44)
        .modifier(
            GlassEffectModifier(
                cornerRadius: cornerRadius,
                useCapsule: true,
                clipsContent: true
            )
        )
    }
}

nonisolated private var glassMPVImportsDirectory: URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("GlassMPVImports", isDirectory: true)
}

nonisolated private func sanitizeGlassMPVFilename(_ raw: String) -> String {
    let disallowed = CharacterSet(charactersIn: "/\\:#?%\"<>|*")
    let joined = raw.components(separatedBy: disallowed).filter { !$0.isEmpty }.joined(separator: "_")
    let trimmed = joined.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? "video" : String(trimmed.prefix(80))
}

nonisolated private func pruneGlassMPVImports(keepingLatest limit: Int) {
    guard let entries = try? FileManager.default.contentsOfDirectory(
        at: glassMPVImportsDirectory,
        includingPropertiesForKeys: [.contentModificationDateKey],
        options: [.skipsHiddenFiles]
    ), entries.count > limit else {
        return
    }
    let sorted = entries.sorted { lhs, rhs in
        let lDate = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
        let rDate = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
        return lDate > rDate
    }
    for obsolete in sorted.dropFirst(limit) {
        try? FileManager.default.removeItem(at: obsolete)
    }
}

nonisolated private func stageGlassMPVImportedFile(from sourceURL: URL) throws -> URL {
    let standardizedImports = glassMPVImportsDirectory.standardizedFileURL.path
    if sourceURL.standardizedFileURL.path.hasPrefix(standardizedImports),
       FileManager.default.isReadableFile(atPath: sourceURL.path) {
        return sourceURL
    }

    try FileManager.default.createDirectory(at: glassMPVImportsDirectory, withIntermediateDirectories: true)
    pruneGlassMPVImports(keepingLatest: 3)

    let didAccess = sourceURL.startAccessingSecurityScopedResource()
    defer {
        if didAccess {
            sourceURL.stopAccessingSecurityScopedResource()
        }
    }

    let ext = sourceURL.pathExtension
    let rawBase = sourceURL.deletingPathExtension().lastPathComponent
    let sanitizedBase = sanitizeGlassMPVFilename(rawBase)
    let prefix = String(UUID().uuidString.prefix(8))
    let filename = ext.isEmpty ? "\(prefix)_\(sanitizedBase)" : "\(prefix)_\(sanitizedBase).\(ext)"
    let destURL = glassMPVImportsDirectory.appendingPathComponent(filename)

    if FileManager.default.fileExists(atPath: destURL.path) {
        try FileManager.default.removeItem(at: destURL)
    }

    var didDirectCopy = false
    var directCopyError: Error?
    if FileManager.default.isReadableFile(atPath: sourceURL.path) {
        do {
            try FileManager.default.copyItem(at: sourceURL, to: destURL)
            didDirectCopy = FileManager.default.isReadableFile(atPath: destURL.path)
        } catch {
            directCopyError = error
        }
    }

    if !didDirectCopy {
        if FileManager.default.fileExists(atPath: destURL.path) {
            try? FileManager.default.removeItem(at: destURL)
        }
        var coordinatorError: NSError?
        var copyError: Error?
        NSFileCoordinator().coordinate(readingItemAt: sourceURL, options: .withoutChanges, error: &coordinatorError) { readableURL in
            do {
                if FileManager.default.fileExists(atPath: destURL.path) {
                    try FileManager.default.removeItem(at: destURL)
                }
                try FileManager.default.copyItem(at: readableURL, to: destURL)
            } catch {
                copyError = error
            }
        }
        if let coordinatorError {
            throw coordinatorError
        }
        if let copyError {
            throw copyError
        }
        if !FileManager.default.isReadableFile(atPath: destURL.path), let directCopyError {
            throw directCopyError
        }
    }

    guard FileManager.default.isReadableFile(atPath: destURL.path) else {
        throw NSError(
            domain: "GlassMPV.LocalImport",
            code: -1,
            userInfo: [NSLocalizedDescriptionKey: "导入后的视频副本不可读：\(destURL.lastPathComponent)"]
        )
    }
    return destURL
}

private struct IOSDocumentPickerView: UIViewControllerRepresentable {
    let onPick: (URL) -> Void
    let onCancel: () -> Void
    let onError: (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onPick: onPick, onCancel: onCancel, onError: onError)
    }

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(
            forOpeningContentTypes: [.movie, .video, .audiovisualContent, .data],
            asCopy: true
        )
        picker.allowsMultipleSelection = false
        picker.shouldShowFileExtensions = true
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {
        context.coordinator.onPick = onPick
        context.coordinator.onCancel = onCancel
        context.coordinator.onError = onError
    }

    @MainActor
    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        var onPick: (URL) -> Void
        var onCancel: () -> Void
        var onError: (String) -> Void

        init(
            onPick: @escaping (URL) -> Void,
            onCancel: @escaping (URL) -> Void,
            onError: @escaping (String) -> Void
        ) {
            self.onPick = onPick
            self.onCancel = onCancel
            self.onError = onError
        }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            guard let firstURL = urls.first else {
                onError("未获取到所选视频文件。")
                return
            }
            do {
                let stagedURL = try stageGlassMPVImportedFile(from: firstURL)
                onPick(stagedURL)
            } catch {
                onError("无法读取所选文件：\(error.localizedDescription)")
            }
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            onCancel()
        }
    }
}

nonisolated private struct GlassMPVMovieTransferable: Transferable, Sendable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { movie in
            SentTransferredFile(movie.url)
        } importing: { received in
            let stagedURL = try stageGlassMPVImportedFile(from: received.file)
            return GlassMPVMovieTransferable(url: stagedURL)
        }

        FileRepresentation(contentType: .video) { movie in
            SentTransferredFile(movie.url)
        } importing: { received in
            let stagedURL = try stageGlassMPVImportedFile(from: received.file)
            return GlassMPVMovieTransferable(url: stagedURL)
        }

        FileRepresentation(contentType: .audiovisualContent) { movie in
            SentTransferredFile(movie.url)
        } importing: { received in
            let stagedURL = try stageGlassMPVImportedFile(from: received.file)
            return GlassMPVMovieTransferable(url: stagedURL)
        }
    }
}
#endif
