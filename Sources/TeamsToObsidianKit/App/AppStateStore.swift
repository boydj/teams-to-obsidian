import Foundation

@MainActor
final class AppStateStore {
    enum Activity: Equatable {
        case idle
        case recording(Date)
        case transcribing
        case summarizing
        case recovering(Int)
        case error(String)
    }

    private(set) var activity: Activity = .idle
    private(set) var paused = false
    var onChange: (() -> Void)?

    func set(_ activity: Activity) {
        self.activity = activity
        onChange?()
    }

    func setPaused(_ paused: Bool) {
        self.paused = paused
        onChange?()
    }
}
