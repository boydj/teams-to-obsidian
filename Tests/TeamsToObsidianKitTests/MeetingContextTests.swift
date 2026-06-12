import XCTest
@testable import TeamsToObsidianKit

final class MeetingContextTests: XCTestCase {
    func testCleansTeamsWindowChrome() {
        XCTAssertEqual(
            MeetingContextProvider.cleanedTeamsWindowTitle("Quarterly Planning | Microsoft Teams"),
            "Quarterly Planning")
        XCTAssertEqual(
            MeetingContextProvider.cleanedTeamsWindowTitle("Budget Sync| Microsoft Teams"),
            "Budget Sync")
    }

    func testRejectsGenericSections() {
        for title in ["Microsoft Teams", "Chat | Microsoft Teams", "(3) Chat | Microsoft Teams",
                      "Activity | Microsoft Teams", "Calendar | Microsoft Teams", ""] {
            XCTAssertNil(MeetingContextProvider.cleanedTeamsWindowTitle(title), title)
        }
    }

    func testPromptIncludesContext() {
        let prompts = PromptBuilder(config: Config.Summarizer())
        let context = MeetingContext(title: "Budget Sync", attendees: ["Ann", "Bob"], organizer: "Ann")
        let prompt = prompts.userPrompt(transcript: "hello", meetingDate: Date(),
                                        durationSeconds: 300, context: context)
        XCTAssertTrue(prompt.contains("Meeting title: Budget Sync"))
        XCTAssertTrue(prompt.contains("Participants: Ann, Bob"))
        XCTAssertTrue(prompt.contains("Organizer: Ann"))
        XCTAssertTrue(prompt.contains("Transcript:\nhello"))
    }

    func testPromptWithoutContext() {
        let prompts = PromptBuilder(config: Config.Summarizer())
        let prompt = prompts.userPrompt(transcript: "hello", meetingDate: Date(), durationSeconds: 300)
        XCTAssertFalse(prompt.contains("Participants:"))
        XCTAssertTrue(prompt.contains("Transcript:\nhello"))
    }
}
