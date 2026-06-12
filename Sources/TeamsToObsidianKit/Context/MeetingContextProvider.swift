import AppKit
import ApplicationServices
import EventKit
import Foundation

/// Context about the meeting gathered at recording start: the calendar event
/// (title, attendees, organizer) and/or the Teams meeting window title.
struct MeetingContext: Codable, Equatable {
    var title: String?
    var attendees: [String] = []
    var organizer: String?

    var isEmpty: Bool { title == nil && attendees.isEmpty && organizer == nil }
}

/// Sources, in priority order:
/// 1. EventKit — the local calendar database. Outlook / Microsoft 365
///    calendars are visible here when the account is added in System Settings
///    → Internet Accounts with Calendars enabled: macOS syncs them locally and
///    we read that copy. The app never talks to Microsoft's servers.
/// 2. The Teams meeting window title via Accessibility — works regardless of
///    calendar setup, since Teams shows the meeting subject in its title bar.
@MainActor
enum MeetingContextProvider {
    private static let eventStore = EKEventStore()

    static func capture(config: Config.Context, at date: Date = Date()) async -> MeetingContext {
        var context = MeetingContext()
        if config.useCalendar, let event = await currentEvent(config: config, at: date) {
            context.title = nonEmpty(event.title)
            context.attendees = (event.attendees ?? [])
                .filter { $0.participantType == .person }
                .compactMap { $0.name }
            context.organizer = event.organizer?.name
        }
        if context.title == nil, config.useWindowTitle {
            context.title = teamsWindowTitle()
        }
        return context
    }

    // MARK: - Calendar (EventKit)

    private static func currentEvent(config: Config.Context, at date: Date) async -> EKEvent? {
        if EKEventStore.authorizationStatus(for: .event) == .notDetermined {
            _ = try? await eventStore.requestFullAccessToEvents()
        }
        guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else {
            Log.info("Calendar access not granted — skipping calendar context.")
            return nil
        }
        var calendars: [EKCalendar]?
        if !config.calendarNames.isEmpty {
            let wanted = Set(config.calendarNames)
            calendars = eventStore.calendars(for: .event).filter { wanted.contains($0.title) }
        }
        // Meetings are often joined late — look back a few hours, then keep
        // only events actually overlapping "now".
        let predicate = eventStore.predicateForEvents(
            withStart: date.addingTimeInterval(-4 * 3600),
            end: date.addingTimeInterval(1800),
            calendars: calendars)
        let candidates = eventStore.events(matching: predicate).filter { event in
            !event.isAllDay
                && event.startDate <= date.addingTimeInterval(120)
                && event.endDate > date.addingTimeInterval(-60)
        }
        // Prefer events with human attendees, then the start time closest to now.
        return candidates.min { a, b in
            let aHasPeople = !(a.attendees ?? []).isEmpty
            let bHasPeople = !(b.attendees ?? []).isEmpty
            if aHasPeople != bHasPeople { return aHasPeople }
            return abs(a.startDate.timeIntervalSince(date)) < abs(b.startDate.timeIntervalSince(date))
        }
    }

    // MARK: - Teams window title (Accessibility)

    static func teamsWindowTitle(bundleIDPrefix: String = "com.microsoft.teams2") -> String? {
        guard AXIsProcessTrusted() else { return nil }
        let teamsApps = NSWorkspace.shared.runningApplications.filter {
            $0.bundleIdentifier?.hasPrefix(bundleIDPrefix) == true
        }
        for app in teamsApps {
            let element = AXUIElementCreateApplication(app.processIdentifier)
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, kAXWindowsAttribute as CFString, &value) == .success,
                  let windows = value as? [AXUIElement] else { continue }
            for window in windows {
                var titleValue: CFTypeRef?
                guard AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &titleValue) == .success,
                      let raw = titleValue as? String,
                      let cleaned = cleanedTeamsWindowTitle(raw) else { continue }
                return cleaned
            }
        }
        return nil
    }

    /// Strips Teams window chrome and rejects generic app-section titles.
    /// Pure string logic (nonisolated) so it is unit-testable.
    nonisolated static func cleanedTeamsWindowTitle(_ raw: String) -> String? {
        var t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let range = t.range(of: "| Microsoft Teams") {
            t = String(t[..<range.lowerBound])
        }
        // Unread badges: "(3) Chat"
        if t.hasPrefix("("), let close = t.firstIndex(of: ")") {
            t = String(t[t.index(after: close)...])
        }
        t = t.trimmingCharacters(in: .whitespacesAndNewlines)
        let generic: Set<String> = ["", "Microsoft Teams", "Activity", "Chat", "Teams",
                                    "Calendar", "Calls", "Files", "Apps", "Notifications", "OneDrive"]
        return generic.contains(t) ? nil : t
    }

    private nonisolated static func nonEmpty(_ s: String?) -> String? {
        guard let t = s?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return nil }
        return t
    }
}
