import XCTest
@testable import TeamsToObsidianKit

/// Guards against config.example.json drifting from the in-code defaults —
/// adding a config field without updating the example fails this test.
final class ConfigExampleSyncTests: XCTestCase {
    func testExampleConfigMatchesDefaults() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // ConfigExampleSyncTests.swift
            .deletingLastPathComponent()   // TeamsToObsidianKitTests
            .deletingLastPathComponent()   // Tests
        let exampleURL = repoRoot.appendingPathComponent("config.example.json")
        let data = try Data(contentsOf: exampleURL)
        let decoded = try JSONDecoder().decode(Config.self, from: data)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        XCTAssertEqual(
            String(data: try encoder.encode(decoded), encoding: .utf8),
            String(data: try encoder.encode(Config()), encoding: .utf8),
            "config.example.json has drifted from the Config defaults")
    }
}
