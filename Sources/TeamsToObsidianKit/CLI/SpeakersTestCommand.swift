import ApplicationServices
import ArgumentParser
import Foundation

/// Companion to the experimental active-speaker capture: run it DURING a real
/// Teams meeting. --dump shows every accessibility string Teams exposes so you
/// can discover what the active-speaker indicator looks like and tune
/// context.activeSpeakerPattern; without --dump it shows live matches and the
/// intervals that would be recorded.
struct SpeakersTestCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "speakers-test",
        abstract: "Probe the Teams accessibility tree for active-speaker names (run during a meeting).")

    @Option(help: "Seconds to observe.")
    var seconds: Int = 30

    @Option(help: "Override the active-speaker regex (capture group 1 = name).")
    var pattern: String?

    @Flag(help: "Print every accessibility string Teams exposes (deduplicated) instead of matching.")
    var dump = false

    func run() async throws {
        guard AXIsProcessTrusted() else {
            throw CLIError("""
            Accessibility permission not granted for this process. Grant your terminal \
            app in System Settings → Privacy & Security → Accessibility, then re-run.
            """)
        }
        let patternString = pattern ?? Config().context.activeSpeakerPattern
        guard let regex = try? NSRegularExpression(pattern: patternString) else {
            throw CLIError("Invalid regex: \(patternString)")
        }
        print(dump
            ? "Dumping Teams accessibility strings for \(seconds)s — join a meeting and have someone speak…"
            : "Watching for active speakers for \(seconds)s with pattern: \(patternString)")

        var seenStrings: Set<String> = []
        var seenNames: Set<String> = []
        for tick in 0..<max(1, seconds) {
            let strings = ActiveSpeakerObserver.collectTeamsStrings()
            if dump {
                for s in strings where !seenStrings.contains(s) {
                    seenStrings.insert(s)
                    print("  \(s.prefix(200))")
                }
            } else {
                let names = ActiveSpeakerObserver.matchNames(in: strings, regex: regex)
                for name in names where !seenNames.contains(name) {
                    seenNames.insert(name)
                }
                if !names.isEmpty {
                    print("[t+\(tick)s] speaking: \(names.sorted().joined(separator: ", "))")
                }
            }
            try await Task.sleep(nanoseconds: 1_000_000_000)
        }

        if dump {
            print("\n\(seenStrings.count) distinct strings seen. Look for one that appears only while someone talks, then set context.activeSpeakerPattern accordingly.")
        } else if seenNames.isEmpty {
            print("\nNo matches. Try --dump to inspect what Teams exposes, then tune context.activeSpeakerPattern.")
        } else {
            print("\nMatched name(s): \(seenNames.sorted().joined(separator: ", "))")
            print("Looks good — enable it with \"context\": { \"captureActiveSpeakers\": true } in the config.")
        }
    }
}
