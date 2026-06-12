import Foundation

enum PipelineState {
    case transcribing
    case summarizing
    case done(URL)
    case failed(String)
    case discarded
}

struct PipelineOutcome {
    let noteURL: URL?
    let errorMessage: String?
}

/// Runs the post-meeting pipeline: transcribe both channels → merge → summarize
/// → render → write to the vault. Invariant: once there is audio worth keeping,
/// the transcript is never lost — a note is always written even when
/// transcription is partial or summarization fails, and audio is force-kept on
/// any transcription failure.
final class MeetingPipeline {
    private let config: Config
    private let transcriber: WhisperTranscriber

    init(config: Config) {
        self.config = config
        self.transcriber = WhisperTranscriber(config: config.whisper)
    }

    @discardableResult
    func run(session: RecordingSession,
             titleOverride: String? = nil,
             ignoreMinDuration: Bool = false,
             stateSink: @escaping (PipelineState) -> Void) async -> PipelineOutcome {
        let meta = session.meta
        let startedAt = meta.startedAt
        let endedAt = meta.endedAt ?? Date()

        var durationSeconds = Int(endedAt.timeIntervalSince(startedAt))
        let micDuration = WAVWriter.dataDurationSeconds(at: session.micWAVURL) ?? 0
        let systemDuration = WAVWriter.dataDurationSeconds(at: session.systemWAVURL) ?? 0
        if durationSeconds <= 0 {
            durationSeconds = Int(max(micDuration, systemDuration))
        }

        // 1. Too short → discard (pre-join misclicks, accidental joins).
        if !ignoreMinDuration && Double(durationSeconds) < config.detection.minMeetingDurationSeconds {
            Log.info("Discarding \(session.directory.lastPathComponent): \(durationSeconds)s is under the \(Int(config.detection.minMeetingDurationSeconds))s minimum.")
            session.update { m in
                m.state = .discarded
                if m.endedAt == nil { m.endedAt = endedAt }
            }
            if !config.recording.keepAudio {
                try? FileManager.default.removeItem(at: session.directory)
            }
            stateSink(.discarded)
            return PipelineOutcome(noteURL: nil, errorMessage: nil)
        }

        session.update { m in
            m.state = .processing
            if m.endedAt == nil { m.endedAt = endedAt }
        }

        // 2. Transcribe each channel serially — large whisper models are
        // memory-hungry, and this is a background batch job.
        stateSink(.transcribing)
        var meSegments: [WhisperSegment] = []
        var themSegments: [WhisperSegment] = []
        var channelWarnings: [String] = []
        var channelsPresent = 0
        var channelsTranscribed = 0

        if let result = await transcribeWithRetry(session.micWAVURL, label: "mic") {
            channelsPresent += 1
            switch result {
            case .success(let segments):
                meSegments = TranscriptMerger.shift(segments, byMS: meta.micStartOffsetMS ?? 0)
                channelsTranscribed += 1
            case .failure(let error):
                channelWarnings.append("The mic channel failed to transcribe: \(describeError(error))")
            }
        }
        if let result = await transcribeWithRetry(session.systemWAVURL, label: "system audio") {
            channelsPresent += 1
            switch result {
            case .success(let segments):
                themSegments = TranscriptMerger.shift(segments, byMS: meta.systemStartOffsetMS ?? 0)
                channelsTranscribed += 1
            case .failure(let error):
                channelWarnings.append("The Teams audio channel failed to transcribe: \(describeError(error))")
            }
        }

        // 2b. Speaker labels for the remote channel: diarization clusters
        // ("Speaker N") plus any active-speaker names captured live from the
        // Teams UI. Failures degrade to plain "Them" — never fatal.
        var diarizationTurns: [SpeakerInterval] = []
        if config.diarization.enabled, !themSegments.isEmpty {
            do {
                let turns = try await SpeakerDiarizer(config: config.diarization)
                    .diarize(wav: session.systemWAVURL)
                diarizationTurns = SpeakerLabeler.shift(turns, byMS: meta.systemStartOffsetMS ?? 0)
            } catch {
                Log.error("Diarization failed: \(describeError(error))")
                channelWarnings.append("Speaker diarization failed (transcript falls back to \"Them\"): \(describeError(error))")
            }
        }
        let activeSpeakers = ActiveSpeakerLog.load(from: session.directory)

        let transcriptionFailed = channelsPresent > 0 && channelsTranscribed == 0
        let transcriptionDegraded = channelsTranscribed < channelsPresent

        // 3. Total transcription failure → still write a note with the
        // metadata, the error, and where the (force-kept) audio lives.
        if transcriptionFailed || channelsPresent == 0 {
            let message = channelWarnings.isEmpty
                ? "No audio was recorded."
                : channelWarnings.joined(separator: " ")
            channelWarnings.append("Audio files were kept at \(session.directory.path).")
            let summary = MeetingSummary(
                title: SummaryParser.fallbackTitle(startedAt),
                summary: "Transcription failed, so no transcript or summary is available for this meeting.",
                keyPoints: [], actionItems: [], decisions: [],
                warning: nil)
            let markdown = MarkdownRenderer.render(
                summary: summary, transcript: "", startedAt: startedAt,
                durationSeconds: durationSeconds, partial: meta.partial,
                extraWarnings: channelWarnings)
            let noteURL = try? VaultWriter.write(
                markdown: markdown, title: summary.title, startedAt: startedAt, config: config.vault)
            session.update { $0.state = .failed }
            stateSink(.failed(message))
            return PipelineOutcome(noteURL: noteURL, errorMessage: message)
        }

        let labeledThem = SpeakerLabeler.label(
            themSegments: themSegments,
            diarization: diarizationTurns,
            activeSpeakers: activeSpeakers)
        let transcript = TranscriptMerger.merge(me: meSegments, labeledThem: labeledThem)
        let context = MeetingContext(
            title: meta.eventTitle,
            attendees: meta.attendees ?? [],
            organizer: meta.organizer)

        // 4. Summarize (one retry; degrades to a transcript-only note on failure).
        stateSink(.summarizing)
        var summary: MeetingSummary
        if transcript.isEmpty {
            summary = MeetingSummary(
                title: SummaryParser.fallbackTitle(startedAt),
                summary: "No speech was transcribed in this meeting.",
                keyPoints: [], actionItems: [], decisions: [],
                warning: nil)
        } else {
            summary = await summarizeWithRetry(
                transcript: transcript, startedAt: startedAt,
                durationSeconds: durationSeconds, context: context)
        }
        // Title preference: explicit override > calendar/window title > AI title.
        if let eventTitle = meta.eventTitle, !eventTitle.isEmpty {
            summary.title = eventTitle
        }
        if let titleOverride, !titleOverride.isEmpty {
            summary.title = titleOverride
        }

        // 5. Render and write. The vault write is the last thing that can fail;
        // if it does, everything is kept on disk.
        let markdown = MarkdownRenderer.render(
            summary: summary, transcript: transcript, startedAt: startedAt,
            durationSeconds: durationSeconds, partial: meta.partial,
            attendees: meta.attendees ?? [], organizer: meta.organizer,
            taskTag: config.vault.taskTag,
            extraWarnings: channelWarnings)
        do {
            let noteURL = try VaultWriter.write(
                markdown: markdown, title: summary.title, startedAt: startedAt, config: config.vault)
            session.update { m in
                m.state = .done
                m.noteTitle = summary.title
            }
            cleanupAudio(session: session, forceKeep: transcriptionDegraded)
            stateSink(.done(noteURL))
            return PipelineOutcome(noteURL: noteURL, errorMessage: nil)
        } catch {
            let message = describeError(error)
            Log.error("Could not write note: \(message)")
            session.update { $0.state = .failed }
            stateSink(.failed(message))
            return PipelineOutcome(noteURL: nil, errorMessage: message)
        }
    }

    // MARK: - Steps

    /// nil when the channel has no usable audio file.
    private func transcribeWithRetry(_ url: URL, label: String) async -> Result<[WhisperSegment], Error>? {
        guard FileManager.default.fileExists(atPath: url.path),
              (WAVWriter.dataDurationSeconds(at: url) ?? 0) > 0.5 else { return nil }
        do {
            return .success(try await transcriber.transcribe(wav: url))
        } catch {
            Log.error("Transcription of \(label) failed, retrying once: \(describeError(error))")
            do {
                return .success(try await transcriber.transcribe(wav: url))
            } catch {
                return .failure(error)
            }
        }
    }

    private func summarizeWithRetry(transcript: String, startedAt: Date,
                                    durationSeconds: Int, context: MeetingContext?) async -> MeetingSummary {
        do {
            let summarizer = try SummarizerFactory.make(config: config.summarizer)
            do {
                return try await summarizer.summarize(
                    transcript: transcript, meetingDate: startedAt,
                    durationSeconds: durationSeconds, context: context)
            } catch {
                Log.error("Summarization failed, retrying once: \(describeError(error))")
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                return try await summarizer.summarize(
                    transcript: transcript, meetingDate: startedAt,
                    durationSeconds: durationSeconds, context: context)
            }
        } catch {
            // Never lose the transcript: degrade to a transcript-only note.
            let message = describeError(error)
            Log.error("Summarization failed: \(message)")
            return MeetingSummary(
                title: SummaryParser.fallbackTitle(startedAt),
                summary: "",
                keyPoints: [], actionItems: [], decisions: [],
                warning: "Summarization failed: \(message) The transcript is below.")
        }
    }

    private func cleanupAudio(session: RecordingSession, forceKeep: Bool) {
        guard !config.recording.keepAudio, !forceKeep else { return }
        try? FileManager.default.removeItem(at: session.micWAVURL)
        try? FileManager.default.removeItem(at: session.systemWAVURL)
    }
}
