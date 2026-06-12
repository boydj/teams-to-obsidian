import Foundation
import os

/// Logs to the unified log and to a file under ~/Library/Logs/teams-to-obsidian.
/// CLI subcommands also mirror to stderr.
enum Log {
    nonisolated(unsafe) static var mirrorToStderr = false

    private static let osLogger = Logger(subsystem: "net.jbip.teams-to-obsidian", category: "app")
    private static let queue = DispatchQueue(label: "tto.log")
    private static let maxFileBytes: UInt64 = 5 * 1024 * 1024

    private static let timestampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return f
    }()

    static func info(_ message: String)  { write(level: "INFO", message); osLogger.info("\(message, privacy: .public)") }
    static func error(_ message: String) { write(level: "ERROR", message); osLogger.error("\(message, privacy: .public)") }
    static func debug(_ message: String) { write(level: "DEBUG", message); osLogger.debug("\(message, privacy: .public)") }

    private static func write(level: String, _ message: String) {
        let line = "\(timestampFormatter.string(from: Date())) [\(level)] \(message)\n"
        if mirrorToStderr {
            FileHandle.standardError.write(Data(line.utf8))
        }
        queue.async {
            do {
                try Paths.ensureDir(Paths.logDir)
                let url = Paths.logFile
                rotateIfNeeded(url)
                if !FileManager.default.fileExists(atPath: url.path) {
                    FileManager.default.createFile(atPath: url.path, contents: nil)
                }
                let handle = try FileHandle(forWritingTo: url)
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: Data(line.utf8))
            } catch {
                // Logging must never crash the app; unified log still has it.
            }
        }
    }

    private static func rotateIfNeeded(_ url: URL) {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? UInt64, size > maxFileBytes else { return }
        let old = url.deletingPathExtension().appendingPathExtension("old.log")
        try? FileManager.default.removeItem(at: old)
        try? FileManager.default.moveItem(at: url, to: old)
    }
}
