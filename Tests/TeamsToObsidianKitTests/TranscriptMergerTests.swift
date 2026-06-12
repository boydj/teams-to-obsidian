import XCTest
@testable import TeamsToObsidianKit

final class TranscriptMergerTests: XCTestCase {
    private func seg(_ start: Int, _ end: Int, _ text: String) -> WhisperSegment {
        WhisperSegment(startMS: start, endMS: end, text: text)
    }

    func testInterleavesBySpeakerAndTime() {
        let me = [seg(0, 1000, "Hello"), seg(5000, 6000, "Sure thing")]
        let them = [seg(2000, 4000, "Hi, can you send the report?")]
        let merged = TranscriptMerger.merge(me: me, them: them)
        let blocks = merged.components(separatedBy: "\n\n")
        XCTAssertEqual(blocks.count, 3)
        XCTAssertTrue(blocks[0].hasPrefix("**Me** [0:00:00]: Hello"))
        XCTAssertTrue(blocks[1].hasPrefix("**Them** [0:00:02]: Hi"))
        XCTAssertTrue(blocks[2].hasPrefix("**Me** [0:00:05]: Sure"))
    }

    func testCoalescesSameSpeakerWithinGap() {
        let me = [seg(0, 1000, "One"), seg(1500, 2500, "two")]
        let entries = TranscriptMerger.mergedEntries(me: me, them: [])
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].text, "One two")
        XCTAssertEqual(entries[0].endMS, 2500)
    }

    func testDoesNotCoalesceAcrossLargeGap() {
        let me = [seg(0, 1000, "One"), seg(4000, 5000, "two")]
        XCTAssertEqual(TranscriptMerger.mergedEntries(me: me, them: []).count, 2)
    }

    func testFiltersNonSpeechAnnotations() {
        let me = [
            seg(0, 1000, "[BLANK_AUDIO]"),
            seg(2000, 3000, "(music)"),
            seg(4000, 5000, "real words"),
            seg(6000, 7000, "   "),
        ]
        let entries = TranscriptMerger.mergedEntries(me: me, them: [])
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].text, "real words")
    }

    func testEmptyChannelsAreFine() {
        XCTAssertEqual(TranscriptMerger.merge(me: [], them: []), "")
        let onlyThem = TranscriptMerger.merge(me: [], them: [seg(0, 1000, "hello")])
        XCTAssertTrue(onlyThem.contains("**Them**"))
    }

    func testShift() {
        let shifted = TranscriptMerger.shift([seg(1000, 2000, "x")], byMS: 500)
        XCTAssertEqual(shifted[0].startMS, 1500)
        XCTAssertEqual(shifted[0].endMS, 2500)
    }

    func testTimestampFormat() {
        XCTAssertEqual(TranscriptMerger.timestamp(0), "0:00:00")
        XCTAssertEqual(TranscriptMerger.timestamp(3_725_000), "1:02:05")
    }
}
