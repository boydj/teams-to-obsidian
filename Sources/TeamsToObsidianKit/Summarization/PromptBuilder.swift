import Foundation

struct PromptBuilder {
    private let maxTranscriptChars: Int
    private let templateOverridePath: String?

    init(config: Config.Summarizer) {
        maxTranscriptChars = max(1_000, config.maxTranscriptChars)
        templateOverridePath = config.promptTemplatePath
    }

    static let defaultSystemPrompt = """
    You summarize Microsoft Teams meeting transcripts. In the transcript, segments \
    labeled "Me" were spoken by the local user; segments labeled "Them" were spoken \
    by other participants (possibly several different people).

    When a participant list is provided, use those real names in the summary and \
    action items instead of "Them" wherever the speaker can be identified.

    Respond with ONLY a fenced JSON code block (```json ... ```) containing an object \
    with exactly these keys:
    - "title": short, specific meeting title (max 60 characters; no date, no quotes or slashes)
    - "summary": a 2-4 paragraph prose summary of the meeting
    - "key_points": array of strings with the main points discussed
    - "action_items": array of strings; start each with the owner when identifiable \
    (e.g. "Me: send the report to finance")
    - "decisions": array of strings listing decisions that were made

    Use empty arrays where nothing applies. Do not write anything outside the JSON fence.
    """

    /// The instruction prompt — replaceable via summarizer.promptTemplatePath.
    func systemPrompt() -> String {
        if let path = templateOverridePath, !path.isEmpty {
            let url = Paths.expand(path)
            if let custom = try? String(contentsOf: url, encoding: .utf8),
               !custom.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return custom
            }
            Log.error("Could not read prompt template at \(url.path); using the built-in prompt.")
        }
        return Self.defaultSystemPrompt
    }

    func userPrompt(transcript: String, meetingDate: Date, durationSeconds: Int,
                    context: MeetingContext? = nil) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"

        var header = "Meeting date: \(formatter.string(from: meetingDate))\n"
        header += "Duration: \(max(1, durationSeconds / 60)) minutes\n"
        if let context {
            if let title = context.title {
                header += "Meeting title: \(title)\n"
            }
            if !context.attendees.isEmpty {
                header += "Participants: \(context.attendees.joined(separator: ", "))\n"
            }
            if let organizer = context.organizer {
                header += "Organizer: \(organizer)\n"
            }
        }

        var body = transcript
        if body.count > maxTranscriptChars {
            // Keep the tail — meeting endings carry the action items.
            body = "[transcript truncated — earliest part omitted]\n" + String(body.suffix(maxTranscriptChars))
        }
        return """
        \(header)
        Transcript:
        \(body)
        """
    }
}
