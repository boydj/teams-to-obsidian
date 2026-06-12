import AppKit
import ArgumentParser
import Foundation

struct RunCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "run",
        abstract: "Run the menu bar app (the default subcommand).")

    // @MainActor puts us on the main thread, which NSApplication requires.
    // app.run() never returns; Quit terminates the process directly.
    @MainActor
    mutating func run() async throws {
        let (config, problem) = ConfigLoader.loadOrDefault()
        let app = NSApplication.shared
        let delegate = AppDelegate(config: config, configProblem: problem)
        AppHolder.delegate = delegate
        app.delegate = delegate
        app.setActivationPolicy(.accessory)   // menu bar only, no Dock icon
        app.run()
    }
}
