import XCTest
@testable import TeamsToObsidianKit

final class VaultWriterTests: XCTestCase {
    func testSanitizeFilename() {
        XCTAssertEqual(VaultWriter.sanitizeFilename("a/b:c|d#e^f[g]h?i*j\"k<l>m"),
                       "a b c d e f g h i j k l m")
        XCTAssertEqual(VaultWriter.sanitizeFilename("   "), "Meeting")
        XCTAssertEqual(VaultWriter.sanitizeFilename("name..."), "name")
        XCTAssertEqual(VaultWriter.sanitizeFilename("two  spaces"), "two spaces")
        XCTAssertEqual(VaultWriter.sanitizeFilename("plain title"), "plain title")
    }

    func testWriteCreatesNoteAndUniquifies() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("tto-test-vault-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        var cfg = Config.Vault()
        cfg.path = tmp.path
        cfg.notesFolder = "Meetings"
        let date = Date(timeIntervalSince1970: 1_700_000_000)

        let first = try VaultWriter.write(markdown: "one", title: "Test", startedAt: date, config: cfg)
        let second = try VaultWriter.write(markdown: "two", title: "Test", startedAt: date, config: cfg)
        XCTAssertNotEqual(first.path, second.path)
        XCTAssertTrue(second.lastPathComponent.contains("(2)"))
        XCTAssertEqual(try String(contentsOf: first, encoding: .utf8), "one")
        XCTAssertEqual(try String(contentsOf: second, encoding: .utf8), "two")
        XCTAssertEqual(first.deletingLastPathComponent().lastPathComponent, "Meetings")
    }

    func testMissingVaultThrows() {
        var cfg = Config.Vault()
        cfg.path = "/nonexistent/path/\(UUID().uuidString)"
        XCTAssertThrowsError(try VaultWriter.write(markdown: "x", title: "T", startedAt: Date(), config: cfg))
    }
}
