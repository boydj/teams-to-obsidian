import CoreAudio
import Foundation

/// Decides when a Teams meeting is in progress by watching Core Audio process
/// objects: Teams holds the microphone input running for the whole meeting,
/// even while muted. Polling is the source of truth (the per-process IsRunning
/// listeners are known to be unreliable); a listener on the process list just
/// triggers an immediate re-check when audio processes come and go.
final class MeetingDetector {
    /// Called on the detector queue with the Teams audio process objects.
    var onMeetingStart: (([AudioObjectID]) -> Void)?
    /// Called on the detector queue.
    var onMeetingEnd: (() -> Void)?

    private let config: Config.Detection
    private let queue = DispatchQueue(label: "tto.detector")
    private var timer: DispatchSourceTimer?
    private var processListObserver: CoreAudioPropertyObserver?

    private enum Phase { case idle, meeting }
    private var phase = Phase.idle
    private var activeSince: Date?
    private var inactiveSince: Date?
    private var suppressed = false

    init(config: Config.Detection) {
        self.config = config
    }

    func start() {
        queue.sync {
            guard timer == nil else { return }
            let t = DispatchSource.makeTimerSource(queue: queue)
            t.schedule(deadline: .now() + 0.5, repeating: max(0.5, config.pollIntervalSeconds))
            t.setEventHandler { [weak self] in self?.evaluate() }
            t.resume()
            timer = t
            processListObserver = CoreAudioPropertyObserver(
                objectID: .system,
                selector: kAudioHardwarePropertyProcessObjectList,
                queue: queue) { [weak self] in self?.evaluate() }
        }
    }

    func stop() {
        queue.sync {
            timer?.cancel()
            timer = nil
            processListObserver?.invalidate()
            processListObserver = nil
            phase = .idle
            activeSince = nil
            inactiveSince = nil
            suppressed = false
        }
    }

    var isRunning: Bool { queue.sync { timer != nil } }

    /// True if Teams currently has audio input running — used at app launch to
    /// catch meetings already in progress.
    func currentlyActive() -> Bool {
        queue.sync { predicateActive(teamsProcesses()) }
    }

    func currentTeamsProcessObjectIDs() -> [AudioObjectID] {
        queue.sync { teamsProcesses() }
    }

    /// After a manual stop, ignore activity until the predicate has gone false
    /// once, so the same still-running meeting doesn't instantly restart a recording.
    func suppressUntilInactive() {
        queue.sync {
            suppressed = true
            phase = .idle
            activeSince = nil
            inactiveSince = nil
        }
    }

    // MARK: - Internals (detector queue only)

    private func teamsProcesses() -> [AudioObjectID] {
        let list = (try? AudioObjectID.readProcessList()) ?? []
        return list.filter { proc in
            let bundleID = proc.processBundleID
            guard !bundleID.isEmpty else { return false }
            return config.bundleIDPrefixes.contains { !$0.isEmpty && bundleID.hasPrefix($0) }
        }
    }

    private func predicateActive(_ processes: [AudioObjectID]) -> Bool {
        processes.contains { proc in
            if proc.processIsRunningInput { return true }
            if config.useOutputSignal && proc.processIsRunningOutput { return true }
            return false
        }
    }

    private func evaluate() {
        let processes = teamsProcesses()
        let active = predicateActive(processes)
        let now = Date()

        if suppressed {
            if !active { suppressed = false }
            return
        }

        switch phase {
        case .idle:
            if active {
                if activeSince == nil { activeSince = now }
                if now.timeIntervalSince(activeSince!) >= config.startDebounceSeconds {
                    phase = .meeting
                    inactiveSince = nil
                    Log.info("Meeting detected (\(processes.count) Teams audio process(es)).")
                    onMeetingStart?(processes)
                }
            } else {
                activeSince = nil
            }
        case .meeting:
            if active {
                inactiveSince = nil
            } else {
                if inactiveSince == nil { inactiveSince = now }
                if now.timeIntervalSince(inactiveSince!) >= config.endDebounceSeconds {
                    phase = .idle
                    activeSince = nil
                    Log.info("Meeting ended.")
                    onMeetingEnd?()
                }
            }
        }
    }
}
