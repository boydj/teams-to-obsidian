import AppKit
import ApplicationServices
import Foundation

/// EXPERIMENTAL: polls the Teams windows' accessibility tree once a second
/// looking for "who is speaking right now" indicators, and records named
/// time intervals into speakers.json in the session directory. The pipeline
/// later stamps those names onto transcript segments (and onto whole
/// diarization clusters by overlap vote — see SpeakerLabeler).
///
/// Entirely dependent on what Teams exposes via Accessibility, which can
/// change with Teams updates — hence config-gated (context.captureActiveSpeakers)
/// and tunable (context.activeSpeakerPattern, first capture group = name).
/// Use `teams-to-obsidian speakers-test --dump` during a real meeting to see
/// the strings Teams exposes and tune the pattern.
final class ActiveSpeakerObserver {
    static let defaultPattern = #"(?i)^(.+?),?\s+(?:is\s+)?speaking\b"#

    private let regex: NSRegularExpression?
    private let anchor: Date
    private let outputURL: URL
    private let queue = DispatchQueue(label: "tto.active-speaker")
    private var timer: DispatchSourceTimer?
    /// Grace before an unseen speaker's interval is closed (UI flicker).
    private let graceMS = 2_500

    private var openIntervals: [String: (startMS: Int, lastSeenMS: Int)] = [:]
    private var closedIntervals: [SpeakerInterval] = []
    private var lastPersist = Date()

    init(pattern: String, anchor: Date, outputURL: URL) {
        self.regex = try? NSRegularExpression(pattern: pattern.isEmpty ? Self.defaultPattern : pattern)
        self.anchor = anchor
        self.outputURL = outputURL
        if regex == nil {
            Log.error("Invalid activeSpeakerPattern — active-speaker capture disabled for this meeting.")
        }
    }

    func start() {
        guard regex != nil, AXIsProcessTrusted() else {
            if regex != nil {
                Log.info("Accessibility not granted — active-speaker capture skipped.")
            }
            return
        }
        queue.sync {
            guard timer == nil else { return }
            let t = DispatchSource.makeTimerSource(queue: queue)
            t.schedule(deadline: .now() + 1, repeating: 1.0)
            t.setEventHandler { [weak self] in self?.tick() }
            t.resume()
            timer = t
            Log.info("Active-speaker capture started.")
        }
    }

    func stop() {
        queue.sync {
            timer?.cancel()
            timer = nil
            let nowMS = Int(Date().timeIntervalSince(anchor) * 1000)
            closeAll(atMS: nowMS)
            persist()
        }
    }

    // MARK: - Queue-only internals

    private func tick() {
        guard let regex else { return }
        let names = Self.matchNames(in: Self.collectTeamsStrings(), regex: regex)
        let nowMS = Int(Date().timeIntervalSince(anchor) * 1000)

        for name in names {
            if var open = openIntervals[name] {
                open.lastSeenMS = nowMS
                openIntervals[name] = open
            } else {
                openIntervals[name] = (startMS: nowMS, lastSeenMS: nowMS)
            }
        }
        for (name, open) in openIntervals where nowMS - open.lastSeenMS > graceMS {
            closedIntervals.append(SpeakerInterval(startMS: open.startMS,
                                                   endMS: open.lastSeenMS,
                                                   label: name))
            openIntervals.removeValue(forKey: name)
        }
        if Date().timeIntervalSince(lastPersist) > 30 {
            persist()
            lastPersist = Date()
        }
    }

    private func closeAll(atMS nowMS: Int) {
        for (name, open) in openIntervals {
            closedIntervals.append(SpeakerInterval(startMS: open.startMS,
                                                   endMS: min(open.lastSeenMS + graceMS, nowMS),
                                                   label: name))
        }
        openIntervals.removeAll()
    }

    private func persist() {
        var snapshot = closedIntervals
        for (name, open) in openIntervals {
            snapshot.append(SpeakerInterval(startMS: open.startMS, endMS: open.lastSeenMS, label: name))
        }
        guard !snapshot.isEmpty else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(snapshot.sorted { $0.startMS < $1.startMS }) {
            try? data.write(to: outputURL, options: .atomic)
        }
    }

    // MARK: - AX scanning (also used by the speakers-test CLI)

    /// All readable strings in the Teams windows' accessibility trees,
    /// bounded so an Electron mega-tree can't stall the poll.
    static func collectTeamsStrings(bundleIDPrefix: String = "com.microsoft.teams2",
                                    maxElements: Int = 5_000,
                                    maxDepth: Int = 30) -> [String] {
        var strings: [String] = []
        var visited = 0
        let apps = NSWorkspace.shared.runningApplications.filter {
            $0.bundleIdentifier?.hasPrefix(bundleIDPrefix) == true
        }
        for app in apps {
            let element = AXUIElementCreateApplication(app.processIdentifier)
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, kAXWindowsAttribute as CFString, &value) == .success,
                  let windows = value as? [AXUIElement] else { continue }
            for window in windows {
                walk(window, depth: 0, maxDepth: maxDepth, visited: &visited,
                     maxElements: maxElements, into: &strings)
            }
        }
        return strings
    }

    private static func walk(_ element: AXUIElement, depth: Int, maxDepth: Int,
                             visited: inout Int, maxElements: Int, into strings: inout [String]) {
        guard depth <= maxDepth, visited < maxElements else { return }
        visited += 1

        for attribute in [kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute] {
            var value: CFTypeRef?
            if AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
               let s = value as? String, !s.isEmpty {
                strings.append(s)
            }
        }

        var childrenValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenValue) == .success,
              let children = childrenValue as? [AXUIElement] else { return }
        for child in children {
            walk(child, depth: depth + 1, maxDepth: maxDepth, visited: &visited,
                 maxElements: maxElements, into: &strings)
        }
    }

    /// Applies the pattern; capture group 1 (or the whole match) is the name.
    static func matchNames(in strings: [String], regex: NSRegularExpression) -> Set<String> {
        var names: Set<String> = []
        for s in strings {
            let range = NSRange(s.startIndex..., in: s)
            guard let match = regex.firstMatch(in: s, range: range) else { continue }
            let groupRange = match.numberOfRanges > 1 ? match.range(at: 1) : match.range
            guard groupRange.location != NSNotFound, let r = Range(groupRange, in: s) else { continue }
            let name = String(s[r]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !name.isEmpty && name.count <= 80 {
                names.insert(name)
            }
        }
        return names
    }
}

enum ActiveSpeakerLog {
    static let filename = "speakers.json"

    static func url(in sessionDirectory: URL) -> URL {
        sessionDirectory.appendingPathComponent(filename)
    }

    static func load(from sessionDirectory: URL) -> [SpeakerInterval] {
        guard let data = try? Data(contentsOf: url(in: sessionDirectory)) else { return [] }
        return (try? JSONDecoder().decode([SpeakerInterval].self, from: data)) ?? []
    }
}
