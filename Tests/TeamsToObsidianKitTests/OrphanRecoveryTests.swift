import XCTest
@testable import TeamsToObsidianKit

final class OrphanRecoveryTests: XCTestCase {
    func testFindsAndRepairsCrashedSessions() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("tto-orphans-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }

        // Crashed session: state stays .recording, WAV never finalized.
        let crashed = try RecordingSession.create(in: root, partial: false)
        let writer = try WAVWriter(url: crashed.micWAVURL)
        writer.append(samples: [Int16](repeating: 400, count: 16_000))   // 1 second
        _ = writer.durationSeconds   // barrier for the queued write; no finalize()

        // Finished session: must be ignored.
        let finished = try RecordingSession.create(in: root, partial: false)
        finished.update { $0.state = .done }

        let orphans = OrphanRecovery.findOrphans(recordingsDir: root)
        XCTAssertEqual(orphans.count, 1)
        XCTAssertEqual(orphans.first?.directory.lastPathComponent,
                       crashed.directory.lastPathComponent)

        let orphan = try XCTUnwrap(orphans.first)
        OrphanRecovery.prepare(orphan)
        XCTAssertEqual(WAVWriter.dataDurationSeconds(at: orphan.micWAVURL), 1.0)
        XCTAssertNotNil(orphan.meta.endedAt)
        writer.finalize()
    }

    func testEmptyDirectoryHasNoOrphans() {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("tto-orphans-\(UUID().uuidString)")
        XCTAssertTrue(OrphanRecovery.findOrphans(recordingsDir: root).isEmpty)
    }
}
