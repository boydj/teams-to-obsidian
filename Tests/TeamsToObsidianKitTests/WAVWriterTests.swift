import XCTest
@testable import TeamsToObsidianKit

final class WAVWriterTests: XCTestCase {
    private func tempWAV() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("tto-wav-\(UUID().uuidString).wav")
    }

    private func readUInt32LE(_ data: Data, at offset: Int) -> UInt32 {
        let raw = data.subdata(in: offset..<(offset + 4))
        return raw.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
    }

    func testWriteFinalizeAndHeader() throws {
        let url = tempWAV()
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = try WAVWriter(url: url)
        writer.append(samples: [Int16](repeating: 1000, count: 16_000))   // exactly 1 second
        writer.finalize()

        let data = try Data(contentsOf: url)
        XCTAssertEqual(data.count, 44 + 32_000)
        XCTAssertEqual(String(data: data.subdata(in: 0..<4), encoding: .ascii), "RIFF")
        XCTAssertEqual(String(data: data.subdata(in: 8..<12), encoding: .ascii), "WAVE")
        XCTAssertEqual(readUInt32LE(data, at: 40), 32_000)        // data chunk size
        XCTAssertEqual(readUInt32LE(data, at: 24), 16_000)        // sample rate
        XCTAssertEqual(WAVWriter.dataDurationSeconds(at: url), 1.0)
    }

    func testRepairHeaderAfterSimulatedCrash() throws {
        let url = tempWAV()
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = try WAVWriter(url: url)
        writer.append(samples: [Int16](repeating: 500, count: 8_000))     // 0.5 seconds
        _ = writer.durationSeconds   // barrier: waits for the queued write

        // No finalize() — simulates a crash; header still carries zero sizes.
        let before = try Data(contentsOf: url)
        XCTAssertEqual(readUInt32LE(before, at: 40), 0)

        try WAVWriter.repairHeader(at: url)
        let after = try Data(contentsOf: url)
        XCTAssertEqual(readUInt32LE(after, at: 40), 16_000)
        XCTAssertEqual(WAVWriter.dataDurationSeconds(at: url), 0.5)
        writer.finalize()
    }
}

final class WhisperTranscriberParseTests: XCTestCase {
    func testParsesWhisperJSON() throws {
        let json = """
        {"result": {"language": "en"}, "transcription": [
          {"timestamps": {"from": "00:00:00,000", "to": "00:00:07,440"},
           "offsets": {"from": 0, "to": 7440},
           "text": " And so my fellow Americans"}]}
        """
        let segments = try WhisperTranscriber.parse(json: Data(json.utf8))
        XCTAssertEqual(segments.count, 1)
        XCTAssertEqual(segments[0].startMS, 0)
        XCTAssertEqual(segments[0].endMS, 7440)
        XCTAssertEqual(segments[0].text, "And so my fellow Americans")
    }

    func testRejectsGarbage() {
        XCTAssertThrowsError(try WhisperTranscriber.parse(json: Data("not json".utf8)))
    }
}
