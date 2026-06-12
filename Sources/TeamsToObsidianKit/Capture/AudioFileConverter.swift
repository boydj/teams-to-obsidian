import AVFoundation
import Foundation

enum AudioFileConverter {
    /// Converts any audio file AVFoundation can read into the 16 kHz mono
    /// 16-bit WAV whisper-cli expects. Used by the `process` subcommand so
    /// users can feed it arbitrary recordings.
    static func convertTo16kMonoWAV(input: URL, output: URL) throws {
        let file = try AVAudioFile(forReading: input)
        guard let resampler = Resampler(inputFormat: file.processingFormat) else {
            throw CLIError("Unsupported audio format in \(input.path)")
        }
        let writer = try WAVWriter(url: output)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 65_536) else {
            throw CLIError("Could not allocate audio buffer")
        }
        while true {
            try file.read(into: buffer)
            if buffer.frameLength == 0 { break }
            writer.append(samples: resampler.convert(buffer))
        }
        writer.finalize()
    }
}
