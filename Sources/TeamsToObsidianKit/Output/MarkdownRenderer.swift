import Foundation

/// Renders the Obsidian note. Sections with no content are omitted; the
/// transcript section is always present. Pure logic — covered by unit tests.
enum MarkdownRenderer {
    static func render(summary: MeetingSummary,
                       transcript: String,
                       startedAt: Date,
                       durationSeconds: Int,
                       partial: Bool,
                       extraWarnings: [String] = []) -> String {
        let dateFormatter = DateFormatter()
        dateFormatter.locale = Locale(identifier: "en_US_POSIX")
        // ISO-style so Obsidian types the property as date & time.
        dateFormatter.dateFormat = "yyyy-MM-dd'T'HH:mm"

        var lines: [String] = []
        lines.append("---")
        lines.append("title: \(yamlString(summary.title))")
        lines.append("date: \(dateFormatter.string(from: startedAt))")
        lines.append("durationMinutes: \(max(1, durationSeconds / 60))")
        lines.append("type: meeting")
        lines.append("tags: [meeting, teams]")
        if partial {
            lines.append("partial: true")
        }
        lines.append("---")
        lines.append("")

        var warnings = extraWarnings
        if let warning = summary.warning {
            warnings.append(warning)
        }
        for warning in warnings {
            lines.append("> [!warning] \(warning.replacingOccurrences(of: "\n", with: " "))")
            lines.append("")
        }

        if !summary.summary.isEmpty {
            lines.append("## Summary")
            lines.append("")
            lines.append(summary.summary)
            lines.append("")
        }
        if !summary.keyPoints.isEmpty {
            lines.append("## Key Points")
            lines.append("")
            for point in summary.keyPoints {
                lines.append("- \(point)")
            }
            lines.append("")
        }
        if !summary.actionItems.isEmpty {
            lines.append("## Action Items")
            lines.append("")
            for item in summary.actionItems {
                lines.append("- [ ] \(item)")
            }
            lines.append("")
        }
        if !summary.decisions.isEmpty {
            lines.append("## Decisions")
            lines.append("")
            for decision in summary.decisions {
                lines.append("- \(decision)")
            }
            lines.append("")
        }
        lines.append("## Transcript")
        lines.append("")
        lines.append(transcript.isEmpty ? "_No speech was transcribed._" : transcript)
        lines.append("")
        return lines.joined(separator: "\n")
    }

    static func yamlString(_ s: String) -> String {
        let escaped = s
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }
}
