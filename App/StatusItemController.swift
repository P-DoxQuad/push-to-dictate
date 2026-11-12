import Cocoa

final class StatusItemController: NSObject {
    private let statusItem: NSStatusItem
    private var toggleMenuItem: NSMenuItem!
    private var toggleModeItem: NSMenuItem!
    private var pushToTalkModeItem: NSMenuItem!
    private var isRecording = false

    private let hotkeyMonitor = HotkeyMonitor()
    private let audioRecorder = AudioRecorder()
    private var lastLevelLog: Date = .distantPast

    override init() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        configureButton()
        statusItem.menu = buildMenu()
        configureHotkey()
        configureAudio()
        promptForAccessibilityIfNeeded()
    }

    private func configureButton() {
        guard let button = statusItem.button else { return }
        button.title = "\u{25CB}"
        button.toolTip = "push-to-dictate"
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()

        toggleMenuItem = NSMenuItem(title: "Start Dictation",
                                    action: #selector(toggleDictation),
                                    keyEquivalent: "")
        toggleMenuItem.target = self
        menu.addItem(toggleMenuItem)

        menu.addItem(NSMenuItem.separator())

        let modeItem = NSMenuItem(title: "Mode", action: nil, keyEquivalent: "")
        let modeSubmenu = NSMenu()
        toggleModeItem = NSMenuItem(title: "Toggle",
                                    action: #selector(selectToggleMode),
                                    keyEquivalent: "")
        toggleModeItem.target = self
        pushToTalkModeItem = NSMenuItem(title: "Push-to-talk",
                                        action: #selector(selectPushToTalkMode),
                                        keyEquivalent: "")
        pushToTalkModeItem.target = self
        modeSubmenu.addItem(toggleModeItem)
        modeSubmenu.addItem(pushToTalkModeItem)
        modeItem.submenu = modeSubmenu
        menu.addItem(modeItem)
        syncModeMenuState()

        menu.addItem(NSMenuItem.separator())

        let prefs = NSMenuItem(title: "Preferences…",
                               action: #selector(openPreferences),
                               keyEquivalent: ",")
        prefs.target = self
        menu.addItem(prefs)

        menu.addItem(NSMenuItem.separator())

        let quit = NSMenuItem(title: "Quit",
                              action: #selector(NSApplication.terminate(_:)),
                              keyEquivalent: "q")
        menu.addItem(quit)

        return menu
    }

    private func configureHotkey() {
        applyHotkeySettings()
        hotkeyMonitor.onActivate = { [weak self] in self?.handleHotkeyActivate() }
        hotkeyMonitor.onDeactivate = { [weak self] in self?.handleHotkeyDeactivate() }
        hotkeyMonitor.start()
    }

    private func applyHotkeySettings() {
        let prefs = Preferences.shared
        hotkeyMonitor.keyCode = prefs.hotkeyKeyCode
        hotkeyMonitor.modifierFlags = prefs.hotkeyModifierFlags
        hotkeyMonitor.mode = (prefs.hotkeyMode == .pushToTalk) ? .pushToTalk : .toggle
    }

    private func handleHotkeyActivate() {
        if hotkeyMonitor.mode == .pushToTalk {
            setRecording(true)
        } else {
            setRecording(!isRecording)
        }
    }

    private func handleHotkeyDeactivate() {
        if hotkeyMonitor.mode == .pushToTalk {
            setRecording(false)
        }
    }

    private func setRecording(_ recording: Bool) {
        if recording == isRecording { return }

        if recording {
            do {
                try audioRecorder.start()
            } catch {
                NSLog("push-to-dictate: failed to start audio capture: \(error)")
                return
            }
        } else {
            let samples = audioRecorder.stop()
            transcribe(samples: samples)
        }

        isRecording = recording
        statusItem.button?.title = isRecording ? "\u{25CF}" : "\u{25CB}"
        toggleMenuItem.title = isRecording ? "Stop Dictation" : "Start Dictation"
    }

    private func transcribe(samples: [Float]) {
        guard !samples.isEmpty else { return }
        let transcriber = makeTranscriber()
        let backendLabel = Preferences.shared.backend.rawValue
        let startedAt = Date()
        NSLog("push-to-dictate: transcribing %d samples via %@",
              samples.count, backendLabel)
        transcriber.transcribe(audio: samples) { result in
            let elapsed = Date().timeIntervalSince(startedAt)
            DispatchQueue.main.async {
                switch result {
                case .success(let text):
                    NSLog("push-to-dictate: transcript (%.2fs): %@", elapsed, text)
                case .failure(let error):
                    NSLog("push-to-dictate: transcription failed (%.2fs): %@",
                          elapsed, error.localizedDescription)
                }
            }
        }
    }

    private func makeTranscriber() -> Transcriber {
        let prefs = Preferences.shared
        switch prefs.backend {
        case .openAI:
            return OpenAITranscriber(apiKey: prefs.openAIAPIKey)
        case .whisperCpp:
            return WhisperCppTranscriber(
                executableURL: URL(fileURLWithPath: prefs.whisperCliPath),
                modelURL: URL(fileURLWithPath: prefs.whisperModelPath)
            )
        }
    }

    private func configureAudio() {
        audioRecorder.onLevel = { [weak self] level in
            guard let self = self else { return }
            let now = Date()
            if now.timeIntervalSince(self.lastLevelLog) >= 0.25 {
                self.lastLevelLog = now
                NSLog("push-to-dictate: mic RMS %.4f", level)
            }
        }
        audioRecorder.onCaptureSaved = { url in
            NSLog("push-to-dictate: saved recording to %@", url.path)
        }
    }

    private func promptForAccessibilityIfNeeded() {
        if HotkeyMonitor.hasAccessibilityPermission() { return }

        let alert = NSAlert()
        alert.messageText = "Accessibility permission required"
        alert.informativeText =
            "push-to-dictate needs Accessibility access to listen for its global hotkey " +
            "and to insert transcribed text into other apps.\n\n" +
            "Open System Preferences → Security & Privacy → Privacy → Accessibility and " +
            "add push-to-dictate, then relaunch the app."
        alert.addButton(withTitle: "Open Accessibility Preferences")
        alert.addButton(withTitle: "Later")
        if alert.runModal() == .alertFirstButtonReturn {
            let url = URL(string:
                "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func toggleDictation() {
        setRecording(!isRecording)
    }

    @objc private func selectToggleMode() {
        Preferences.shared.hotkeyMode = .toggle
        applyHotkeySettings()
        syncModeMenuState()
    }

    @objc private func selectPushToTalkMode() {
        Preferences.shared.hotkeyMode = .pushToTalk
        applyHotkeySettings()
        syncModeMenuState()
    }

    @objc private func openPreferences() {}

    private func syncModeMenuState() {
        let current = Preferences.shared.hotkeyMode
        toggleModeItem.state = (current == .toggle) ? .on : .off
        pushToTalkModeItem.state = (current == .pushToTalk) ? .on : .off
    }
}
