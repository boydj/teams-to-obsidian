import ArgumentParser
import CoreAudio
import Foundation

/// Drives the recorders directly: validates capture against a deterministic
/// source (Music.app) before trusting it with a real meeting, and doubles as
/// the TCC-prompt trigger when run from a terminal.
struct RecordTestCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "record-test",
        abstract: "Capture a short test recording (also triggers the macOS permission prompts).")

    @Option(help: "Seconds to record.")
    var seconds: Int = 10

    @Option(name: .customLong("bundle-id"),
            help: "Tap processes whose bundle ID starts with this prefix.")
    var bundleID: String = "com.apple.Music"

    @Flag(name: .customLong("mic-only"), help: "Record only the microphone.")
    var micOnly = false

    @Flag(name: .customLong("system-only"), help: "Record only system/process audio.")
    var systemOnly = false

    @Flag(help: "Tap ALL system audio instead of one process (globalExclude mode).")
    var global = false

    @Option(help: "Output directory (default: the temporary directory).")
    var out: String?

    func run() async throws {
        let outDir = out.map(Paths.expand) ?? FileManager.default.temporaryDirectory
        try Paths.ensureDir(outDir)
        let stamp = Int(Date().timeIntervalSince1970)

        var micRecorder: MicRecorder?
        var micWriter: WAVWriter?
        var tapRecorder: ProcessTapRecorder?
        var tapWriter: WAVWriter?

        if !systemOnly {
            let url = outDir.appendingPathComponent("tto-mic-test-\(stamp).wav")
            let writer = try WAVWriter(url: url)
            let recorder = MicRecorder(writer: writer, voiceProcessing: false)
            try recorder.start()
            micRecorder = recorder
            micWriter = writer
            print("Recording mic → \(url.path)")
        }

        if !micOnly {
            let url = outDir.appendingPathComponent("tto-system-test-\(stamp).wav")
            let writer = try WAVWriter(url: url)
            let mode: ProcessTapRecorder.Mode
            if global {
                print("Tapping ALL system audio (globalExclude mode)")
                mode = .globalExcludingNone
            } else {
                let processes = ((try? AudioObjectID.readProcessList()) ?? [])
                    .filter { $0.processBundleID.hasPrefix(bundleID) }
                guard !processes.isEmpty else {
                    throw CLIError("""
                    No audio process found with bundle ID prefix "\(bundleID)". \
                    Is the app running (and has it played audio)? \
                    Try --global to tap all system audio instead.
                    """)
                }
                print("Tapping \(processes.count) process(es) with prefix \(bundleID)")
                mode = .processes(processes)
            }
            let recorder = ProcessTapRecorder(mode: mode, writer: writer)
            try recorder.start()
            tapRecorder = recorder
            tapWriter = writer
            print("Recording system audio → \(url.path)")
        }

        print("Recording for \(seconds)s…")
        try await Task.sleep(nanoseconds: UInt64(max(1, seconds)) * 1_000_000_000)

        micRecorder?.stop()
        tapRecorder?.stop()
        if let micWriter {
            micWriter.finalize()
            print("Mic: \(String(format: "%.1f", micWriter.durationSeconds))s written")
        }
        if let tapWriter, let tapRecorder {
            tapWriter.finalize()
            let peak = tapRecorder.peakRMS
            var line = "System: \(String(format: "%.1f", tapWriter.durationSeconds))s written, peak RMS \(String(format: "%.4f", peak))"
            if peak < 0.001 {
                line += "  ⚠️ looks silent — see the troubleshooting section in the README"
            }
            print(line)
        }
    }
}
