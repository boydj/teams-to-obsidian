import Foundation

/// Summarizes via a local Ollama server (native /api/chat, non-streaming).
/// Localhost only — no external calls.
final class OllamaSummarizer: Summarizer {
    let name = "ollama"

    private let config: Config.Ollama
    private let prompts: PromptBuilder
    private let session: URLSession

    init(config: Config.Ollama, prompts: PromptBuilder) {
        self.config = config
        self.prompts = prompts
        let sessionConfig = URLSessionConfiguration.ephemeral
        // Local models can take a long time on hour-long transcripts.
        sessionConfig.timeoutIntervalForRequest = 600
        sessionConfig.timeoutIntervalForResource = 1_800
        session = URLSession(configuration: sessionConfig)
    }

    private struct ChatRequest: Encodable {
        struct Message: Encodable {
            let role: String
            let content: String
        }
        struct Options: Encodable {
            let temperature: Double
        }
        let model: String
        let messages: [Message]
        let stream: Bool
        let options: Options
    }

    private struct ChatResponse: Decodable {
        struct Message: Decodable {
            let content: String
        }
        let message: Message
    }

    func summarize(transcript: String, meetingDate: Date, durationSeconds: Int) async throws -> MeetingSummary {
        let text = try await chat(
            system: prompts.systemPrompt(),
            user: prompts.userPrompt(transcript: transcript, meetingDate: meetingDate, durationSeconds: durationSeconds))
        return SummaryParser.parse(text, meetingDate: meetingDate)
    }

    func healthCheck() async throws -> String {
        try await chat(system: "You are a connectivity check.",
                       user: "Reply with the single word: pong")
    }

    private func chat(system: String, user: String) async throws -> String {
        guard let base = URL(string: config.baseURL) else {
            throw SummarizerError.badConfig("Invalid Ollama base URL: \(config.baseURL)")
        }
        var request = URLRequest(url: base.appendingPathComponent("api/chat"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 600
        request.httpBody = try JSONEncoder().encode(ChatRequest(
            model: config.model,
            messages: [
                .init(role: "system", content: system),
                .init(role: "user", content: user),
            ],
            stream: false,
            options: .init(temperature: 0.2)))

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let urlError as URLError where urlError.code == .cannotConnectToHost
            || urlError.code == .cannotFindHost
            || urlError.code == .networkConnectionLost {
            throw SummarizerError.backend(
                "Could not reach Ollama at \(config.baseURL) — is it running? Start it with `ollama serve` (or launch the Ollama app).")
        } catch let urlError as URLError where urlError.code == .timedOut {
            throw SummarizerError.backend(
                "Ollama timed out — the model may be too slow for this transcript. Try a smaller model (summarizer.ollama.model).")
        }

        guard let http = response as? HTTPURLResponse else {
            throw SummarizerError.unexpectedResponse("No HTTP response from Ollama")
        }
        guard http.statusCode == 200 else {
            let bodyText = String(data: data, encoding: .utf8) ?? ""
            var message = "Ollama returned HTTP \(http.statusCode): \(bodyText.prefix(300))"
            if http.statusCode == 404 && bodyText.lowercased().contains("model") {
                message += "\nPull the model first: `ollama pull \(config.model)`"
            }
            throw SummarizerError.backend(message)
        }
        do {
            return try JSONDecoder().decode(ChatResponse.self, from: data).message.content
        } catch {
            let snippet = String(data: data, encoding: .utf8)?.prefix(300) ?? ""
            throw SummarizerError.unexpectedResponse("Unexpected Ollama response: \(snippet)")
        }
    }
}
