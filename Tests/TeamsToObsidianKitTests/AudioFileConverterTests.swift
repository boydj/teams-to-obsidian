import XCTest
@testable import TeamsToObsidianKit

final class AudioFileConverterTests: XCTestCase {
    private func tempURL(_ ext: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("tto-conv-\(UUID().uuidString).\(ext)")
    }

    func testWriterOutputIsDetectedAsCanonical() throws {
        let url = tempURL("wav")
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = try WAVWriter(url: url)            // 16 kHz mono 16-bit
        writer.append(samples: [Int16](repeating: 100, count: 8_000))
        writer.finalize()
        XCTAssertTrue(AudioFileConverter.isCanonical16kMonoWAV(url))
    }

    func testFastPathCopiesConformingWAV() throws {
        let input = tempURL("wav")
        let output = tempURL("wav")
        defer {
            try? FileManager.default.removeItem(at: input)
            try? FileManager.default.removeItem(at: output)
        }
        let writer = try WAVWriter(url: input)
        writer.append(samples: (0..<16_000).map { Int16(truncatingIfNeeded: $0) })  // 1s
        writer.finalize()

        try AudioFileConverter.convertTo16kMonoWAV(input: input, output: output)

        // Byte-identical copy, and still a valid 1-second 16 kHz WAV.
        XCTAssertEqual(try Data(contentsOf: input), try Data(contentsOf: output))
        XCTAssertEqual(WAVWriter.dataDurationSeconds(at: output), 1.0)
    }

    func testRejectsNonCanonicalHeaders() throws {
        let url = tempURL("wav")
        defer { try? FileManager.default.removeItem(at: url) }
        // 44.1 kHz stereo — must NOT take the fast path.
        var header = WAVWriter.header(dataSize: 0, sampleRate: 44_100)
        // (header() always emits mono; flip channels to 2 to simulate non-conforming)
        header[22] = 2
        try header.write(to: url)
        XCTAssertFalse(AudioFileConverter.isCanonical16kMonoWAV(url))
    }

    func testRejectsTooShortFile() throws {
        let url = tempURL("wav")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data([0x52, 0x49, 0x46, 0x46]).write(to: url)   // just "RIFF"
        XCTAssertFalse(AudioFileConverter.isCanonical16kMonoWAV(url))
    }
}
