import Foundation

enum SessionState: String, Codable {
    case recording, processing, done, failed, discarded
}

struct SessionMeta: Codable {
    var startedAt: Date
    var endedAt: Date?
    var state: SessionState
    var partial: Bool
    var noteTitle: String?
    /// Per-channel recording start skew relative to startedAt, applied when merging.
    var micStartOffsetMS: Int?
    var systemStartOffsetMS: Int?
    /// Context captured at meeting start (calendar event or Teams window title).
    var eventTitle: String?
    var attendees: [String]?
    var organizer: String?
}

/// One directory per meeting under the recordings dir, holding mic.wav,
/// system.wav and meta.json. meta.json is rewritten at every state transition —
/// that is what drives orphan detection after a crash.
final class RecordingSession {
    let directory: URL
    private(set) var meta: SessionMeta

    var micWAVURL: URL { directory.appendingPathComponent("mic.wav") }
    var systemWAVURL: URL { directory.appendingPathComponent("system.wav") }
    private var metaURL: URL { directory.appendingPathComponent("meta.json") }

    private init(directory: URL, meta: SessionMeta) {
        self.directory = directory
        self.meta = meta
    }

    static func create(in recordingsDir: URL, partial: Bool, startedAt: Date = Date()) throws -> RecordingSession {
        try Paths.ensureDir(recordingsDir)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd'T'HH-mm-ss"
        let stamp = formatter.string(from: startedAt)
        var dir = recordingsDir.appendingPathComponent(stamp)
        var counter = 2
        while FileManager.default.fileExists(atPath: dir.path) {
            dir = recordingsDir.appendingPathComponent("\(stamp)-\(counter)")
            counter += 1
        }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let session = RecordingSession(
            directory: dir,
            meta: SessionMeta(startedAt: startedAt, endedAt: nil, state: .recording,
                              partial: partial, noteTitle: nil,
                              micStartOffsetMS: nil, systemStartOffsetMS: nil,
                              eventTitle: nil, attendees: nil, organizer: nil))
        session.persistMeta()
        return session
    }

    static func load(directory: URL) -> RecordingSession? {
        let metaURL = directory.appendingPathComponent("meta.json")
        if let data = try? Data(contentsOf: metaURL) {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            guard let meta = try? decoder.decode(SessionMeta.self, from: data) else { return nil }
            return RecordingSession(directory: directory, meta: meta)
        }
        // No meta but WAVs present (killed before the first persist): synthesize.
        // The directory creation date approximates the meeting start.
        let mic = directory.appendingPathComponent("mic.wav")
        let system = directory.appendingPathComponent("system.wav")
        guard FileManager.default.fileExists(atPath: mic.path)
                || FileManager.default.fileExists(atPath: system.path) else { return nil }
        let attrs = try? FileManager.default.attributesOfItem(atPath: directory.path)
        let started = (attrs?[.creationDate] as? Date)
            ?? (attrs?[.modificationDate] as? Date)
            ?? Date()
        return RecordingSession(
            directory: directory,
            meta: SessionMeta(startedAt: started, endedAt: nil, state: .recording,
                              partial: false, noteTitle: nil,
                              micStartOffsetMS: nil, systemStartOffsetMS: nil,
                              eventTitle: nil, attendees: nil, organizer: nil))
    }

    func update(_ mutate: (inout SessionMeta) -> Void) {
        mutate(&meta)
        persistMeta()
    }

    private func persistMeta() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            let data = try encoder.encode(meta)
            try data.write(to: metaURL, options: .atomic)
        } catch {
            Log.error("Could not persist session meta for \(directory.lastPathComponent): \(error)")
        }
    }
}
