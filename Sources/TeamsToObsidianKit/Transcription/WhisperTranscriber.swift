import Foundation

struct WhisperSegment: Equatable {
    let startMS: Int
    let endMS: Int
    let text: String
}

enum WhisperError: Error, LocalizedError {
    case cliNotFound(String)
    case modelNotFound(String)
    case failed(exitCode: Int32, stderrTail: String)
    case timedOut(TimeInterval)
    case badOutput(String)

    var errorDescription: String? {
        switch self {
        case .cliNotFound(let path):
            return "whisper-cli not found at \(path) — run scripts/setup-whisper.sh or fix whisper.cliPath in the config."
        case .modelNotFound(let path):
            return "Whisper model not found at \(path) — run scripts/setup-whisper.sh or fix whisper.modelPath in the config."
        case let .failed(code, tail):
            return "whisper-cli exited with code \(code): \(tail)"
        case .timedOut(let seconds):
            return "whisper-cli timed out after \(Int(seconds))s"
        case .badOutput(let detail):
            return "Could not parse whisper-cli JSON output: \(detail)"
        }
    }
}

/// Invokes whisper.cpp's whisper-cli as a subprocess and parses its JSON
/// segment output (`-oj`: offsets are in milliseconds).
final class WhisperTranscriber {
    private let config: Config.Whisper

    init(config: Config.Whisper) {
        self.config = config
    }

    func transcribe(wav: URL) async throws -> [WhisperSegment] {
        let cli = Paths.expand(config.cliPath)
        let model = Paths.expand(config.modelPath)
        guard FileManager.default.isExecutableFile(atPath: cli.path) else {
            throw WhisperError.cliNotFound(cli.path)
        }
        guard FileManager.default.fileExists(atPath: model.path) else {
            throw WhisperError.modelNotFound(model.path)
        }

        let outputBase = FileManager.default.temporaryDirectory
            .appendingPathComponent("tto-whisper-\(UUID().uuidString)")
        let jsonURL = URL(fileURLWithPath: outputBase.path + ".json")
        defer { try? FileManager.default.removeItem(at: jsonURL) }

        var args = [
            "-m", model.path,
            "-f", wav.path,
            "-l", config.language,
            "-oj",
            "-of", outputBase.path,
            "--no-prints",
        ]
        if config.threads > 0 {
            args += ["-t", String(config.threads)]
        }

        let audioSeconds = WAVWriter.dataDurationSeconds(at: wav) ?? 0
        let timeout = max(600, audioSeconds * 3)

        Log.info("Transcribing \(wav.lastPathComponent) (~\(Int(audioSeconds))s of audio)...")
        let result = try await SubprocessRunner.run(executable: cli, arguments: args, timeout: timeout)
        if result.timedOut {
            throw WhisperError.timedOut(timeout)
        }
        guard result.exitCode == 0 else {
            throw WhisperError.failed(exitCode: result.exitCode, stderrTail: String(result.stderr.suffix(2000)))
        }
        let data: Data
        do {
            data = try Data(contentsOf: jsonURL)
        } catch {
            throw WhisperError.badOutput("missing output file \(jsonURL.lastPathComponent); stderr: \(result.stderr.suffix(500))")
        }
        return try Self.parse(json: data)
    }

    static func parse(json: Data) throws -> [WhisperSegment] {
        struct Output: Decodable {
            struct Item: Decodable {
                struct Offsets: Decodable {
                    let from: Int
                    let to: Int
                }
                let offsets: Offsets
                let text: String
            }
            let transcription: [Item]
        }
        let decoded: Output
        do {
            decoded = try JSONDecoder().decode(Output.self, from: json)
        } catch {
            throw WhisperError.badOutput(String(describing: error))
        }
        return decoded.transcription.map {
            WhisperSegment(startMS: $0.offsets.from,
                           endMS: $0.offsets.to,
                           text: $0.text.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }
}
