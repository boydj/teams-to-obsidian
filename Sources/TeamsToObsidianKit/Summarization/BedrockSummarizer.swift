import AWSBedrockRuntime
import AWSSDKIdentity
import Foundation

/// Summarizes via the AWS Bedrock Converse API. The Converse API is uniform
/// across Bedrock-hosted models, so summarizer.bedrock.modelID is an opaque
/// string ("anthropic.claude-opus-4-8", a "us."-prefixed inference profile, …).
/// Credentials come from the standard AWS chain, or a named profile when
/// summarizer.bedrock.profile is set.
final class BedrockSummarizer: Summarizer {
    let name = "bedrock"

    private let config: Config.Bedrock
    private let prompts: PromptBuilder
    private var client: BedrockRuntimeClient?

    init(config: Config.Bedrock, prompts: PromptBuilder) {
        self.config = config
        self.prompts = prompts
    }

    func summarize(transcript: String, meetingDate: Date, durationSeconds: Int) async throws -> MeetingSummary {
        let text = try await converse(
            system: prompts.systemPrompt(),
            user: prompts.userPrompt(transcript: transcript, meetingDate: meetingDate, durationSeconds: durationSeconds))
        return SummaryParser.parse(text, meetingDate: meetingDate)
    }

    func healthCheck() async throws -> String {
        try await converse(system: "You are a connectivity check.",
                           user: "Reply with the single word: pong")
    }

    private func makeClient() async throws -> BedrockRuntimeClient {
        if let client { return client }
        let configuration: BedrockRuntimeClient.BedrockRuntimeClientConfiguration
        if let profile = config.profile, !profile.isEmpty {
            let resolver = try ProfileAWSCredentialIdentityResolver(profileName: profile)
            configuration = try await BedrockRuntimeClient.BedrockRuntimeClientConfiguration(
                awsCredentialIdentityResolver: resolver,
                region: config.region)
        } else {
            // Default chain: env vars, ~/.aws/{config,credentials}, SSO, roles.
            configuration = try await BedrockRuntimeClient.BedrockRuntimeClientConfiguration(region: config.region)
        }
        let created = BedrockRuntimeClient(config: configuration)
        client = created
        return created
    }

    private func converse(system: String, user: String) async throws -> String {
        do {
            let client = try await makeClient()
            // Only maxTokens: newer Anthropic models on Bedrock reject sampling
            // parameters like temperature.
            let input = ConverseInput(
                inferenceConfig: BedrockRuntimeClientTypes.InferenceConfiguration(maxTokens: config.maxTokens),
                messages: [BedrockRuntimeClientTypes.Message(content: [.text(user)], role: .user)],
                modelId: config.modelID,
                system: [.text(system)])
            let response = try await client.converse(input: input)
            guard let output = response.output,
                  case .message(let message) = output,
                  let content = message.content,
                  let first = content.first,
                  case .text(let text) = first else {
                throw SummarizerError.unexpectedResponse("Bedrock returned no text content")
            }
            return text
        } catch let error as SummarizerError {
            throw error
        } catch {
            throw SummarizerError.backend(Self.friendlyMessage(
                for: error, region: config.region, modelID: config.modelID, profile: config.profile))
        }
    }

    /// Maps common AWS failures to actionable messages. String matching on the
    /// error description is UX sugar only — never control flow.
    static func friendlyMessage(for error: Error, region: String, modelID: String, profile: String?) -> String {
        let raw = String(describing: error)
        let lower = raw.lowercased()
        var hints: [String] = []
        if lower.contains("expiredtoken") || (lower.contains("expired") && lower.contains("token")) {
            let profileFlag = profile.map { " --profile \($0)" } ?? ""
            hints.append("Your AWS session has expired — run `aws sso login\(profileFlag)` (or refresh your credentials).")
        }
        if lower.contains("accessdenied") {
            hints.append("Check that model access is enabled for \(modelID) in \(region) (Bedrock console → Model access) and that your IAM policy allows bedrock:InvokeModel.")
        }
        if lower.contains("unrecognizedclient") || lower.contains("no credentials")
            || lower.contains("credentials") && lower.contains("not") {
            hints.append("No usable AWS credentials found. Set summarizer.bedrock.profile in the config, or export AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY.")
        }
        if lower.contains("resourcenotfound") || lower.contains("model identifier") || lower.contains("validationexception") {
            hints.append("Model \"\(modelID)\" may not be available in \(region) — some models require a cross-region inference profile ID (e.g. a \"us.\" prefix).")
        }
        let hintText = hints.isEmpty ? "" : "\n" + hints.joined(separator: "\n")
        return "Bedrock request failed: \(raw.prefix(500))\(hintText)"
    }
}
