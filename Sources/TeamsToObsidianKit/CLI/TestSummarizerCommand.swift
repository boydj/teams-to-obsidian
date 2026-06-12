import ArgumentParser
import Foundation

struct TestSummarizerCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "test-summarizer",
        abstract: "Verify connectivity to the configured summarizer backend.")

    @Option(help: "Override the configured backend: bedrock or ollama.")
    var backend: String?

    @Option(help: "Path to a config file.")
    var config: String?

    func run() async throws {
        var cfg = try ConfigLoader.load(path: config)
        if let backend {
            cfg.summarizer.backend = backend
        }
        let summarizer = try SummarizerFactory.make(config: cfg.summarizer)
        switch summarizer.name {
        case "bedrock":
            let b = cfg.summarizer.bedrock
            print("Checking Bedrock (model \(b.modelID), region \(b.region), profile \(b.profile ?? "default chain"))…")
        case "ollama":
            let o = cfg.summarizer.ollama
            print("Checking Ollama (model \(o.model) at \(o.baseURL))…")
        default:
            print("Checking \(summarizer.name)…")
        }
        do {
            let reply = try await summarizer.healthCheck()
            let trimmed = reply.trimmingCharacters(in: .whitespacesAndNewlines)
            print("OK — model replied: \(trimmed.prefix(200))")
        } catch {
            print("FAILED: \(describeError(error))")
            throw ExitCode.failure
        }
    }
}
