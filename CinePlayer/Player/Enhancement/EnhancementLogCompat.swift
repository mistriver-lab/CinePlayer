import Foundation
import os
#if canImport(OSLog)
    import OSLog
#endif
#if canImport(UIKit)
    import UIKit
#endif

nonisolated enum CinemoreLogLevel: String, Sendable {
    case debug
    case warning
    case error

    var tag: String {
        switch self {
        case .debug: "DEBUG"
        case .warning: "WARN"
        case .error: "ERROR"
        }
    }
}

nonisolated struct DiagnosticLogEntry: Identifiable, Sendable {
    let id: UUID
    let timestamp: Date
    let level: CinemoreLogLevel
    let message: String

    var formattedLine: String {
        let ts = timestamp.formatted(Date.ISO8601FormatStyle(includingFractionalSeconds: true))
        return "[\(ts)] [\(level.tag)] \(message)"
    }
}

nonisolated final class DiagnosticLogStore: @unchecked Sendable {
    static let shared = DiagnosticLogStore()

    private let lock = NSLock()
    private let maxEntries = 500
    private var entries: [DiagnosticLogEntry] = []
    private let logger = Logger(subsystem: "com.glassmpv.cine", category: "Runtime")

    private init() {}

    func append(level: CinemoreLogLevel, message: String) {
        let entry = DiagnosticLogEntry(
            id: UUID(),
            timestamp: Date(),
            level: level,
            message: message
        )

        lock.lock()
        entries.append(entry)
        if entries.count > maxEntries {
            entries.removeFirst(entries.count - maxEntries)
        }
        lock.unlock()

        switch level {
        case .debug:
            logger.debug("\(message, privacy: .public)")
        case .warning:
            logger.warning("\(message, privacy: .public)")
        case .error:
            logger.error("\(message, privacy: .public)")
        }

        #if DEBUG
            print("[\(level.tag)] \(message)")
        #endif
    }

    func recentEntries(limit: Int = 200) -> [DiagnosticLogEntry] {
        guard limit > 0 else { return [] }
        lock.lock()
        let result = Array(entries.suffix(limit))
        lock.unlock()
        return result
    }

    func clear() {
        lock.lock()
        entries.removeAll(keepingCapacity: true)
        lock.unlock()
    }

    static func currentThermalStateText() -> String {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: "nominal"
        case .fair: "fair"
        case .serious: "serious"
        case .critical: "critical"
        @unknown default: "unknown"
        }
    }

    static func deviceModelIdentifier() -> String {
        var sysinfo = utsname()
        uname(&sysinfo)
        return withUnsafePointer(to: &sysinfo.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: 1) {
                String(cString: $0)
            }
        }
    }

    func buildDiagnosticReport(videoSummary: String?, statsSummary: String?) -> String {
        lock.lock()
        let buffered = entries
        lock.unlock()

        let nowText = Date().formatted(Date.ISO8601FormatStyle(includingFractionalSeconds: true))
        let shortVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let buildVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        let model = Self.deviceModelIdentifier()
        let osVersion = ProcessInfo.processInfo.operatingSystemVersionString
        let thermal = Self.currentThermalStateText()
        let lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled

        var sections: [String] = []
        sections.append([
            "=== GlassMPV Diagnostic Report ===",
            "Generated: \(nowText)",
            "App Version: \(shortVersion) (\(buildVersion))",
            "Device: \(model)",
            "OS: \(osVersion)",
            "Thermal State: \(thermal)",
            "Low Power Mode: \(lowPower)",
        ].joined(separator: "\n"))

        sections.append([
            "=== Video & Enhancement Stats ===",
            "Video: \(videoSummary ?? "none")",
            "Stats: \(statsSummary ?? "none")",
        ].joined(separator: "\n"))

        var bufferLines = ["=== Runtime Ring Buffer Logs (\(buffered.count) entries) ==="]
        if buffered.isEmpty {
            bufferLines.append("(empty)")
        } else {
            bufferLines.append(contentsOf: buffered.map(\.formattedLine))
        }
        sections.append(bufferLines.joined(separator: "\n"))

        var osLogLines = ["=== OSLogStore (last 5m, com.glassmpv.cine) ==="]
        #if canImport(OSLog)
            if #available(iOS 15.0, macOS 12.0, tvOS 15.0, *) {
                do {
                    let store = try OSLogStore(scope: .currentProcessIdentifier)
                    let position = store.position(date: Date().addingTimeInterval(-300))
                    let predicate = NSPredicate(format: "subsystem == %@", "com.glassmpv.cine")
                    let rawEntries = try store.getEntries(at: position, matching: predicate)
                    var collected: [String] = []
                    for entry in rawEntries {
                        let ts = entry.date.formatted(Date.ISO8601FormatStyle(includingFractionalSeconds: true))
                        if let logEntry = entry as? OSLogEntryLog {
                            collected.append("[\(ts)] [\(logEntry.category)] \(logEntry.composedMessage)")
                        } else {
                            collected.append("[\(ts)] \(entry.composedMessage)")
                        }
                    }
                    let tail = Array(collected.suffix(200))
                    if tail.isEmpty {
                        osLogLines.append("(no entries in last 5m)")
                    } else {
                        osLogLines.append(contentsOf: tail)
                    }
                } catch {
                    osLogLines.append("OSLogStore unavailable: \(error.localizedDescription)")
                }
            } else {
                osLogLines.append("OSLogStore requires iOS 15+ / macOS 12+ / tvOS 15+")
            }
        #else
            osLogLines.append("OSLog framework not available")
        #endif
        sections.append(osLogLines.joined(separator: "\n"))

        return sections.joined(separator: "\n\n") + "\n"
    }

    func writeDiagnosticReportFile(videoSummary: String?, statsSummary: String?) -> URL? {
        let content = buildDiagnosticReport(videoSummary: videoSummary, statsSummary: statsSummary)
        let timestamp = Int(Date().timeIntervalSince1970)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("GlassMPV-Diagnostics-\(timestamp).txt")
        do {
            try content.write(to: url, atomically: true, encoding: .utf8)
            return url
        } catch {
            logger.error("Failed to write diagnostic report: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }
}

nonisolated func cinemoreLog(level: CinemoreLogLevel, _ message: String) {
    DiagnosticLogStore.shared.append(level: level, message: message)
}
