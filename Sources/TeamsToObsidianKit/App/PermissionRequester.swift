import AVFoundation
import Foundation

@MainActor
enum PermissionRequester {
    /// Triggers both TCC prompts proactively (Microphone + System Audio
    /// Recording Only) so they appear at install time, not mid-meeting.
    /// Returns a short human-readable report.
    static func requestAll() async -> String {
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
        return lines.joined(separator: "\n")
    }
}
