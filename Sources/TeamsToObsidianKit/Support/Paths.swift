import Foundation

enum Paths {
    static func expand(_ path: String) -> URL {
        URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
    }

    static var configDir: URL { expand("~/.config/teams-to-obsidian") }
    static var configFile: URL { configDir.appendingPathComponent("config.json") }
    static var logDir: URL { expand("~/Library/Logs/teams-to-obsidian") }
    static var logFile: URL { logDir.appendingPathComponent("teams-to-obsidian.log") }

    @discardableResult
    static func ensureDir(_ url: URL) throws -> URL {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
