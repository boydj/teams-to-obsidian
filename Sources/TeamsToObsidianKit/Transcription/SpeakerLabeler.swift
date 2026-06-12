import Foundation

/// Assigns a speaker label to each remote ("Them") transcript segment by
/// combining two evidence sources on the same timeline:
///  - diarization clusters ("Speaker 1", "Speaker 2", …) — consistent voices
///  - Teams active-speaker capture — real names for the moments the UI showed
///    someone speaking
///
/// When a diarization cluster's airtime mostly coincides with one captured
/// name, the whole cluster is renamed — so even segments the UI capture
/// missed get the right name. Pure logic, covered by unit tests.
enum SpeakerLabeler {
    static func label(themSegments: [WhisperSegment],
                      diarization: [SpeakerInterval],
                      activeSpeakers: [SpeakerInterval],
                      fallback: String = "Them") -> [(label: String, segment: WhisperSegment)] {
        let clusterNames = nameClusters(diarization: diarization, activeSpeakers: activeSpeakers)
        return themSegments.map { segment in
            if let cluster = bestMatch(for: segment, in: diarization) {
                return (clusterNames[cluster] ?? cluster, segment)
            }
            if let name = bestMatch(for: segment, in: activeSpeakers) {
                return (name, segment)
            }
            return (fallback, segment)
        }
    }

    /// Maps diarization cluster labels to captured real names by overlap vote.
    /// A cluster is renamed when one name accounts for ≥60% of the cluster's
    /// name-overlapped time and at least 5 seconds in absolute terms.
    static func nameClusters(diarization: [SpeakerInterval],
                             activeSpeakers: [SpeakerInterval]) -> [String: String] {
        guard !diarization.isEmpty, !activeSpeakers.isEmpty else { return [:] }
        var votes: [String: [String: Int]] = [:]   // cluster -> name -> overlap ms
        for turn in diarization {
            for named in activeSpeakers {
                let overlap = overlapMS(turn.startMS, turn.endMS, named.startMS, named.endMS)
                if overlap > 0 {
                    votes[turn.label, default: [:]][named.label, default: 0] += overlap
                }
            }
        }
        var mapping: [String: String] = [:]
        for (cluster, byName) in votes {
            let total = byName.values.reduce(0, +)
            guard total > 0, let best = byName.max(by: { $0.value < $1.value }) else { continue }
            if best.value >= 5_000 && Double(best.value) >= 0.6 * Double(total) {
                mapping[cluster] = best.key
            }
        }
        return mapping
    }

    /// The label of the interval overlapping the segment the most, when that
    /// overlap is meaningful (≥1s, or ≥30% of the segment).
    private static func bestMatch(for segment: WhisperSegment,
                                  in intervals: [SpeakerInterval]) -> String? {
        var byLabel: [String: Int] = [:]
        for interval in intervals {
            let overlap = overlapMS(segment.startMS, segment.endMS, interval.startMS, interval.endMS)
            if overlap > 0 {
                byLabel[interval.label, default: 0] += overlap
            }
        }
        guard let best = byLabel.max(by: { $0.value < $1.value }) else { return nil }
        let segmentLength = max(1, segment.endMS - segment.startMS)
        let meaningful = best.value >= 1_000 || Double(best.value) >= 0.3 * Double(segmentLength)
        return meaningful ? best.key : nil
    }

    static func overlapMS(_ aStart: Int, _ aEnd: Int, _ bStart: Int, _ bEnd: Int) -> Int {
        max(0, min(aEnd, bEnd) - max(aStart, bStart))
    }

    /// Shifts intervals onto the merged-transcript timebase (channel start skew).
    static func shift(_ intervals: [SpeakerInterval], byMS offset: Int) -> [SpeakerInterval] {
        guard offset != 0 else { return intervals }
        return intervals.map {
            SpeakerInterval(startMS: $0.startMS + offset, endMS: $0.endMS + offset, label: $0.label)
        }
    }
}
