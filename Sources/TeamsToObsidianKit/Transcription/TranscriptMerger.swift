import Foundation

enum Speaker: String {
    case me = "Me"
    case them = "Them"
}

/// Interleaves the mic ("Me") and Teams-output ("Them") transcripts into one
/// timeline. Pure logic — covered by unit tests.
enum TranscriptMerger {
    struct Entry: Equatable {
        let speaker: Speaker
        let startMS: Int
        var endMS: Int
        var text: String
    }

    static func merge(me: [WhisperSegment], them: [WhisperSegment], coalesceGapMS: Int = 1500) -> String {
        let entries = mergedEntries(me: me, them: them, coalesceGapMS: coalesceGapMS)
        return entries
            .map { "**\($0.speaker.rawValue)** [\(timestamp($0.startMS))]: \($0.text)" }
            .joined(separator: "\n\n")
    }

    static func mergedEntries(me: [WhisperSegment], them: [WhisperSegment], coalesceGapMS: Int = 1500) -> [Entry] {
        var tagged: [(speaker: Speaker, segment: WhisperSegment)] =
            me.map { (.me, $0) } + them.map { (.them, $0) }
        tagged = tagged.filter { isMeaningful($0.segment.text) }
        // Deterministic ordering (Swift's sort is not guaranteed stable).
        tagged.sort { a, b in
            if a.segment.startMS != b.segment.startMS { return a.segment.startMS < b.segment.startMS }
            if a.segment.endMS != b.segment.endMS { return a.segment.endMS < b.segment.endMS }
            return a.speaker == .me && b.speaker == .them
        }

        var entries: [Entry] = []
        for (speaker, segment) in tagged {
            if var last = entries.last,
               last.speaker == speaker,
               segment.startMS - last.endMS < coalesceGapMS {
                last.text += " " + segment.text
                last.endMS = max(last.endMS, segment.endMS)
                entries[entries.count - 1] = last
            } else {
                entries.append(Entry(speaker: speaker,
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
