import Foundation

/// Finds recordings whose pipeline never finished (crash, force quit, power
/// loss) so they can be processed on the next launch.
enum OrphanRecovery {
    static func findOrphans(recordingsDir: URL) -> [RecordingSession] {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: recordingsDir, includingPropertiesForKeys: nil) else { return [] }
        return entries
            .filter { url in
                var isDir: ObjCBool = false
                return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
            }
            .compactMap { RecordingSession.load(directory: $0) }
            .filter { $0.meta.state == .recording || $0.meta.state == .processing }
            .sorted { $0.meta.startedAt < $1.meta.startedAt }
    }

    /// Repairs the unfinalized WAV headers so whisper can read them, and fills
    /// in a plausible end time from the last write.
    static func prepare(_ session: RecordingSession) {
        var lastWrite: Date?
        for url in [session.micWAVURL, session.systemWAVURL]
        where FileManager.default.fileExists(atPath: url.path) {
            try? WAVWriter.repairHeader(at: url)
            let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
            if let mtime = attrs?[.modificationDate] as? Date {
                lastWrite = max(lastWrite ?? mtime, mtime)
            }
        }
        session.update { m in
            if m.endedAt == nil {
                m.endedAt = lastWrite ?? Date()
            }
        }
    }
}
