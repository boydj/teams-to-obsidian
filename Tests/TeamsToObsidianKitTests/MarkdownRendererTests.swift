import XCTest
@testable import TeamsToObsidianKit

final class MarkdownRendererTests: XCTestCase {
    func testFullNote() {
        let summary = MeetingSummary(
            title: "My \"Quoted\" Title", summary: "Body.",
            keyPoints: ["k"], actionItems: ["a"], decisions: ["d"], warning: nil)
        let md = MarkdownRenderer.render(
            summary: summary,
            transcript: "**Me** [0:00:00]: hi",
            startedAt: Date(timeIntervalSince1970: 0),
            durationSeconds: 600,
            partial: false)
        XCTAssertTrue(md.hasPrefix("---\n"))
        XCTAssertTrue(md.contains("title: \"My \\\"Quoted\\\" Title\""))
        XCTAssertTrue(md.contains("durationMinutes: 10"))
        XCTAssertTrue(md.contains("## Summary"))
        XCTAssertTrue(md.contains("- k"))
        XCTAssertTrue(md.contains("- [ ] a"))
        XCTAssertTrue(md.contains("## Decisions"))
        XCTAssertTrue(md.contains("## Transcript"))
        XCTAssertFalse(md.contains("partial:"))
    }

    func testOmitsEmptySectionsAndShowsWarnings() {
        let summary = MeetingSummary(
            title: "T", summary: "",
            keyPoints: [], actionItems: [], decisions: [],
            warning: "Summarization failed: boom.")
        let md = MarkdownRenderer.render(
            summary: summary, transcript: "text", startedAt: Date(),
            durationSeconds: 60, partial: true, extraWarnings: ["channel warning"])
        XCTAssertFalse(md.contains("## Summary"))
        XCTAssertFalse(md.contains("## Key Points"))
        XCTAssertFalse(md.contains("## Action Items"))
        XCTAssertTrue(md.contains("> [!warning] channel warning"))
        XCTAssertTrue(md.contains("> [!warning] Summarization failed: boom."))
        XCTAssertTrue(md.contains("partial: true"))
        XCTAssertTrue(md.contains("## Transcript"))
    }

    func testAttendeesOrganizerAndTaskTag() {
        let summary = MeetingSummary(
            title: "T", summary: "s",
            keyPoints: [], actionItems: ["send report"], decisions: [], warning: nil)
        let md = MarkdownRenderer.render(
            summary: summary, transcript: "x", startedAt: Date(), durationSeconds: 60,
            partial: false,
            attendees: ["Ann A", "Bob \"B\""], organizer: "Ann A", taskTag: "#task")
        XCTAssertTrue(md.contains("organizer: \"Ann A\""))
        XCTAssertTrue(md.contains("attendees: [\"Ann A\", \"Bob \\\"B\\\"\"]"))
        XCTAssertTrue(md.contains("- [ ] send report #task"))
    }

    func testEmptyTranscriptPlaceholder() {
        let summary = MeetingSummary(
            title: "T", summary: "s", keyPoints: [], actionItems: [], decisions: [], warning: nil)
        let md = MarkdownRenderer.render(
            summary: summary, transcript: "", startedAt: Date(), durationSeconds: 60, partial: false)
        XCTAssertTrue(md.contains("_No speech was transcribed._"))
    }
}
