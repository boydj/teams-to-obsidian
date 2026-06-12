import ArgumentParser
import Foundation

/// Public entry point called by the executable target.
public enum TeamsToObsidianCLI {
    public static func run() async {
        Log.mirrorToStderr = true
        await RootCommand.main()
    }
}

struct RootCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "teams-to-obsidian",
        abstract: "Record, transcribe, and summarize Microsoft Teams meetings into Obsidian.",
        discussion: """
        With no subcommand this runs the menu bar app, which auto-detects Teams \
        meetings, records them, transcribes locally with whisper.cpp, summarizes \
        with AWS Bedrock or local Ollama, and writes a note into your Obsidian vault.

        Runtime network access is limited to AWS Bedrock (when selected) and \
        localhost Ollama — nothing else, ever.
        """,
        version: "0.1.0",
        subcommands: [
            RunCommand.self,
            ProcessCommand.self,
            TestSummarizerCommand.self,
            RecordTestCommand.self,
            InitConfigCommand.self,
        ],
        defaultSubcommand: RunCommand.self)
}
