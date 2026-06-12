import ArgumentParser
import Foundation

/// Offline harness: runs the full transcribe→summarize→note pipeline on
/// existing audio files, no meeting (or permissions) required.
struct ProcessCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "process",
        abstract: "Run the transcribe → summarize → note pipeline on existing audio files.")

    @Option(help: "Audio file with YOUR side of the meeting (any format AVFoundation reads).")
    var mic: String?

    @Option(help: "Audio file with the OTHER participants (e.g. captured Teams output).")
    var system: String?

    @Option(help: "Override the note title instead of using the AI-generated one.")
    var title: String?

    @Option(help: "Path to a config file (default: ~/.config/teams-to-obsidian/config.json).")
    var config: String?

    func run() async throws {
        guard mic != nil || system != nil else {
            throw ValidationError("Provide at least one of --mic or --system.")
        }
        let cfg = try ConfigLoader.load(path: config)

        // Build a synthetic session; inputs are converted into it, never touched.
        let session = try RecordingSession.create(in: cfg.recordingsDir, partial: false)
        var inputDate: Date?
        if let mic {
            let input = Paths.expand(mic)
            print("Converting \(input.lastPathComponent)…")
            try AudioFileConverter.convertTo16kMonoWAV(input: input, output: session.micWAVURL)
            inputDate = inputDate ?? fileDate(input)
        }
        if let system {
            let input = Paths.expand(system)
            print("Converting \(input.lastPathComponent)…")
            try AudioFileConverter.convertTo16kMonoWAV(input: input, output: session.systemWAVURL)
            inputDate = inputDate ?? fileDate(input)
        }

        let duration = max(WAVWriter.dataDurationSeconds(at: session.micWAVURL) ?? 0,
                           WAVWriter.dataDurationSeconds(at: session.systemWAVURL) ?? 0)
        // The input's mtime approximates the meeting end.
        let endedAt = inputDate ?? Date()
        session.update { m in
            m.startedAt = endedAt.addingTimeInterval(-duration)
            m.endedAt = endedAt
        }

        let pipeline = MeetingPipeline(config: cfg)
        let outcome = await pipeline.run(session: session,
                                         titleOverride: title,
                                         ignoreMinDuration: true) { state in
            switch state {
            case .transcribing: print("Transcribing…")
            case .summarizing: print("Summarizing…")
            case .done(let url): print("Note written: \(url.path)")
            case .failed(let message): print("Failed: \(message)")
            case .discarded: print("Discarded (below minimum duration).")
            }
        }
        if outcome.noteURL == nil {
            throw ExitCode.failure
        }
    }

    private func fileDate(_ url: URL) -> Date? {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        return attrs?[.modificationDate] as? Date
    }
}
