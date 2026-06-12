import XCTest
@testable import TeamsToObsidianKit

private struct FakeError: Error, CustomStringConvertible {
    let description: String
}

final class BedrockFriendlyMessageTests: XCTestCase {
    func testExpiredSSOHintIncludesProfile() {
        let message = BedrockSummarizer.friendlyMessage(
            for: FakeError(description: "ExpiredTokenException: the security token is expired"),
            region: "us-east-1", modelID: "m", profile: "work")
        XCTAssertTrue(message.contains("aws sso login --profile work"))
    }

    func testAccessDeniedHint() {
        let message = BedrockSummarizer.friendlyMessage(
            for: FakeError(description: "AccessDeniedException: not authorized"),
            region: "us-east-1", modelID: "anthropic.claude-opus-4-8", profile: nil)
        XCTAssertTrue(message.contains("model access is enabled"))
        XCTAssertTrue(message.contains("anthropic.claude-opus-4-8"))
    }

    func testModelNotFoundHintMentionsInferenceProfiles() {
        let message = BedrockSummarizer.friendlyMessage(
            for: FakeError(description: "ResourceNotFoundException: model identifier is invalid"),
            region: "eu-west-1", modelID: "bogus", profile: nil)
        XCTAssertTrue(message.contains("inference profile"))
    }

    func testUnknownErrorHasNoBogusHints() {
        let message = BedrockSummarizer.friendlyMessage(
            for: FakeError(description: "something else entirely"),
            region: "us-east-1", modelID: "m", profile: nil)
        XCTAssertTrue(message.hasPrefix("Bedrock request failed:"))
        XCTAssertFalse(message.contains("sso login"))
    }
}
