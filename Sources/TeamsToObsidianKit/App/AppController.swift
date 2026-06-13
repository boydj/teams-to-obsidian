import AppKit
import CoreAudio
import Foundation

/// Glue between the detector, the active recording, and the pipeline queue.
/// MainActor: all mutation happens on the main thread; detector and audio
/// callbacks hop here via Task.
@MainActor
final class AppController {
    let config: Config
    let store = AppStateStore()

    private let configProblem: String?
    private let detector: MeetingDetector
    private let pipeline: MeetingPipeline

    private var active: ActiveRecording?
    private var orphans: [RecordingSession] = []

    private struct PipelineJob {
        let session: RecordingSession
        let titleOverride: String?
        let ignoreMinDuration: Bool
    }
    private var pipelineJobs: [PipelineJob] = []
    private var pipelineBusy = false
    private(set) var lastNoteURL: URL?
    private var workspaceObservers: [NSObjectProtocol] = []

    var orphanCount: Int { orphans.count }

    init(config: Config, configProblem: String?) {
        self.config = config
        self.configProblem = configProblem
        self.detector = MeetingDetector(config: config.detection)
        self.pipeline = MeetingPipeline(config: config)
    }

    func start() {
        // Microphone and system-audio recording can only be requested from a
        // real .app bundle (the Info.plist usage strings + bundle identity are
        // what let macOS prompt and list the app under Privacy & Security).
        // A bare binary detects meetings but can never record — warn loudly.
        if Bundle.main.bundleURL.pathExtension != "app" {
            let message = "Running as a bare binary — mic and system-audio recording won't work and "
                + "the app won't appear under Privacy & Security. Build and run the bundle: "
                + "`make install` then open /Applications/TeamsToObsidian.app."
            Log.error(message)
            store.set(.error(message))
        }

        if let configProblem {
            store.set(.error(configProblem))
        }

        // Scan for orphans BEFORE any new recording can create a .recording session.
        orphans = OrphanRecovery.findOrphans(recordingsDir: config.recordingsDir)
        if !orphans.isEmpty {
            Log.info("Found \(orphans.count) orphaned recording(s) from a previous run.")
            recoverOrphans()
        }

        detector.onMeetingStart = { [weak self] ids in
            Task { @MainActor in self?.meetingStarted(processObjectIDs: ids, partial: false) }
        }
        detector.onMeetingEnd = { [weak self] in
            Task { @MainActor in self?.meetingEnded(manual: false) }
        }
        detector.start()

        // Catch a meeting already in progress at launch.
        if detector.currentlyActive() {
            Log.info("Teams meeting already in progress at launch — starting a partial recording.")
            meetingStarted(processObjectIDs: detector.currentTeamsProcessObjectIDs(), partial: true)
        }

        installWorkspaceObservers()

        // First run: fire the TCC prompts automatically so the user doesn't
        // have to find the menu item. Only when bundled (a bare binary can't)
        // and only when the mic permission has never been decided, so this
        // never nags after the first grant/deny.
        if Bundle.main.bundleURL.pathExtension == "app", PermissionRequester.microphoneUndetermined() {
            Log.info("First launch with undetermined permissions — requesting automatically.")
            Task { @MainActor in
                let previousPolicy = NSApp.activationPolicy()
                NSApp.setActivationPolicy(.regular)
                NSApp.activate(ignoringOtherApps: true)
                _ = await PermissionRequester.requestAll()
                NSApp.setActivationPolicy(previousPolicy)
            }
        }
    }

    /// Called from applicationWillTerminate: make the WAVs valid so orphan
    /// recovery can finish the job on the next launch.
    func prepareForTermination() {
        guard let recording = active else { return }
        Log.info("Terminating while recording — finalizing WAVs for recovery on next launch.")
        teardown(recording)
        // meta stays .recording → picked up as an orphan next launch.
        active = nil
    }

    // MARK: - Menu actions

    func stopAndProcessNow() {
        meetingEnded(manual: true)
    }

    func togglePause() {
        if store.paused {
            detector.start()
            store.setPaused(false)
        } else {
            if active != nil { meetingEnded(manual: true) }
            detector.stop()
            store.setPaused(true)
        }
    }

    func reprocessLastRecording() {
        guard let session = findLatestReprocessable() else {
            showAlert("No recordings available",
                      "No kept recordings were found under \(config.recordingsDir.path). " +
                      "Enable recording.keepAudio in the config to keep audio after notes are written.")
            return
        }
        enqueuePipeline(PipelineJob(session: session, titleOverride: nil, ignoreMinDuration: true))
    }

    func recoverOrphans() {
        guard !orphans.isEmpty else { return }
        store.set(.recovering(orphans.count))
        for orphan in orphans {
            OrphanRecovery.prepare(orphan)
            enqueuePipeline(PipelineJob(session: orphan, titleOverride: nil, ignoreMinDuration: false))
        }
        orphans = []
    }

    // MARK: - Meeting lifecycle

    private func meetingStarted(processObjectIDs: [AudioObjectID], partial: Bool) {
        guard active == nil, !store.paused else { return }
        do {
            let session = try RecordingSession.create(in: config.recordingsDir, partial: partial)
            let micWriter = try WAVWriter(url: session.micWAVURL)
            let systemWriter = try WAVWriter(url: session.systemWAVURL)
            let recording = ActiveRecording(session: session, micWriter: micWriter, systemWriter: systemWriter)
            var startedAnything = false

            let mic = MicRecorder(writer: micWriter, voiceProcessing: config.capture.micVoiceProcessing)
            do {
                try mic.start()
                recording.mic = mic
                let offset = Int(Date().timeIntervalSince(session.meta.startedAt) * 1000)
                session.update { $0.micStartOffsetMS = offset }
                startedAnything = true
            } catch {
                Log.error("Mic capture failed: \(describeError(error))")
            }

            let tap = ProcessTapRecorder(mode: tapMode(processObjectIDs), writer: systemWriter)
            do {
                try tap.start()
                recording.tap = tap
                let offset = Int(Date().timeIntervalSince(session.meta.startedAt) * 1000)
                session.update { $0.systemStartOffsetMS = offset }
                startedAnything = true
            } catch {
                Log.error("System audio capture failed: \(describeError(error))")
            }

            guard startedAnything else {
                micWriter.finalize()
                systemWriter.finalize()
                try? FileManager.default.removeItem(at: session.directory)
                store.set(.error("Recording failed: could not start mic or system audio capture — check permissions (menu → Request Permissions…)."))
                return
            }

            active = recording
            store.set(.recording(session.meta.startedAt))
            startWatchdog(for: recording)
            installDeviceChangeObserver(for: recording)
            captureContext(for: recording)
            if config.context.captureActiveSpeakers {
                let observer = ActiveSpeakerObserver(
                    pattern: config.context.activeSpeakerPattern,
                    anchor: session.meta.startedAt,
                    outputURL: ActiveSpeakerLog.url(in: session.directory))
                observer.start()
                recording.speakerObserver = observer
            }
        } catch {
            store.set(.error("Could not start recording: \(describeError(error))"))
        }
    }

    /// Gathers the calendar event / Teams window title for note enrichment.
    /// The meeting window title can appear a few seconds after join, so a
    /// second look happens 15s in if the first found nothing.
    private func captureContext(for recording: ActiveRecording) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            let context = await MeetingContextProvider.capture(config: self.config.context)
            if self.active === recording, !context.isEmpty {
                recording.session.update { m in
                    if m.eventTitle == nil { m.eventTitle = context.title }
                    if !context.attendees.isEmpty { m.attendees = context.attendees }
                    if let organizer = context.organizer { m.organizer = organizer }
                }
            }
            guard context.title == nil, self.config.context.useWindowTitle else { return }
            try? await Task.sleep(nanoseconds: 15_000_000_000)
            guard self.active === recording else { return }
            if let title = MeetingContextProvider.teamsWindowTitle() {
                recording.session.update { m in
                    if m.eventTitle == nil { m.eventTitle = title }
                }
            }
        }
    }

    private func meetingEnded(manual: Bool) {
        guard let recording = active else { return }
        active = nil
        if manual {
            detector.suppressUntilInactive()
        }
        teardown(recording)
        recording.session.update { m in
            if m.endedAt == nil { m.endedAt = Date() }
        }
        enqueuePipeline(PipelineJob(session: recording.session, titleOverride: nil, ignoreMinDuration: false))
    }

    private func teardown(_ recording: ActiveRecording) {
        recording.watchdog?.invalidate()
        recording.watchdog = nil
        recording.deviceObserver?.invalidate()
        recording.deviceObserver = nil
        recording.speakerObserver?.stop()
        recording.speakerObserver = nil
        recording.mic?.stop()
        recording.tap?.stop()
        recording.micWriter.finalize()
        recording.systemWriter.finalize()
    }

    private func tapMode(_ ids: [AudioObjectID]) -> ProcessTapRecorder.Mode {
        config.capture.captureMode.lowercased() == "globalexclude"
            ? .globalExcludingNone
            : .processes(ids)
    }

    // MARK: - Tap resilience

    private func startWatchdog(for recording: ActiveRecording) {
        guard recording.tap != nil else { return }
        recording.watchdog = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.watchdogTick() }
        }
    }

    private func watchdogTick() {
        guard let recording = active, let tap = recording.tap, !recording.watchdogRebuilt else { return }
        if Date().timeIntervalSince(tap.lastNonSilentAt) > 30 {
            Log.error("System audio has been silent for 30s — rebuilding the tap with refreshed Teams processes.")
            recording.watchdogRebuilt = true
            rebuildTap(for: recording)
        }
    }

    private func rebuildTap(for recording: ActiveRecording) {
        recording.tap?.stop()
        recording.tap = nil
        let tap = ProcessTapRecorder(mode: tapMode(detector.currentTeamsProcessObjectIDs()),
                                     writer: recording.systemWriter)
        do {
            try tap.start()
            recording.tap = tap
        } catch {
            Log.error("Tap rebuild failed: \(describeError(error))")
        }
    }

    /// AirPods connecting etc. change the default output device the aggregate
    /// references — rebuild the tap and keep appending to the same WAV.
    private func installDeviceChangeObserver(for recording: ActiveRecording) {
        recording.deviceObserver = CoreAudioPropertyObserver(
            objectID: .system,
            selector: kAudioHardwarePropertyDefaultOutputDevice,
            queue: DispatchQueue.global()) { [weak self] in
                Task { @MainActor in
                    guard let self, let current = self.active, current === recording else { return }
                    Log.info("Default output device changed — rebuilding the tap.")
                    self.rebuildTap(for: current)
                }
            }
    }

    // MARK: - Pipeline queue (one whisper at a time — large models are memory-hungry)

    private func enqueuePipeline(_ job: PipelineJob) {
        pipelineJobs.append(job)
        drainPipelineQueue()
    }

    private func drainPipelineQueue() {
        guard !pipelineBusy, !pipelineJobs.isEmpty else { return }
        let job = pipelineJobs.removeFirst()
        pipelineBusy = true
        Task { [weak self] in
            guard let self else { return }
            await self.pipeline.run(session: job.session,
                                    titleOverride: job.titleOverride,
                                    ignoreMinDuration: job.ignoreMinDuration) { state in
                Task { @MainActor in self.applyPipelineState(state) }
            }
            await MainActor.run {
                self.pipelineBusy = false
                self.drainPipelineQueue()
            }
        }
    }

    private func applyPipelineState(_ state: PipelineState) {
        // While a NEW meeting is recording, the recording state owns the icon.
        let recordingNow = active != nil
        switch state {
        case .transcribing:
            if !recordingNow { store.set(.transcribing) }
        case .summarizing:
            if !recordingNow { store.set(.summarizing) }
        case .done(let url):
            lastNoteURL = url
            NoteNotifier.shared.notifyNoteReady(noteURL: url, enabled: config.notifications.enabled)
            if !recordingNow { store.set(.idle) }
        case .failed(let message):
            if !recordingNow { store.set(.error(message)) }
        case .discarded:
            // The meeting was under the minimum length and was dropped — tell
            // the user so "no note appeared" isn't a silent mystery.
            NoteNotifier.shared.notifyMessage(
                title: "No note created",
                body: "That meeting was under the \(Int(config.detection.minMeetingDurationSeconds))s minimum. "
                    + "Adjust detection.minMeetingDurationSeconds in the config if that's too long.",
                enabled: config.notifications.enabled)
            if !recordingNow { store.set(.idle) }
        }
    }

    // MARK: - Helpers

    private func findLatestReprocessable() -> RecordingSession? {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: config.recordingsDir, includingPropertiesForKeys: nil) else { return nil }
        let activePath = active?.session.directory.path
        return entries
            .compactMap { RecordingSession.load(directory: $0) }
            .filter { $0.directory.path != activePath }
            .filter {
                FileManager.default.fileExists(atPath: $0.micWAVURL.path)
                    || FileManager.default.fileExists(atPath: $0.systemWAVURL.path)
            }
            .max { $0.meta.startedAt < $1.meta.startedAt }
    }

    private func installWorkspaceObservers() {
        let center = NSWorkspace.shared.notificationCenter
        workspaceObservers.append(center.addObserver(
            forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.active != nil else { return }
                Log.info("System is going to sleep — ending the active recording.")
                self.meetingEnded(manual: false)
            }
        })
        workspaceObservers.append(center.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                // If the meeting survived sleep, the detector's phase machine
                // won't re-fire start for it — start a new partial recording.
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                if self.active == nil && !self.store.paused && self.detector.currentlyActive() {
                    Log.info("Meeting still active after wake — starting a new partial recording.")
                    self.meetingStarted(processObjectIDs: self.detector.currentTeamsProcessObjectIDs(),
                                        partial: true)
                }
            }
        })
    }

    private func showAlert(_ title: String, _ message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.runModal()
    }
}

@MainActor
final class ActiveRecording {
    let session: RecordingSession
    let micWriter: WAVWriter
    let systemWriter: WAVWriter
    var mic: MicRecorder?
    var tap: ProcessTapRecorder?
    var watchdog: Timer?
    var deviceObserver: CoreAudioPropertyObserver?
    var speakerObserver: ActiveSpeakerObserver?
    var watchdogRebuilt = false

    init(session: RecordingSession, micWriter: WAVWriter, systemWriter: WAVWriter) {
        self.session = session
        self.micWriter = micWriter
        self.systemWriter = systemWriter
    }
}
