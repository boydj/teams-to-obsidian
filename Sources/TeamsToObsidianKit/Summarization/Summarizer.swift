import Foundation

struct MeetingSummary: Codable, Equatable {
    var title: String
    var summary: String
    var keyPoints: [String]
    var actionItems: [String]
    var decisions: [String]
    /// Set when something degraded (summarizer failed, unstructured output);
    /// rendered as a warning callout in the note.
    var warning: String?
}

enum SummarizerError: Error, LocalizedError {
    case backend(String)
    case unexpectedResponse(String)
    case badConfig(String)

    var errorDescription: String? {
        switch self {
        case .backend(let message), .unexpectedResponse(let message), .badConfig(let message):
            return message
        }
    }
}

protocol Summarizer {
    var name: String { get }
    func summarize(transcript: String, meetingDate: Date, durationSeconds: Int,
                   context: MeetingContext?) async throws -> MeetingSummary
    /// Cheap connectivity round-trip; returns the model's reply text.
    func healthCheck() async throws -> String
}

enum SummarizerFactory {
    static func make(config: Config.Summarizer) throws -> Summarizer {
        let prompts = PromptBuilder(config: config)
        switch config.backend.lowercased() {
        case "bedrock":
            return BedrockSummarizer(config: config.bedrock, prompts: prompts)
        case "ollama":
            return OllamaSummarizer(config: config.ollama, prompts: prompts)
        default:
            throw SummarizerError.badConfig(
                "Unknown summarizer backend \"\(config.backend)\" — use \"bedrock\" or \"ollama\".")
        }
    }
}

/// Robust parsing of the model's reply. Ladder: ```json fence → first {...}
/// blob → fallback that embeds the raw text verbatim. Raw text is never discarded.
enum SummaryParser {
    static func parse(_ raw: String, meetingDate: Date) -> MeetingSummary {
        for candidate in candidates(in: raw) {
            if let dto = decode(candidate) {
                return MeetingSummary(
                    title: cleanTitle(dto.title) ?? fallbackTitle(meetingDate),
                    summary: dto.summary?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
                    keyPoints: dto.keyPoints ?? [],
                    actionItems: dto.actionItems ?? [],
                    decisions: dto.decisions ?? [],
                    warning: nil)
            }
        }
        return MeetingSummary(
            title: fallbackTitle(meetingDate),
            summary: raw.trimmingCharacters(in: .whitespacesAndNewlines),
            keyPoints: [],
            actionItems: [],
            decisions: [],
            warning: "The summarizer returned unstructured output; it is shown below as-is.")
    }

    static func fallbackTitle(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return "Teams Meeting \(formatter.string(from: date))"
    }

    private struct DTO: Decodable {
        let title: String?
        let summary: String?
        let keyPoints: [String]?
        let actionItems: [String]?
        let decisions: [String]?
    }

    private static func decode(_ candidate: String) -> DTO? {
        guard let data = candidate.data(using: .utf8) else { return nil }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try? decoder.decode(DTO.self, from: data)
    }

    private static func candidates(in raw: String) -> [String] {
        var out: [String] = []
        if let fenced = fencedBlock(in: raw) { out.append(fenced) }
        if let first = raw.firstIndex(of: "{"), let last = raw.lastIndex(of: "}"), first < last {
            out.append(String(raw[first...last]))
        }
        return out
    }

    private static func fencedBlock(in raw: String) -> String? {
        guard let opener = raw.range(of: "```json", options: .caseInsensitive) ?? raw.range(of: "```") else {
            return nil
        }
        let rest = raw[opener.upperBound...]
        guard let close = rest.range(of: "```") else { return nil }
        return String(rest[..<close.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func cleanTitle(_ title: String?) -> String? {
        guard var t = title?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return nil }
        t = t.replacingOccurrences(of: "\n", with: " ")
        if t.count > 80 {
            t = String(t.prefix(80)).trimmingCharacters(in: .whitespaces)
        }
        return t.isEmpty ? nil : t
    }
}
