import Foundation

enum ConfigError: Error, LocalizedError {
    case malformed(URL, String)

    var errorDescription: String? {
        switch self {
        case let .malformed(url, detail):
            return "Config file at \(url.path) is not valid JSON: \(detail)"
        }
    }
}

enum ConfigLoader {
    /// Strict load for CLI commands: missing file → defaults; malformed file → error.
    static func load(path: String? = nil) throws -> Config {
        let url = path.map(Paths.expand) ?? Paths.configFile
        guard FileManager.default.fileExists(atPath: url.path) else {
            Log.info("No config at \(url.path); using defaults (run `teams-to-obsidian init-config`).")
            return Config()
        }
        let data = try Data(contentsOf: url)
        do {
            return try JSONDecoder().decode(Config.self, from: data)
        } catch {
            throw ConfigError.malformed(url, String(describing: error))
        }
    }

    /// Lenient load for the menu bar app: never fails, returns a problem
    /// description instead so the UI can surface it.
    static func loadOrDefault() -> (config: Config, problem: String?) {
        do {
            return (try load(), nil)
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
            Log.error(message)
            return (Config(), message)
        }
    }

    /// Writes the default config. Returns the path written.
    @discardableResult
    static func writeDefault(force: Bool) throws -> URL {
        try Paths.ensureDir(Paths.configDir)
        let url = Paths.configFile
        if FileManager.default.fileExists(atPath: url.path) && !force {
            throw CLIError("Config already exists at \(url.path) — use --force to overwrite.")
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(Config())
        try data.write(to: url, options: .atomic)
        return url
    }
}

/// Simple error type whose description is the message itself; used by CLI paths.
struct CLIError: Error, LocalizedError, CustomStringConvertible {
    let message: String
    init(_ message: String) { self.message = message }
    var description: String { message }
    var errorDescription: String? { message }
}
