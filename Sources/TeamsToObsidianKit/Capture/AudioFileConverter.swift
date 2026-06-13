import AVFoundation
import Foundation

enum AudioFileConverter {
    /// Converts an audio file into the 16 kHz mono 16-bit WAV whisper-cli
    /// expects. Used by the `process` subcommand so users can feed it existing
    /// recordings.
    ///
    /// WAV input is read directly (no AVFoundation) so the common case never
    /// depends on AVAudioFile's codec services — which fail opaquely in some
    /// environments (surfacing as Foundation._GenericObjCError / "nilError").
    /// Non-WAV input (m4a, mp3, aiff, …) still goes through AVAudioFile.
    static func convertTo16kMonoWAV(input: URL, output: URL) throws {
        // 1. Already a canonical 16 kHz mono 16-bit PCM WAV (this app's own
        //    recordings) → byte copy, no decoding at all.
        if isCanonical16kMonoWAV(input) {
            try? FileManager.default.removeItem(at: output)
            try FileManager.default.copyItem(at: input, to: output)
            return
        }
        // 2. Any 16-bit PCM WAV (e.g. afconvert -d LEI16 output, with whatever
        //    extra chunks it inserts) → parse + resample without AVAudioFile.
        if let pcm = readPCM16WAV(input) {
            try writeResampled(samples: pcm.samples, sourceRate: pcm.sampleRate,
                               channels: pcm.channels, output: output)
            return
        }
        // 3. Other formats → AVAudioFile, wrapping framework errors so they
        //    never surface as an opaque value.
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
            throw CLIError("Could not read audio file \(input.lastPathComponent) — "
                + "unsupported or corrupt? Underlying error: "
                + "\(error.localizedDescription) [\(error)]")
        }
    }

    // MARK: - Direct WAV reading

    private struct PCM16 {
        let samples: [Int16]            // interleaved
        let sampleRate: Double
        let channels: AVAudioChannelCount
    }

    /// Parses a 16-bit integer PCM WAV by walking RIFF chunks (tolerant of
    /// FLLR/fact/extra chunks and a non-16-byte fmt). Returns nil for anything
    /// that isn't 16-bit integer PCM, so the caller falls back to AVAudioFile.
    /// macOS hosts are little-endian, matching WAV, so samples copy directly.
    private static func readPCM16WAV(_ url: URL) -> PCM16? {
        guard let data = try? Data(contentsOf: url), data.count >= 12 else { return nil }

        func tag(_ o: Int) -> String {
            guard o + 4 <= data.count else { return "" }
            return String(data: data.subdata(in: o..<(o + 4)), encoding: .ascii) ?? ""
        }
        func u32(_ o: Int) -> UInt32 {
            data.subdata(in: o..<(o + 4)).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }.littleEndian
        }
        func u16(_ o: Int) -> UInt16 {
            data.subdata(in: o..<(o + 2)).withUnsafeBytes { $0.loadUnaligned(as: UInt16.self) }.littleEndian
        }

        guard tag(0) == "RIFF", tag(8) == "WAVE" else { return nil }

        var fmt: (format: UInt16, channels: UInt16, rate: UInt32, bits: UInt16)?
        var dataRange: Range<Int>?
        var offset = 12
        while offset + 8 <= data.count {
            let chunkID = tag(offset)
            let chunkSize = Int(u32(offset + 4))
            let body = offset + 8
            if chunkID == "fmt ", body + 16 <= data.count {
                fmt = (u16(body), u16(body + 2), u32(body + 4), u16(body + 14))
            } else if chunkID == "data" {
                dataRange = body..<min(body + chunkSize, data.count)
            }
            // RIFF chunks are word-aligned: odd sizes carry a pad byte.
            offset = body + chunkSize + (chunkSize & 1)
        }

        guard let fmt, let dataRange, fmt.format == 1, fmt.bits == 16,
              fmt.channels >= 1, fmt.rate > 0, !dataRange.isEmpty else { return nil }

        let bytes = data.subdata(in: dataRange)
        let count = bytes.count / 2
        var samples = [Int16](repeating: 0, count: count)
        samples.withUnsafeMutableBytes { dst in
            bytes.withUnsafeBytes { src in
                dst.copyMemory(from: UnsafeRawBufferPointer(rebasing: src[0..<(count * 2)]))
            }
        }
        return PCM16(samples: samples, sampleRate: Double(fmt.rate), channels: AVAudioChannelCount(fmt.channels))
    }

    /// Feeds interleaved 16-bit samples through the shared Resampler
    /// (AVAudioConverter handles downmix + resample to 16 kHz mono int16).
    private static func writeResampled(samples: [Int16], sourceRate: Double,
                                       channels: AVAudioChannelCount, output: URL) throws {
        guard let inputFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: sourceRate,
                                              channels: channels, interleaved: true),
              let resampler = Resampler(inputFormat: inputFormat) else {
            throw CLIError("Unsupported WAV format: \(Int(sourceRate)) Hz, \(channels) channel(s)")
        }
        let writer = try WAVWriter(url: output)
        let totalFrames = samples.count / Int(channels)
        let chunkFrames = 65_536
        var frame = 0
        while frame < totalFrames {
            let n = min(chunkFrames, totalFrames - frame)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: AVAudioFrameCount(n)),
                  let dst = buffer.int16ChannelData else { break }
            buffer.frameLength = AVAudioFrameCount(n)
            let base = frame * Int(channels)
            let span = n * Int(channels)
            samples.withUnsafeBufferPointer { src in
                dst[0].update(from: src.baseAddress! + base, count: span)
            }
            writer.append(samples: resampler.convert(buffer))
            frame += n
        }
        writer.finalize()
    }

    // MARK: - Canonical-header fast path

    /// True when the file begins with the canonical 44-byte PCM WAV header for
    /// 16 kHz, 1 channel, 16-bit (what WAVWriter emits).
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
