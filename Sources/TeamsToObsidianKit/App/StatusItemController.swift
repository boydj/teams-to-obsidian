import AppKit

@MainActor
final class StatusItemController: NSObject {
    private let statusItem: NSStatusItem
    private unowned let controller: AppController

    init(controller: AppController) {
        self.controller = controller
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()
        controller.store.onChange = { [weak self] in self?.refresh() }
        refresh()
    }

    func refresh() {
        guard let button = statusItem.button else { return }
        let (symbol, description) = iconInfo()
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: description)
        image?.isTemplate = true
        button.image = image
        button.toolTip = "TeamsToObsidian — \(description)"
        statusItem.menu = buildMenu()
    }

    private func iconInfo() -> (symbol: String, description: String) {
        if controller.store.paused {
            return ("pause.circle", "Paused")
        }
        switch controller.store.activity {
        case .idle: return ("circle.dashed", "Idle — waiting for a Teams meeting")
        case .recording(let since):
            let minutes = Int(Date().timeIntervalSince(since) / 60)
            return ("record.circle.fill", "Recording (\(minutes) min)")
        case .transcribing: return ("waveform.circle", "Transcribing…")
        case .summarizing: return ("sparkles", "Summarizing…")
        case .recovering(let n): return ("arrow.clockwise.circle", "Recovering \(n) recording(s)…")
        case .error: return ("exclamationmark.circle", "Error")
        }
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: iconInfo().description, action: nil, keyEquivalent: ""))
        if case .error(let message) = controller.store.activity {
            menu.addItem(NSMenuItem(title: String(message.prefix(120)), action: nil, keyEquivalent: ""))
        }
        menu.addItem(.separator())

        if case .recording = controller.store.activity {
            menu.addItem(makeItem("Stop & Process Now", #selector(stopNow)))
        }
        if controller.lastNoteURL != nil {
            menu.addItem(makeItem("Open Last Note", #selector(openLastNote)))
        }
        menu.addItem(makeItem("Reprocess Last Recording", #selector(reprocessLast)))
        if controller.orphanCount > 0 {
            menu.addItem(makeItem("Recover \(controller.orphanCount) Unfinished Recording(s)",
                                  #selector(recoverOrphans)))
        }
        menu.addItem(.separator())
        menu.addItem(makeItem(controller.store.paused ? "Resume Meeting Detection" : "Pause Meeting Detection",
                              #selector(togglePause)))
        menu.addItem(makeItem("Request Permissions…", #selector(requestPermissions)))
        if LoginItem.isAvailable {
            let login = makeItem("Start at Login", #selector(toggleLogin))
            login.state = LoginItem.isEnabled ? .on : .off
            menu.addItem(login)
        }
        menu.addItem(.separator())
        menu.addItem(makeItem("Open Config File", #selector(openConfig)))
        menu.addItem(makeItem("Open Notes Folder", #selector(openVault)))
        menu.addItem(makeItem("Open Log", #selector(openLog)))
        menu.addItem(.separator())
        menu.addItem(makeItem("Quit TeamsToObsidian", #selector(quit)))
        return menu
    }

    private func makeItem(_ title: String, _ action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    // MARK: - Actions

    @objc private func stopNow() { controller.stopAndProcessNow() }

    @objc private func openLastNote() {
        if let url = controller.lastNoteURL { NoteNotifier.openNote(at: url) }
    }

    @objc private func reprocessLast() { controller.reprocessLastRecording() }

    @objc private func recoverOrphans() { controller.recoverOrphans() }

    @objc private func togglePause() { controller.togglePause() }

    @objc private func requestPermissions() {
        Task { @MainActor in
            Log.info("Request Permissions invoked.")
            // Accessory apps never take focus, which can keep the system TCC
            // prompt (and our result alert) from coming forward. Become a
            // regular foreground app for the duration, then restore.
            let previousPolicy = NSApp.activationPolicy()
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
            defer { NSApp.setActivationPolicy(previousPolicy) }

            let report = await PermissionRequester.requestAll()
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.messageText = "Permissions"
            alert.informativeText = report + "\n\nmacOS only shows each prompt once. "
                + "If something is missing, enable TeamsToObsidian in System Settings, "
                + "then quit and reopen the app."
            alert.addButton(withTitle: "Open Screen & System Audio Recording")
            alert.addButton(withTitle: "Open Microphone")
            alert.addButton(withTitle: "Close")
            switch alert.runModal() {
            case .alertFirstButtonReturn: Self.openPrivacyPane("Privacy_ScreenCapture")
            case .alertSecondButtonReturn: Self.openPrivacyPane("Privacy_Microphone")
            default: break
            }
        }
    }

    private static func openPrivacyPane(_ anchor: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func toggleLogin() {
        do {
            try LoginItem.setEnabled(!LoginItem.isEnabled)
        } catch {
            Log.error("Login item change failed: \(describeError(error))")
        }
        refresh()
    }

    @objc private func openConfig() {
        if !FileManager.default.fileExists(atPath: Paths.configFile.path) {
            _ = try? ConfigLoader.writeDefault(force: false)
        }
        NSWorkspace.shared.open(Paths.configFile)
    }

    @objc private func openVault() {
        let vault = Paths.expand(controller.config.vault.path)
        let folder = vault.appendingPathComponent(controller.config.vault.notesFolder)
        NSWorkspace.shared.open(FileManager.default.fileExists(atPath: folder.path) ? folder : vault)
    }

    @objc private func openLog() {
        NSWorkspace.shared.open(Paths.logFile)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
