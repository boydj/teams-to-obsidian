import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let config: Config
    private let configProblem: String?
    private var controller: AppController?
    private var statusController: StatusItemController?

    init(config: Config, configProblem: String?) {
        self.config = config
        self.configProblem = configProblem
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NoteNotifier.shared.setup()
        let controller = AppController(config: config, configProblem: configProblem)
        self.controller = controller
        self.statusController = StatusItemController(controller: controller)
        controller.start()
        Log.info("TeamsToObsidian started (pid \(ProcessInfo.processInfo.processIdentifier)).")
    }

    func applicationWillTerminate(_ notification: Notification) {
        controller?.prepareForTermination()
    }
}

/// NSApplication.delegate does not retain its delegate; the run command parks
/// it here for the lifetime of the process.
@MainActor
enum AppHolder {
    static var delegate: AppDelegate?
}
