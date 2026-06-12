import Foundation

/// Interleaves the mic ("Me") and Teams-output transcripts into one timeline.
/// Remote segments carry per-speaker labels when diarization / active-speaker
/// capture provided them, otherwise "Them". Pure logic — covered by unit tests.
enum TranscriptMerger {
    static let meLabel = "Me"
    static let themLabel = "Them"

    struct Entry: Equatable {
        let speaker: String
        let startMS: Int
        var endMS: Int
        var text: String
    }

    /// Convenience for unlabeled remote segments (all "Them").
    static func merge(me: [WhisperSegment], them: [WhisperSegment], coalesceGapMS: Int = 1500) -> String {
        merge(me: me, labeledThem: them.map { (themLabel, $0) }, coalesceGapMS: coalesceGapMS)
    }

    static func merge(me: [WhisperSegment],
                      labeledThem: [(label: String, segment: WhisperSegment)],
                      coalesceGapMS: Int = 1500) -> String {
        let entries = mergedEntries(me: me, labeledThem: labeledThem, coalesceGapMS: coalesceGapMS)
        return entries
            .map { "**\($0.speaker)** [\(timestamp($0.startMS))]: \($0.text)" }
            .joined(separator: "\n\n")
    }

    static func mergedEntries(me: [WhisperSegment], them: [WhisperSegment],
                              coalesceGapMS: Int = 1500) -> [Entry] {
        mergedEntries(me: me, labeledThem: them.map { (themLabel, $0) }, coalesceGapMS: coalesceGapMS)
    }

    static func mergedEntries(me: [WhisperSegment],
                              labeledThem: [(label: String, segment: WhisperSegment)],
                              coalesceGapMS: Int = 1500) -> [Entry] {
        var tagged: [(label: String, segment: WhisperSegment)] =
            me.map { (meLabel, $0) } + labeledThem
        tagged = tagged.filter { isMeaningful($0.segment.text) }
        // Deterministic ordering (Swift's sort is not guaranteed stable).
        tagged.sort { a, b in
            if a.segment.startMS != b.segment.startMS { return a.segment.startMS < b.segment.startMS }
            if a.segment.endMS != b.segment.endMS { return a.segment.endMS < b.segment.endMS }
            if a.label != b.label { return a.label == meLabel || (b.label != meLabel && a.label < b.label) }
            return false
        }

        var entries: [Entry] = []
        for (label, segment) in tagged {
            if var last = entries.last,
               last.speaker == label,
               segment.startMS - last.endMS < coalesceGapMS {
                last.text += " " + segment.text
                last.endMS = max(last.endMS, segment.endMS)
                entries[entries.count - 1] = last
            } else {
                entries.append(Entry(speaker: label,
                                     startMS: segment.startMS,
                                     endMS: segment.endMS,
                                     text: segment.text))
            }
        }
        return entries
    }

    /// Shifts segments by an offset (per-channel recording start skew).
    static func shift(_ segments: [WhisperSegment], byMS offset: Int) -> [WhisperSegment] {
        guard offset != 0 else { return segments }
        return segments.map {
            WhisperSegment(startMS: $0.startMS + offset, endMS: $0.endMS + offset, text: $0.text)
        }
    }

    static func timestamp(_ ms: Int) -> String {
        let total = max(0, ms) / 1000
        return String(format: "%d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
    }

    /// Drops empty segments and whisper's bracketed non-speech annotations
    /// ([BLANK_AUDIO], (music), …) — common hallucinations on silence/hold music.
    static func isMeaningful(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return false }
        if (t.hasPrefix("[") && t.hasSuffix("]")) || (t.hasPrefix("(") && t.hasSuffix(")")) {
            return false
        }
        return true
    }
}
