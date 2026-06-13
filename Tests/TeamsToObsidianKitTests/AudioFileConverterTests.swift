import XCTest
@testable import TeamsToObsidianKit

final class AudioFileConverterTests: XCTestCase {
    private func tempURL(_ ext: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("tto-conv-\(UUID().uuidString).\(ext)")
    }

    /// Builds a 16-bit PCM WAV, optionally inserting a non-data chunk before
    /// `data` (as afconvert does) so the file is conforming but not canonical.
    private func makeWAV(sampleRate: UInt32, channels: UInt16, frames: Int, extraChunk: Bool) -> Data {
        var body = Data()
        func tag(_ s: String) { body.append(contentsOf: Array(s.utf8)) }
        func le16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { body.append(contentsOf: $0) } }
        func le32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { body.append(contentsOf: $0) } }

        let blockAlign = channels * 2
        let dataBytes = frames * Int(blockAlign)

        tag("WAVE")
        tag("fmt "); le32(16)
        le16(1); le16(channels); le32(sampleRate)
        le32(sampleRate * UInt32(blockAlign)); le16(blockAlign); le16(16)
        if extraChunk {
            tag("FLLR"); le32(4); le32(0)        // 4-byte filler chunk
        }
        tag("data"); le32(UInt32(dataBytes))
        for i in 0..<(frames * Int(channels)) {
            le16(UInt16(truncatingIfNeeded: i))
        }

        var out = Data()
        out.append(contentsOf: Array("RIFF".utf8))
        withUnsafeBytes(of: UInt32(body.count).littleEndian) { out.append(contentsOf: $0) }
        out.append(body)
        return out
    }

    func testWriterOutputIsDetectedAsCanonical() throws {
        let url = tempURL("wav")
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = try WAVWriter(url: url)
        writer.append(samples: [Int16](repeating: 100, count: 8_000))
        writer.finalize()
        XCTAssertTrue(AudioFileConverter.isCanonical16kMonoWAV(url))
    }

    func testFastPathCopiesConformingWAV() throws {
        let input = tempURL("wav"); let output = tempURL("wav")
        defer { try? FileManager.default.removeItem(at: input); try? FileManager.default.removeItem(at: output) }
        let writer = try WAVWriter(url: input)
        writer.append(samples: (0..<16_000).map { Int16(truncatingIfNeeded: $0) })   // 1s
        writer.finalize()

        try AudioFileConverter.convertTo16kMonoWAV(input: input, output: output)
        XCTAssertEqual(try Data(contentsOf: input), try Data(contentsOf: output))
        XCTAssertEqual(WAVWriter.dataDurationSeconds(at: output), 1.0)
    }

    /// The afconvert-like case that previously failed with nilError: a 16 kHz
    /// mono 16-bit WAV that isn't byte-canonical (extra chunk) must convert via
    /// the direct reader, NOT AVAudioFile.
    func testNonCanonical16kMonoWavTakesDirectPath() throws {
        let input = tempURL("wav"); let output = tempURL("wav")
        defer { try? FileManager.default.removeItem(at: input); try? FileManager.default.removeItem(at: output) }
        try makeWAV(sampleRate: 16_000, channels: 1, frames: 16_000, extraChunk: true).write(to: input)

        XCTAssertFalse(AudioFileConverter.isCanonical16kMonoWAV(input))   // forces chunk-walk path
        try AudioFileConverter.convertTo16kMonoWAV(input: input, output: output)

        XCTAssertTrue(AudioFileConverter.isCanonical16kMonoWAV(output))   // output is canonical
        XCTAssertEqual(WAVWriter.dataDurationSeconds(at: output) ?? 0, 1.0, accuracy: 0.05)
    }

    func testStereo44kResamplesToMono16k() throws {
        let input = tempURL("wav"); let output = tempURL("wav")
        defer { try? FileManager.default.removeItem(at: input); try? FileManager.default.removeItem(at: output) }
        try makeWAV(sampleRate: 44_100, channels: 2, frames: 44_100, extraChunk: false).write(to: input)

        try AudioFileConverter.convertTo16kMonoWAV(input: input, output: output)
        XCTAssertTrue(AudioFileConverter.isCanonical16kMonoWAV(output))
        XCTAssertEqual(WAVWriter.dataDurationSeconds(at: output) ?? 0, 1.0, accuracy: 0.1)
    }

    func testRejectsTooShortFile() throws {
        let url = tempURL("wav")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data([0x52, 0x49, 0x46, 0x46]).write(to: url)   // just "RIFF"
        XCTAssertFalse(AudioFileConverter.isCanonical16kMonoWAV(url))
    }
}
