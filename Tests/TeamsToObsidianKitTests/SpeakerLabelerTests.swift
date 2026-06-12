import XCTest
@testable import TeamsToObsidianKit

final class SpeakerLabelerTests: XCTestCase {
    private func seg(_ start: Int, _ end: Int, _ text: String = "x") -> WhisperSegment {
        WhisperSegment(startMS: start, endMS: end, text: text)
    }

    func testClusterVoteNaming() {
        let diarization = [
            SpeakerInterval(startMS: 0, endMS: 10_000, label: "Speaker 1"),
            SpeakerInterval(startMS: 20_000, endMS: 30_000, label: "Speaker 1"),
            SpeakerInterval(startMS: 10_000, endMS: 20_000, label: "Speaker 2"),
        ]
        let active = [
            SpeakerInterval(startMS: 1_000, endMS: 9_000, label: "Sarah"),
            SpeakerInterval(startMS: 21_000, endMS: 24_000, label: "Sarah"),
        ]
        let mapping = SpeakerLabeler.nameClusters(diarization: diarization, activeSpeakers: active)
        XCTAssertEqual(mapping["Speaker 1"], "Sarah")
        XCTAssertNil(mapping["Speaker 2"])
    }

    func testNamedClusterLabelsSegmentsEvenWhereCaptureMissed() {
        // The 20-30s turn has no direct capture overlap, but its cluster was
        // named via the 0-10s vote — the segment still gets the real name.
        let diarization = [
            SpeakerInterval(startMS: 0, endMS: 10_000, label: "Speaker 1"),
            SpeakerInterval(startMS: 20_000, endMS: 30_000, label: "Speaker 1"),
        ]
        let active = [SpeakerInterval(startMS: 0, endMS: 9_000, label: "Sarah")]
        let labeled = SpeakerLabeler.label(
            themSegments: [seg(21_000, 25_000)], diarization: diarization, activeSpeakers: active)
        XCTAssertEqual(labeled[0].label, "Sarah")
    }

    func testUnnamedClusterKeepsSpeakerNumber() {
        let diarization = [SpeakerInterval(startMS: 0, endMS: 10_000, label: "Speaker 2")]
        let labeled = SpeakerLabeler.label(
            themSegments: [seg(1_000, 4_000)], diarization: diarization, activeSpeakers: [])
        XCTAssertEqual(labeled[0].label, "Speaker 2")
    }

    func testActiveSpeakerDirectLabelWithoutDiarization() {
        let active = [SpeakerInterval(startMS: 0, endMS: 3_500, label: "Bob")]
        let labeled = SpeakerLabeler.label(
            themSegments: [seg(1_000, 4_000)], diarization: [], activeSpeakers: active)
        XCTAssertEqual(labeled[0].label, "Bob")
    }

    func testFallsBackToThem() {
        let labeled = SpeakerLabeler.label(
            themSegments: [seg(0, 2_000)], diarization: [], activeSpeakers: [])
        XCTAssertEqual(labeled[0].label, "Them")
    }

    func testTrivialOverlapDoesNotLabel() {
        // 100ms of overlap on a 5s segment is noise, not attribution.
        let diarization = [SpeakerInterval(startMS: 0, endMS: 1_100, label: "Speaker 1")]
        let labeled = SpeakerLabeler.label(
            themSegments: [seg(1_000, 6_000)], diarization: diarization, activeSpeakers: [])
        XCTAssertEqual(labeled[0].label, "Them")
    }

    func testLabeledMergeInterleavesAndCoalesces() {
        let me = [seg(0, 1_000, "Hi")]
        let labeled: [(label: String, segment: WhisperSegment)] = [
            ("Sarah", seg(2_000, 3_000, "Hello")),
            ("Sarah", seg(3_200, 4_000, "again")),
            ("Speaker 2", seg(6_000, 7_000, "Hey")),
        ]
        let text = TranscriptMerger.merge(me: me, labeledThem: labeled)
        XCTAssertTrue(text.contains("**Me** [0:00:00]: Hi"))
        XCTAssertTrue(text.contains("**Sarah** [0:00:02]: Hello again"))
        XCTAssertTrue(text.contains("**Speaker 2** [0:00:06]: Hey"))
    }
}

final class SpeakerDiarizerParseTests: XCTestCase {
    func testParsesSherpaOutput() {
        let stdout = """
        0.318 -- 6.865 speaker_00
        7.017 -- 10.747 speaker_01
        some unrelated log line
        11.000 -- 12.500 speaker_00
        """
        let turns = SpeakerDiarizer.parse(stdout: stdout)
        XCTAssertEqual(turns.count, 3)
        XCTAssertEqual(turns[0], SpeakerInterval(startMS: 318, endMS: 6_865, label: "Speaker 1"))
        XCTAssertEqual(turns[1].label, "Speaker 2")
        XCTAssertEqual(turns[2].label, "Speaker 1")
    }

    func testEmptyAndGarbage() {
        XCTAssertTrue(SpeakerDiarizer.parse(stdout: "").isEmpty)
        XCTAssertTrue(SpeakerDiarizer.parse(stdout: "no segments here").isEmpty)
    }
}

final class ActiveSpeakerPatternTests: XCTestCase {
    func testDefaultPatternMatchesSpeakingVariants() throws {
        let regex = try NSRegularExpression(pattern: ActiveSpeakerObserver.defaultPattern)
        let names = ActiveSpeakerObserver.matchNames(in: [
            "Jane Doe, speaking",
            "John Smith is speaking",
            "Muted, Bob Jones",
            "speaking rate",
        ], regex: regex)
        XCTAssertEqual(names, ["Jane Doe", "John Smith"])
    }
}
