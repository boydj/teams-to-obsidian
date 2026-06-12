import XCTest
@testable import TeamsToObsidianKit

final class ConfigTests: XCTestCase {
    func testDefaults() {
        let c = Config()
        XCTAssertEqual(c.summarizer.backend, "bedrock")
        XCTAssertEqual(c.summarizer.bedrock.modelID, "anthropic.claude-opus-4-8")
        XCTAssertEqual(c.summarizer.ollama.baseURL, "http://localhost:11434")
        XCTAssertEqual(c.detection.bundleIDPrefixes, ["com.microsoft.teams2"])
        XCTAssertEqual(c.capture.captureMode, "processTap")
        XCTAssertFalse(c.recording.keepAudio)
    }

    func testPartialConfigKeepsDefaults() throws {
        let json = #"{"summarizer": {"backend": "ollama", "ollama": {"model": "qwen3"}}, "vault": {"path": "/tmp/v"}}"#
        let c = try JSONDecoder().decode(Config.self, from: Data(json.utf8))
        XCTAssertEqual(c.summarizer.backend, "ollama")
        XCTAssertEqual(c.summarizer.ollama.model, "qwen3")
        XCTAssertEqual(c.summarizer.ollama.baseURL, "http://localhost:11434")
        XCTAssertEqual(c.vault.path, "/tmp/v")
        XCTAssertEqual(c.vault.notesFolder, "Meetings")
        XCTAssertEqual(c.whisper.language, "en")
        XCTAssertEqual(c.detection.minMeetingDurationSeconds, 60)
    }

    func testUnknownKeysAreIgnored() throws {
        let json = #"{"futureFeature": true, "vault": {"path": "/tmp/v", "somethingNew": 1}}"#
        let c = try JSONDecoder().decode(Config.self, from: Data(json.utf8))
        XCTAssertEqual(c.vault.path, "/tmp/v")
    }

    func testRoundTrip() throws {
        var c = Config()
        c.summarizer.bedrock.profile = "work"
        c.summarizer.backend = "ollama"
        c.recording.keepAudio = true
        let data = try JSONEncoder().encode(c)
        let back = try JSONDecoder().decode(Config.self, from: data)
        XCTAssertEqual(back.summarizer.bedrock.profile, "work")
        XCTAssertEqual(back.summarizer.backend, "ollama")
        XCTAssertTrue(back.recording.keepAudio)
    }
}
