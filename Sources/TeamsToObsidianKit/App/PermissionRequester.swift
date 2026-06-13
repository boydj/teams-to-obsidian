import AVFoundation
import ApplicationServices
import EventKit
import Foundation

@MainActor
enum PermissionRequester {
    /// Triggers the TCC prompts proactively so they appear at install time,
    /// not mid-meeting. Microphone and System Audio Recording are required;
    /// Calendar, Accessibility, and Notifications enrich notes and are optional.
    /// Returns a short human-readable report.
    static func requestAll() async -> String {
        // On a bare binary there's no Info.plist, so requesting the microphone
        // doesn't just fail — macOS terminates the process for accessing a
        // privacy-sensitive API without a usage description. Bail with guidance
        // rather than crash.
        guard Bundle.main.bundleURL.pathExtension == "app" else {
            return "TeamsToObsidian is running as a bare binary, so macOS will not grant it "
                + "permissions (and may kill it if it asks). Run `make install` and open "
                + "/Applications/TeamsToObsidian.app, then use Request Permissions from there."
        }

        var lines: [String] = []

        let micGranted = await AVCaptureDevice.requestAccess(for: .audio)
        lines.append(micGranted
            ? "Microphone: granted ✓"
            : "Microphone: denied — enable it in System Settings → Privacy & Security → Microphone.")

        // A 2-second throwaway global tap forces the "System Audio Recording
        // Only" prompt without needing Teams to be running.
        do {
            let tmp = FileManager.default.temporaryDirectory
                .appendingPathComponent("tto-permission-probe-\(UUID().uuidString).wav")
            defer { try? FileManager.default.removeItem(at: tmp) }
            let writer = try WAVWriter(url: tmp)
            let tap = ProcessTapRecorder(mode: .globalExcludingNone, writer: writer)
            try tap.start()
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            tap.stop()
            writer.finalize()
            lines.append("System audio recording: working ✓")
        } catch {
            lines.append("System audio recording: not working — grant it in System Settings → "
                + "Privacy & Security → Screen & System Audio Recording (System Audio Recording Only). "
                + "(\(describeError(error)))")
        }

        // Optional: calendar context (meeting titles, attendees).
        let calendarGranted = (try? await EKEventStore().requestFullAccessToEvents()) ?? false
        lines.append(calendarGranted
            ? "Calendar: granted ✓ (notes get real meeting titles and attendees)"
            : "Calendar: not granted — notes won't include calendar titles/attendees. "
                + "(System Settings → Privacy & Security → Calendars)")

        // Optional: Teams window title fallback.
        let axOptions = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        let axGranted = AXIsProcessTrustedWithOptions(axOptions)
        lines.append(axGranted
            ? "Accessibility: granted ✓ (Teams window title fallback)"
            : "Accessibility: not granted — the Teams window-title fallback is off. "
                + "(System Settings → Privacy & Security → Accessibility)")

        // Optional: "note ready" notifications.
        let notificationsGranted = await NoteNotifier.shared.requestAuthorization()
        lines.append(notificationsGranted
            ? "Notifications: granted ✓"
            : "Notifications: not enabled — you won't be told when notes are ready.")

        return lines.joined(separator: "\n")
    }
}
