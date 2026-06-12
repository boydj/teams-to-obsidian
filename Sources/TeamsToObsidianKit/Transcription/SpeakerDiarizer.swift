import Foundation

/// A labeled time range on the system-audio timeline. Used both for
/// diarization clusters ("Speaker 1") and Teams active-speaker capture
/// (real names).
struct SpeakerInterval: Codable, Equatable {
    let startMS: Int
    let endMS: Int
    let label: String
}

enum DiarizationError: Error, LocalizedError {
    case notConfigured(String)
    case failed(exitCode: Int32, stderrTail: String)
    case timedOut(TimeInterval)

    var errorDescription: String? {
        switch self {
        case .notConfigured(let what):
            return "Diarization is enabled but \(what) — run scripts/setup-diarization.sh or fix the diarization paths in the config."
        case let .failed(code, tail):
            return "sherpa-onnx diarization exited with code \(code): \(tail)"
        case .timedOut(let seconds):
            return "Diarization timed out after \(Int(seconds))s"
        }
    }
}

/// Splits the mixed Teams-output channel into per-speaker turns using
/// sherpa-onnx's offline speaker diarization CLI (pyannote segmentation +
/// speaker-embedding clustering), invoked as a subprocess like whisper.
/// Fully local; models are downloaded once by scripts/setup-diarization.sh.
///
/// stdout format (verified against sherpa-onnx source):
///   0.318 -- 6.865 speaker_00
final class SpeakerDiarizer {
    private let config: Config.Diarization

    init(config: Config.Diarization) {
        self.config = config
    }

    func diarize(wav: URL) async throws -> [SpeakerInterval] {
        let binary = Paths.expand(config.binaryPath)
        let segmentation = Paths.expand(config.segmentationModelPath)
        let embedding = Paths.expand(config.embeddingModelPath)
        guard FileManager.default.isExecutableFile(atPath: binary.path) else {
            throw DiarizationError.notConfigured("the binary was not found at \(binary.path)")
        }
        guard FileManager.default.fileExists(atPath: segmentation.path) else {
            throw DiarizationError.notConfigured("the segmentation model was not found at \(segmentation.path)")
        }
        guard FileManager.default.fileExists(atPath: embedding.path) else {
            throw DiarizationError.notConfigured("the embedding model was not found at \(embedding.path)")
        }

        var args = [
            "--segmentation.pyannote-model=\(segmentation.path)",
            "--embedding.model=\(embedding.path)",
        ]
        if config.numSpeakers > 0 {
            args.append("--clustering.num-clusters=\(config.numSpeakers)")
        } else {
            args.append("--clustering.cluster-threshold=\(config.clusterThreshold)")
        }
        args.append(wav.path)

        let audioSeconds = WAVWriter.dataDurationSeconds(at: wav) ?? 0
        let timeout = max(600, audioSeconds * 2)

        Log.info("Diarizing \(wav.lastPathComponent) (~\(Int(audioSeconds))s of audio)...")
        let result = try await SubprocessRunner.run(
            executable: binary, arguments: args, timeout: timeout, captureStdout: true)
        if result.timedOut {
            throw DiarizationError.timedOut(timeout)
        }
        guard result.exitCode == 0 else {
            throw DiarizationError.failed(exitCode: result.exitCode,
                                          stderrTail: String(result.stderr.suffix(1000)))
        }
        let turns = Self.parse(stdout: result.stdout)
        Log.info("Diarization found \(Set(turns.map(\.label)).count) speaker(s) across \(turns.count) turn(s).")
        return turns
    }

    /// Parses "0.318 -- 6.865 speaker_00" lines; speaker_00 → "Speaker 1".
    static func parse(stdout: String) -> [SpeakerInterval] {
        var turns: [SpeakerInterval] = []
        for line in stdout.split(separator: "\n") {
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            // start, "--", end, speaker_NN
            guard parts.count >= 4, parts[1] == "--",
                  let start = Double(parts[0]),
                  let end = Double(parts[2]),
                  parts[3].hasPrefix("speaker_"),
                  let index = Int(parts[3].dropFirst("speaker_".count)) else { continue }
            turns.append(SpeakerInterval(startMS: Int((start * 1000).rounded()),
                                         endMS: Int((end * 1000).rounded()),
                                         label: "Speaker \(index + 1)"))
        }
        return turns
    }
}
