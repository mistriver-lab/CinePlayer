import Foundation
import SwiftUI
import Combine

@MainActor
final class PlayerSessionStore: ObservableObject {
    static let shared = PlayerSessionStore()

    @Published var currentSource: PlayerSource?
    @Published var lastOpenError: String?
    @Published var controlConfig: PlayerControlConfig

    private var securityScopedURLs: [URL] = []
    private var cancellables = Set<AnyCancellable>()

    private enum StorageKey {
        static let skipForwardSeconds = "player.control.skipForwardSeconds"
        static let skipBackwardSeconds = "player.control.skipBackwardSeconds"
    }

    init() {
        var config = PlayerControlConfig.default
        let defaults = UserDefaults.standard
        if defaults.object(forKey: StorageKey.skipForwardSeconds) != nil {
            config.skipForwardSeconds = defaults.integer(forKey: StorageKey.skipForwardSeconds)
        }
        if defaults.object(forKey: StorageKey.skipBackwardSeconds) != nil {
            config.skipBackwardSeconds = defaults.integer(forKey: StorageKey.skipBackwardSeconds)
        }
        self.controlConfig = config

        $controlConfig
            .removeDuplicates()
            .dropFirst()
            .sink { cfg in
                let d = UserDefaults.standard
                d.set(cfg.skipForwardSeconds, forKey: StorageKey.skipForwardSeconds)
                d.set(cfg.skipBackwardSeconds, forKey: StorageKey.skipBackwardSeconds)
            }
            .store(in: &cancellables)
    }

    func open(url: URL, startTime: TimeInterval = 0) {
        open(sources: [PlayerSource(url: url, startTime: startTime)], startAt: 0)
    }

    func open(urls: [URL], startAt: Int = 0) {
        open(sources: urls.map { PlayerSource(url: $0) }, startAt: startAt)
    }

    func open(sources: [PlayerSource], startAt: Int = 0) {
        lastOpenError = nil
        releaseSecurityScopedURLs()

        let preparedSources = prepareSourcesForPlayback(sources)
        guard !preparedSources.isEmpty else {
            close()
            if let first = sources.first {
                lastOpenError = "无法读取视频文件：\(first.url.lastPathComponent)"
            }
            return
        }

        let clampedIndex = min(max(startAt, 0), preparedSources.count - 1)
        currentSource = preparedSources[clampedIndex]
    }

    func close() {
        currentSource = nil
        releaseSecurityScopedURLs()
    }

    private func prepareSourcesForPlayback(_ sources: [PlayerSource]) -> [PlayerSource] {
        var result: [PlayerSource] = []
        var secured: [URL] = []

        for source in sources {
            let fileURL = source.url
            guard fileURL.isFileURL else {
                result.append(source)
                continue
            }

            let hasSecurityAccess = fileURL.startAccessingSecurityScopedResource()
            var resolvedURL = fileURL
            var isReadable =
                FileManager.default.fileExists(atPath: resolvedURL.path)
                    && FileManager.default.isReadableFile(atPath: resolvedURL.path)

            if !isReadable {
                resolvedURL = Self.coordinateReadableURL(fileURL)
                isReadable =
                    FileManager.default.fileExists(atPath: resolvedURL.path)
                        && FileManager.default.isReadableFile(atPath: resolvedURL.path)
            }

            guard hasSecurityAccess || isReadable else {
                continue
            }

            if hasSecurityAccess {
                secured.append(fileURL)
            }
            let effectiveSource =
                resolvedURL == fileURL
                    ? source
                    : PlayerSource(url: resolvedURL, startTime: source.startTime)
            result.append(effectiveSource)
        }

        securityScopedURLs = secured
        return result
    }

    nonisolated private static func coordinateReadableURL(_ url: URL) -> URL {
        var resolvedURL = url
        var coordError: NSError?
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordError) { newURL in
            resolvedURL = newURL
        }
        return resolvedURL
    }

    private func releaseSecurityScopedURLs() {
        guard !securityScopedURLs.isEmpty else {
            return
        }
        for url in securityScopedURLs {
            url.stopAccessingSecurityScopedResource()
        }
        securityScopedURLs.removeAll(keepingCapacity: false)
    }
}
