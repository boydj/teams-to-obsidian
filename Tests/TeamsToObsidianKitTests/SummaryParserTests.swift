import XCTest
@testable import TeamsToObsidianKit

final class SummaryParserTests: XCTestCase {
    private let date = Date(timeIntervalSince1970: 1_700_000_000)

    func testParsesFencedJSON() {
        let raw = """
        Here you go:
        ```json
        {"title": "Quarterly Planning", "summary": "We planned.", "key_points": ["a"], \
        "action_items": ["Me: do x"], "decisions": ["ship it"]}
        ```
        """
        let s = SummaryParser.parse(raw, meetingDate: date)
        XCTAssertEqual(s.title, "Quarterly Planning")
        XCTAssertEqual(s.summary, "We planned.")
        XCTAssertEqual(s.keyPoints, ["a"])
        XCTAssertEqual(s.actionItems, ["Me: do x"])
        XCTAssertEqual(s.decisions, ["ship it"])
        XCTAssertNil(s.warning)
    }

    func testParsesBareJSONWithSurroundingProse() {
        let raw = #"Sure! {"title": "T", "summary": "S", "key_points": [], "action_items": [], "decisions": []} Hope that helps."#
        XCTAssertEqual(SummaryParser.parse(raw, meetingDate: date).title, "T")
    }

    func testFallsBackToRawText() {
        let raw = "I could not produce JSON, sorry. The meeting was about cats."
        let s = SummaryParser.parse(raw, meetingDate: date)
        XCTAssertNotNil(s.warning)
        XCTAssertTrue(s.summary.contains("about cats"))
        XCTAssertTrue(s.title.hasPrefix("Teams Meeting"))
    }

    func testMissingFieldsGetDefaults() {
        let raw = #"{"summary": "Only a summary"}"#
        let s = SummaryParser.parse(raw, meetingDate: date)
        XCTAssertTrue(s.title.hasPrefix("Teams Meeting"))
        XCTAssertEqual(s.summary, "Only a summary")
        XCTAssertEqual(s.actionItems, [])
        XCTAssertNil(s.warning)
    }

    func testLongTitleTruncated() {
        let long = String(repeating: "x", count: 200)
        let raw = "{\"title\": \"\(long)\", \"summary\": \"s\"}"
        XCTAssertLessThanOrEqual(SummaryParser.parse(raw, meetingDate: date).title.count, 80)
    }
}
