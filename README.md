# teams-to-obsidian

A macOS menu bar app that automatically records the Microsoft Teams meetings you
join, transcribes them **locally** with [whisper.cpp](https://github.com/ggml-org/whisper.cpp),
summarizes them with a **configurable AI model** (AWS Bedrock or local Ollama),
and writes a Markdown note — AI summary, action items, decisions, and the full
"Me / Them" transcript — into your Obsidian vault.

**Privacy:** at runtime the app makes **zero network calls except to AWS
Bedrock** (and only when the Bedrock backend is selected). Transcription is
fully local; the Ollama backend talks only to `localhost`. No telemetry, no
update checks. The one-time `scripts/setup-whisper.sh` setup step downloads
whisper.cpp and a model (github.com + huggingface.co) — that's it.

## How it works

1. **Detect** — Teams holds the microphone open for the duration of a meeting
   (even while muted). The app watches Core Audio process objects for
   `com.microsoft.teams2*` running audio input; debounced start/stop.
2. **Record** — two crash-safe 16 kHz WAVs: your mic via `AVAudioEngine`, and
   Teams' audio output via a **Core Audio process tap** (macOS 14.4+), so only
   Teams audio is captured — not your music or notification sounds.
3. **Transcribe** — when the meeting ends, each channel runs through
   `whisper-cli` (Metal-accelerated), then the two are merged into a single
   timeline labeled **Me** / **Them**.
4. **Summarize** — the transcript goes to your configured model: AWS Bedrock
   (Converse API — any Bedrock model ID works) or local Ollama.
5. **Write** — a note lands in your vault. If summarization fails, the note is
   still written with the full transcript — audio/transcripts are never lost.

## Requirements

- Apple Silicon Mac, **macOS 14.4 or newer**
- Xcode Command Line Tools (`xcode-select --install`) and `cmake`
  (`brew install cmake`) to build
- The **new Teams** desktop client (bundle ID `com.microsoft.teams2`).
  Teams-in-a-browser is not detected.
- For Bedrock: AWS credentials (profile/SSO/env) with model access enabled in
  your region. For Ollama: [Ollama](https://ollama.com) running locally with a
  pulled model.

## Setup

```sh
git clone <this repo> && cd teams-to-obsidian

make build                  # builds the binary (first build is slow — AWS SDK)
make whisper                # one-time: clone+build whisper.cpp, download the model
.build/release/teams-to-obsidian init-config
open ~/.config/teams-to-obsidian/config.json   # set vault.path at minimum
```

Then install the menu bar app and grant permissions:

```sh
make install                # assembles, ad-hoc signs, copies to /Applications
open /Applications/TeamsToObsidian.app
```

Click the menu bar icon → **Request Permissions…** and approve:

1. **Microphone** (Privacy & Security → Microphone)
2. **System Audio Recording Only** (Privacy & Security → Screen & System Audio
   Recording) — this is what lets the app record Teams' output.

Finally, enable **Start at Login** from the menu. Done — join a Teams meeting
and a note appears in your vault a few minutes after you leave.

> Recording notice: you are responsible for complying with the consent laws
> that apply to your meetings. Headphones are recommended — without them the
> far end can bleed into your mic and duplicate text between Me/Them.

## Configuration

`~/.config/teams-to-obsidian/config.json` (see `config.example.json`; all keys
optional — missing keys keep their defaults):

| Key | Default | Meaning |
|---|---|---|
| `vault.path` | `~/Documents/ObsidianVault` | Your Obsidian vault folder — **edit this** |
| `vault.notesFolder` | `Meetings` | Folder inside the vault for notes |
| `vault.filenameTemplate` | `{date} {title}` | `{date}` = `yyyy-MM-dd HHmm` |
| `whisper.cliPath` / `modelPath` | setup-whisper.sh locations | whisper-cli binary and ggml model |
| `whisper.language` | `en` | Whisper language, or `auto` |
| `summarizer.backend` | `bedrock` | `bedrock` or `ollama` |
| `summarizer.bedrock.modelID` | `anthropic.claude-opus-4-8` | **Any Bedrock model ID** — opaque string; inference profiles (`us.` prefix) work too |
| `summarizer.bedrock.region` | `us-east-1` | Bedrock region |
| `summarizer.bedrock.profile` | _(default chain)_ | AWS profile name (supports SSO) |
| `summarizer.ollama.model` | `llama3.1` | `ollama pull <model>` first |
| `summarizer.maxTranscriptChars` | `200000` | Longer transcripts are truncated from the front (the tail has the action items) |
| `summarizer.promptTemplatePath` | _(built-in)_ | File that replaces the instruction prompt |
| `detection.minMeetingDurationSeconds` | `60` | Shorter recordings are discarded |
| `detection.useOutputSignal` | `false` | Also treat Teams audio *output* as meeting-active (escape hatch) |
| `capture.captureMode` | `processTap` | `globalExclude` = record all system audio instead (fallback) |
| `capture.micVoiceProcessing` | `false` | Apple echo cancellation on the mic (experimental) |
| `recording.keepAudio` | `false` | Keep WAVs after the note is written (always kept on transcription failure) |

**Whisper model:** the default `large-v3-turbo-q5_0` (~574 MB) is near-large
accuracy at ~8× speed — comfortably faster than real time on any M-series Mac,
and worth it for compressed multi-speaker meeting audio. Low-RAM alternative:
`TTO_WHISPER_MODEL=small.en make whisper` (then update `whisper.modelPath`).

## CLI

The same binary doubles as a CLI (`.build/release/teams-to-obsidian`, or
`/Applications/TeamsToObsidian.app/Contents/MacOS/teams-to-obsidian`):

```sh
teams-to-obsidian                      # run the menu bar app (default)
teams-to-obsidian init-config [--force]
teams-to-obsidian process --mic me.wav --system them.wav [--title "Weekly sync"]
                                       # full pipeline on existing audio — no meeting needed
teams-to-obsidian test-summarizer [--backend bedrock|ollama]
teams-to-obsidian record-test --seconds 10 [--bundle-id com.apple.Music] [--mic-only|--system-only] [--global]
```

Note: when CLI subcommands trigger permission prompts, macOS attributes the
grant to your *terminal app*, not to TeamsToObsidian.app — the installed app
needs its own grants (menu → Request Permissions…).

## Verifying the install

1. **Offline pipeline** (no permissions needed):
   ```sh
   say -o me.aiff "Action item: I will send the budget report on Friday."
   afconvert me.aiff -o me.wav -d LEI16@16000 -c 1 -f WAVE
   say -o them.aiff -v Daniel "Thanks. We decided to ship version two next month."
   afconvert them.aiff -o them.wav -d LEI16@16000 -c 1 -f WAVE
   teams-to-obsidian process --mic me.wav --system them.wav
   ```
   Open the note in Obsidian: frontmatter, summary, a `- [ ]` action item, and
   an interleaved Me/Them transcript.
2. **Backends:** `teams-to-obsidian test-summarizer --backend ollama` and
   `--backend bedrock` (failures print actionable hints).
3. **Capture:** play a song in Music.app, then
   `teams-to-obsidian record-test --seconds 10 --bundle-id com.apple.Music` —
   the WAV should contain the song and report a non-zero peak RMS. Repeat with
   `--mic-only` while speaking.
4. **End-to-end:** start a Teams "Meet now" with a second device, talk on both
   sides for >1 minute, leave. Watch the icon cycle record → transcribe →
   summarize; the note appears in your vault.
5. **Crash drill:** `kill -9` the app mid-meeting, relaunch — it repairs the
   WAV headers and produces the note ("orphan recovery").
6. **Privacy audit:** run `lsof -i -P | grep teams-to` through a full cycle.
   With Ollama you'll see only `localhost:11434`; with Bedrock only
   `bedrock-runtime.<region>.amazonaws.com`.

## Troubleshooting

**The system-audio WAV is silent for Teams** (known field report: process taps
on Teams occasionally deliver silence, likely due to helper-process routing).
The app already mitigates: it taps *all* `com.microsoft.teams2*` helper
processes, reads the tap's true sample rate (Teams uses 24 kHz), and a 30-second
silence watchdog rebuilds the tap mid-meeting. If it persists, set
`"capture": { "captureMode": "globalExclude" }` — that records all system audio
(reliable, at the cost of capturing notification sounds too).

**Permission prompts keep reappearing after rebuilds.** Ad-hoc signatures tie
TCC grants to the binary hash. For development, reset with
`tccutil reset Microphone net.jbip.teams-to-obsidian` and re-grant, or create a
self-signed code-signing certificate in Keychain Access and sign with it for a
stable identity.

**Bedrock errors.** `test-summarizer` surfaces the usual causes: expired SSO
session (`aws sso login --profile …`), model access not enabled in the region
(Bedrock console → Model access), or a model that needs an inference-profile ID
(`us.`-prefixed) instead of the bare model ID.

**Meetings aren't detected.** Confirm you run the *new* Teams app. While in a
meeting, the mic indicator (orange dot) should be on — that's the signal used.
If a Teams update changes mute behavior, set `detection.useOutputSignal: true`.

**Meeting ended but no note.** Check the menu icon state and
`~/Library/Logs/teams-to-obsidian/teams-to-obsidian.log`. Recordings under 60s
are discarded by design (`detection.minMeetingDurationSeconds`).

## Development

- `Sources/TeamsToObsidianKit/` — all logic (Capture, Detection, Transcription,
  Summarization, Pipeline, Output, App, CLI). The executable target is a shim.
- `make test` runs unit tests for the pure logic (merger, parsers, renderer,
  config, WAV writer).
- `aws-sdk-swift` is pinned to an exact version in `Package.swift`: the Bedrock
  client uses `BedrockRuntimeClientConfiguration`, which that version marks
  deprecated (in favor of `BedrockRuntimeClientConfig`) but still ships.
  Migrate the two call sites in `BedrockSummarizer.makeClient` when bumping the
  dependency. Commit `Package.resolved` after a successful build for fully
  reproducible dependency resolution.
