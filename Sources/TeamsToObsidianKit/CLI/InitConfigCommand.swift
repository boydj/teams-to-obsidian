import ArgumentParser
import Foundation

struct InitConfigCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "init-config",
        abstract: "Write the default config to ~/.config/teams-to-obsidian/config.json.")

    @Flag(help: "Overwrite an existing config file.")
    var force = false

    func run() throws {
        let url = try ConfigLoader.writeDefault(force: force)
        print("Wrote \(url.path)")
        print("Next: edit vault.path to point at your Obsidian vault, then run scripts/setup-whisper.sh.")
    }
}
