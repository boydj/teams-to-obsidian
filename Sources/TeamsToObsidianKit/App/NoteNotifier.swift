import AppKit
import Foundation
import UserNotifications

/// Posts "note ready" notifications and opens notes in Obsidian. The
/// UserNotifications framework only works from a real .app bundle, so all of
/// this no-ops when running as a bare CLI binary.
@MainActor
final class NoteNotifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NoteNotifier()

    private var available: Bool { Bundle.main.bundleURL.pathExtension == "app" }

    func setup() {
        guard available else { return }
        UNUserNotificationCenter.current().delegate = self
    }

    func requestAuthorization() async -> Bool {
        guard available else { return false }
        return (try? await UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound])) ?? false
    }

    func notifyNoteReady(noteURL: URL, enabled: Bool) {
        guard enabled, available else { return }
        let content = UNMutableNotificationContent()
        content.title = "Meeting note ready"
        content.body = noteURL.deletingPathExtension().lastPathComponent
        content.userInfo = ["path": noteURL.path]
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        let path = response.notification.request.content.userInfo["path"] as? String
        Task { @MainActor in
            if let path {
                Self.openNote(at: URL(fileURLWithPath: path))
            }
        }
        completionHandler()
    }

    /// Opens the note in Obsidian via its URI scheme (obsidian://open?path=…),
    /// falling back to the default .md handler if Obsidian isn't installed.
    static func openNote(at url: URL) {
        var components = URLComponents()
        components.scheme = "obsidian"
        components.host = "open"
        components.queryItems = [URLQueryItem(name: "path", value: url.path)]
        if let obsidianURL = components.url, NSWorkspace.shared.open(obsidianURL) {
            return
        }
        NSWorkspace.shared.open(url)
    }
}
