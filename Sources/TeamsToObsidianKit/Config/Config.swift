import Foundation

/// App configuration, stored as JSON at ~/.config/teams-to-obsidian/config.json.
/// Every field has a default so a partial config file works; unknown keys are ignored.
struct Config: Codable {
    struct Vault: Codable {
        /// Path to the Obsidian vault (or any folder of Markdown files). Tilde is expanded.
        var path: String = "~/Documents/ObsidianVault"
        /// Folder inside the vault where meeting notes are written. Created if missing.
        var notesFolder: String = "Meetings"
        /// Note filename. {date} = "yyyy-MM-dd HHmm", {title} = sanitized AI title.
        var filenameTemplate: String = "{date} {title}"
        /// Appended to every action item, e.g. "#task" for the Obsidian Tasks
        /// plugin's global filter. Empty = plain "- [ ]" checkboxes.
        var taskTag: String = ""

        init() {}
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            path = c.decodeOr(String.self, .path, path)
            notesFolder = c.decodeOr(String.self, .notesFolder, notesFolder)
            filenameTemplate = c.decodeOr(String.self, .filenameTemplate, filenameTemplate)
            taskTag = c.decodeOr(String.self, .taskTag, taskTag)
        }
    }

    struct Whisper: Codable {
        /// Path to the whisper-cli binary built by scripts/setup-whisper.sh.
        var cliPath: String = "~/.local/share/teams-to-obsidian/whisper.cpp/build/bin/whisper-cli"
        /// Path to the ggml model file.
        var modelPath: String = "~/.local/share/teams-to-obsidian/whisper.cpp/models/ggml-large-v3-turbo-q5_0.bin"
        /// Whisper language code, or "auto" to detect.
        var language: String = "en"
        /// Threads for whisper-cli; 0 lets whisper pick.
        var threads: Int = 0

        init() {}
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            cliPath = c.decodeOr(String.self, .cliPath, cliPath)
            modelPath = c.decodeOr(String.self, .modelPath, modelPath)
            language = c.decodeOr(String.self, .language, language)
            threads = c.decodeOr(Int.self, .threads, threads)
        }
    }

    struct Bedrock: Codable {
        /// Bedrock model ID — opaque string. Anthropic models carry the "anthropic." prefix
        /// (e.g. "anthropic.claude-opus-4-8"); cross-region inference profiles use "us." etc.
        var modelID: String = "anthropic.claude-opus-4-8"
        var region: String = "us-east-1"
        /// AWS profile name from ~/.aws/config. nil = default credential chain
        /// (env vars, default profile, SSO, container/instance roles).
        var profile: String?
        /// Max tokens for the summary response.
        var maxTokens: Int = 4096

        init() {}
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            modelID = c.decodeOr(String.self, .modelID, modelID)
            region = c.decodeOr(String.self, .region, region)
            profile = c.decodeOr(String?.self, .profile, nil)
            maxTokens = c.decodeOr(Int.self, .maxTokens, maxTokens)
        }
    }

    struct Ollama: Codable {
        var baseURL: String = "http://localhost:11434"
        /// Model name as known to Ollama (`ollama pull <model>` first).
        var model: String = "llama3.1"

        init() {}
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            baseURL = c.decodeOr(String.self, .baseURL, baseURL)
            model = c.decodeOr(String.self, .model, model)
        }
    }

    struct Summarizer: Codable {
        /// "bedrock" or "ollama".
        var backend: String = "bedrock"
        var bedrock: Bedrock = Bedrock()
        var ollama: Ollama = Ollama()
        /// Transcripts longer than this are truncated from the FRONT (the tail
        /// usually carries the action items) before being sent to the model.
        var maxTranscriptChars: Int = 200_000
        /// Optional path to a file that replaces the built-in instruction (system) prompt.
        var promptTemplatePath: String?

        init() {}
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            backend = c.decodeOr(String.self, .backend, backend)
            bedrock = c.decodeOr(Bedrock.self, .bedrock, bedrock)
            ollama = c.decodeOr(Ollama.self, .ollama, ollama)
            maxTranscriptChars = c.decodeOr(Int.self, .maxTranscriptChars, maxTranscriptChars)
            promptTemplatePath = c.decodeOr(String?.self, .promptTemplatePath, nil)
        }
    }

    struct Detection: Codable {
        /// A meeting is "active" while any audio process whose bundle ID starts with one of
        /// these prefixes is running audio input. New Teams = com.microsoft.teams2 (helpers
        /// extend that prefix).
        var bundleIDPrefixes: [String] = ["com.microsoft.teams2"]
        /// Mic must be held continuously this long before we treat it as a meeting start.
        var startDebounceSeconds: Double = 3
        /// Mic must be released continuously this long before we treat it as a meeting end
        /// (absorbs brief drops/rejoins).
        var endDebounceSeconds: Double = 10
        /// Recordings shorter than this are discarded (pre-join misclicks).
        var minMeetingDurationSeconds: Double = 60
        /// Authoritative poll interval; Core Audio listeners only reduce latency.
        var pollIntervalSeconds: Double = 2
        /// Also treat "Teams is running audio OUTPUT" as meeting-active. Escape hatch in
        /// case a Teams update stops holding the mic while muted.
        var useOutputSignal: Bool = false

        init() {}
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            bundleIDPrefixes = c.decodeOr([String].self, .bundleIDPrefixes, bundleIDPrefixes)
            startDebounceSeconds = c.decodeOr(Double.self, .startDebounceSeconds, startDebounceSeconds)
            endDebounceSeconds = c.decodeOr(Double.self, .endDebounceSeconds, endDebounceSeconds)
            minMeetingDurationSeconds = c.decodeOr(Double.self, .minMeetingDurationSeconds, minMeetingDurationSeconds)
            pollIntervalSeconds = c.decodeOr(Double.self, .pollIntervalSeconds, pollIntervalSeconds)
            useOutputSignal = c.decodeOr(Bool.self, .useOutputSignal, useOutputSignal)
        }
    }

    struct Recording: Codable {
        /// Keep WAV files after a note is written (always kept when transcription fails).
        var keepAudio: Bool = false
        var directory: String = "~/Library/Application Support/teams-to-obsidian/recordings"

        init() {}
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            keepAudio = c.decodeOr(Bool.self, .keepAudio, keepAudio)
            directory = c.decodeOr(String.self, .directory, directory)
        }
    }

    struct Context: Codable {
        /// Match the recording to a calendar event (EventKit) for the real
        /// title, attendee names, and organizer. Outlook/Microsoft 365
        /// calendars work when the account is added in System Settings →
        /// Internet Accounts with Calendars enabled (read locally; the app
        /// never calls Microsoft's APIs). Needs the Calendar permission.
        var useCalendar: Bool = true
        /// Restrict the calendar lookup to these calendar names. Empty = all.
        var calendarNames: [String] = []
        /// Fall back to the Teams meeting window title (needs the
        /// Accessibility permission).
        var useWindowTitle: Bool = true

        init() {}
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            useCalendar = c.decodeOr(Bool.self, .useCalendar, useCalendar)
            calendarNames = c.decodeOr([String].self, .calendarNames, calendarNames)
            useWindowTitle = c.decodeOr(Bool.self, .useWindowTitle, useWindowTitle)
        }
    }

    struct Notifications: Codable {
        /// Post a "note ready" notification that opens the note in Obsidian.
        var enabled: Bool = true

        init() {}
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            enabled = c.decodeOr(Bool.self, .enabled, enabled)
        }
    }

    struct Capture: Codable {
        /// "processTap" taps only the Teams processes (preferred).
        /// "globalExclude" taps ALL system audio (fallback if the Teams tap records silence).
        var captureMode: String = "processTap"
        /// Enable Apple's voice processing (echo cancellation) on the mic. Experimental:
        /// can interact badly with Teams' own processing; recommended fix for echo is headphones.
        var micVoiceProcessing: Bool = false

        init() {}
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            captureMode = c.decodeOr(String.self, .captureMode, captureMode)
            micVoiceProcessing = c.decodeOr(Bool.self, .micVoiceProcessing, micVoiceProcessing)
        }
    }

    var vault: Vault = Vault()
    var whisper: Whisper = Whisper()
    var summarizer: Summarizer = Summarizer()
    var detection: Detection = Detection()
    var recording: Recording = Recording()
    var capture: Capture = Capture()
    var context: Context = Context()
    var notifications: Notifications = Notifications()

    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        vault = c.decodeOr(Vault.self, .vault, vault)
        whisper = c.decodeOr(Whisper.self, .whisper, whisper)
        summarizer = c.decodeOr(Summarizer.self, .summarizer, summarizer)
        detection = c.decodeOr(Detection.self, .detection, detection)
        recording = c.decodeOr(Recording.self, .recording, recording)
        capture = c.decodeOr(Capture.self, .capture, capture)
        context = c.decodeOr(Context.self, .context, context)
        notifications = c.decodeOr(Notifications.self, .notifications, notifications)
    }
}

extension Config {
    var recordingsDir: URL { Paths.expand(recording.directory) }
}
