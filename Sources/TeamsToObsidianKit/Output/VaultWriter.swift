import Foundation

/// Writes notes into the Obsidian vault. An Obsidian vault is just a folder of
/// Markdown files — the write is a hidden temp file plus a same-volume rename,
/// so Obsidian never indexes a half-written note.
enum VaultWriter {
    static func write(markdown: String, title: String, startedAt: Date, config: Config.Vault) throws -> URL {
        let vault = Paths.expand(config.path)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: vault.path, isDirectory: &isDir), isDir.boolValue else {
            throw CLIError("Obsidian vault not found at \(vault.path) — set vault.path in \(Paths.configFile.path).")
        }
        let folder = config.notesFolder.isEmpty
            ? vault
            : vault.appendingPathComponent(config.notesFolder)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        let dateFormatter = DateFormatter()
        dateFormatter.locale = Locale(identifier: "en_US_POSIX")
        dateFormatter.dateFormat = "yyyy-MM-dd HHmm"

        let base = config.filenameTemplate
            .replacingOccurrences(of: "{date}", with: dateFormatter.string(from: startedAt))
            .replacingOccurrences(of: "{title}", with: sanitizeFilename(title))
            .trimmingCharacters(in: .whitespaces)

        var destination = folder.appendingPathComponent(base + ".md")
        var counter = 2
        while FileManager.default.fileExists(atPath: destination.path) && counter < 100 {
            destination = folder.appendingPathComponent("\(base) (\(counter)).md")
            counter += 1
        }

        let temp = folder.appendingPathComponent(".tto-tmp-\(UUID().uuidString)")
        try Data(markdown.utf8).write(to: temp)
        do {
            try FileManager.default.moveItem(at: temp, to: destination)
        } catch {
            try? FileManager.default.removeItem(at: temp)
            throw error
        }
        Log.info("Wrote note: \(destination.path)")
        return destination
    }

    /// Strips characters that are illegal in filenames or special in Obsidian links.
    static func sanitizeFilename(_ title: String) -> String {
        let illegal = Set<Character>("/\\:|#^[]?*\"<>\n\r\t")
        var s = String(title.map { illegal.contains($0) ? " " : $0 })
        while s.contains("  ") {
            s = s.replacingOccurrences(of: "  ", with: " ")
        }
        s = s.trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: ".")))
        return s.isEmpty ? "Meeting" : s
    }
}
