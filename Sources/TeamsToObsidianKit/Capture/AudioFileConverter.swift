import AVFoundation
import Foundation

enum AudioFileConverter {
    /// Converts any audio file AVFoundation can read into the 16 kHz mono
    /// 16-bit WAV whisper-cli expects. Used by the `process` subcommand so
    /// users can feed it arbitrary recordings.
    static func convertTo16kMonoWAV(input: URL, output: URL) throws {
        // Fast path: the input is already a canonical 16 kHz mono 16-bit PCM
        // WAV (e.g. produced by `afconvert -d LEI16@16000 -c 1` or by this
        // app's own recorder). Copy it byte-for-byte and skip AVFoundation
        // entirely — which also sidesteps headless environments where the
        // audio codec services that back AVAudioFile aren't available.
        if isCanonical16kMonoWAV(input) {
            try? FileManager.default.removeItem(at: output)
            try FileManager.default.copyItem(at: input, to: output)
            return
        }

        do {
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
        } catch let error as CLIError {
            throw error
        } catch {
            // Wrap framework errors so they never surface as an opaque value.
            throw CLIError("Could not read audio file \(input.lastPathComponent) — "
                + "is it a supported audio format? Underlying error: "
                + "\(error.localizedDescription) [\(error)]")
        }
    }

    /// True when the file begins with the canonical 44-byte PCM WAV header for
    /// 16 kHz, 1 channel, 16-bit. Non-canonical-but-conforming files simply
    /// fall through to the AVFoundation path, so this only ever fast-paths
    /// files we are certain about.
    static func isCanonical16kMonoWAV(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        guard let header = try? handle.read(upToCount: 44), header.count == 44 else { return false }

        func tag(_ offset: Int) -> String? {
            String(data: header.subdata(in: offset..<(offset + 4)), encoding: .ascii)
        }
        func u32(_ offset: Int) -> UInt32 {
            header.subdata(in: offset..<(offset + 4)).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }.littleEndian
        }
        func u16(_ offset: Int) -> UInt16 {
            header.subdata(in: offset..<(offset + 2)).withUnsafeBytes { $0.loadUnaligned(as: UInt16.self) }.littleEndian
        }

        return tag(0) == "RIFF"
            && tag(8) == "WAVE"
            && tag(12) == "fmt "
            && u32(16) == 16        // PCM fmt-chunk size
            && u16(20) == 1         // audio format: PCM
            && u16(22) == 1         // channels: mono
            && u32(24) == 16_000    // sample rate
            && u16(34) == 16        // bits per sample
            && tag(36) == "data"
    }
}
