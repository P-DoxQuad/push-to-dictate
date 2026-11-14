import Cocoa

final class StatusItemController: NSObject, NSUserNotificationCenterDelegate {

    // Peak RMS below this across the whole recording = treat as silence,
    // skip transcription. Normal speech sits around 0.05–0.3; room noise
    // and dead-air clips are well under 0.005.
    private static let silentPeakThreshold: Float = 0.01

    private let statusItem: NSStatusItem
    private var toggleMenuItem: NSMenuItem!
    private var toggleModeItem: NSMenuItem!
    private var pushToTalkModeItem: NSMenuItem!
    private var isRecording = false

    private let hotkeyMonitor = HotkeyMonitor()
    private let audioRecorder = AudioRecorder()
    private let textInjector = TextInjector()
    private var lastLevelLog: Date = .distantPast

    private enum IconState { case idle, recording, processing, error }
    private var iconState: IconState = .idle
    private var dotVisible = false
    private var dotTimer: Timer?
    private var errorClearTimer: Timer?

    override init() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()
        configureButton()
        statusItem.menu = buildMenu()
        configureHotkey()
        configureAudio()
        observeAppearanceChanges()
        promptForAccessibilityIfNeeded()
    }

    private func configureButton() {
        guard let button = statusItem.button else { return }
        button.image = currentMenuBarImage()
        button.imageScaling = .scaleProportionallyDown
        button.toolTip = "push-to-dictate"
    }

    func refreshMenuBarIcon() {
        statusItem.button?.image = currentMenuBarImage()
    }

    private func currentMenuBarImage() -> NSImage? {
        let base: NSImage?
        if Preferences.shared.useColoredMenuBarIcon {
            base = NSImage(named: NSImage.Name("Push_to_Dictate_Color_Menu_Bar_44"))
        } else {
            let isDark = isDarkMenuBar()
            let name = isDark ? "Push_to_Dictate_White_Menu_Bar_44"
                              : "Push_to_Dictate_Black_Menu_Bar_44"
            base = NSImage(named: NSImage.Name(name))
        }
        guard let image = base else { return nil }
        let sized = image.copy() as? NSImage ?? image
        sized.size = NSSize(width: 24, height: 24)

        switch iconState {
        case .error:
            return tintedRed(sized)
        case .recording:
            return dotVisible ? withDot(sized, color: .systemGreen) : sized
        case .processing:
            let skyBlue = NSColor(srgbRed: 0.1, green: 0.72, blue: 1.0, alpha: 1.0)
            return dotVisible ? withDot(sized, color: skyBlue) : sized
        case .idle:
            return sized
        }
    }

    private func withDot(_ image: NSImage, color: NSColor) -> NSImage {
        let size = image.size
        let result = NSImage(size: size)
        result.lockFocus()
        image.draw(at: .zero, from: NSRect(origin: .zero, size: size),
                   operation: .sourceOver, fraction: 1.0)
        color.setFill()
        let dot = NSBezierPath(ovalIn: NSRect(x: size.width - 7, y: 0,
                                              width: 6, height: 6))
        dot.fill()
        result.unlockFocus()
        return result
    }

    private func setIconState(_ state: IconState) {
        dotTimer?.invalidate()
        dotTimer = nil
        errorClearTimer?.invalidate()
        errorClearTimer = nil

        iconState = state
        dotVisible = true

        switch state {
        case .recording, .processing:
            dotTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) {
                [weak self] _ in
                self?.dotVisible.toggle()
                self?.refreshMenuBarIcon()
            }
        case .error:
            errorClearTimer = Timer.scheduledTimer(withTimeInterval: 5.0,
                                                   repeats: false) {
                [weak self] _ in
                self?.setIconState(.idle)
            }
        case .idle:
            break
        }
        refreshMenuBarIcon()
    }

    private func isDarkMenuBar() -> Bool {
        if #available(macOS 10.14, *) {
            let appearance = NSApp.effectiveAppearance
            return appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        }
        // macOS 10.13: "Use dark menu bar and Dock" in System Preferences → General
        // writes AppleInterfaceStyle=Dark into the global domain. Absent = light.
        let style = UserDefaults.standard.string(forKey: "AppleInterfaceStyle")
        return style == "Dark"
    }

    private func tintedRed(_ image: NSImage) -> NSImage {
        let size = image.size
        let result = NSImage(size: size)
        result.lockFocus()
        image.draw(at: .zero, from: NSRect(origin: .zero, size: size),
                   operation: .sourceOver, fraction: 1.0)
        NSColor.systemRed.set()
        NSRect(origin: .zero, size: size).fill(using: .sourceIn)
        result.unlockFocus()
        return result
    }

    private func observeAppearanceChanges() {
        if #available(macOS 10.14, *) {
            NSApp.addObserver(self, forKeyPath: "effectiveAppearance",
                              options: [.new], context: nil)
        }
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(interfaceThemeChanged),
            name: NSNotification.Name("AppleInterfaceThemeChangedNotification"),
            object: nil
        )
    }

    @objc private func interfaceThemeChanged() {
        DispatchQueue.main.async { [weak self] in
            self?.refreshMenuBarIcon()
        }
    }

    // User clicked the notification banner — clear the error tint early.
    func userNotificationCenter(_ center: NSUserNotificationCenter,
                                didActivate notification: NSUserNotification) {
        if iconState == .error {
            setIconState(.idle)
        }
    }

    // Force banners to appear even when our app is frontmost.
    func userNotificationCenter(_ center: NSUserNotificationCenter,
                                shouldPresent notification: NSUserNotification) -> Bool {
        return true
    }

    override func observeValue(forKeyPath keyPath: String?,
                               of object: Any?,
                               change: [NSKeyValueChangeKey: Any]?,
                               context: UnsafeMutableRawPointer?) {
        if keyPath == "effectiveAppearance" {
            refreshMenuBarIcon()
        }
    }

    deinit {
        if #available(macOS 10.14, *) {
            NSApp.removeObserver(self, forKeyPath: "effectiveAppearance")
        }
        DistributedNotificationCenter.default().removeObserver(self)
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
            if let issue = preflightBackend() {
                showError(title: "Cannot start dictation", detail: issue)
                return
            }
            do {
                try audioRecorder.start()
            } catch {
                showError(title: "Microphone error",
                          detail: error.localizedDescription)
                return
            }
            playSound(Preferences.shared.startSound)
        } else {
            let samples = audioRecorder.stop()
            let peak = audioRecorder.peakRMS
            playSound(Preferences.shared.stopSound)
            if peak < StatusItemController.silentPeakThreshold {
                Logger.info(String(format: "skipping transcription: silent recording (peak RMS %.4f)", peak))
                setIconState(.idle)
            } else {
                transcribe(samples: samples)
            }
        }

        isRecording = recording
        if recording {
            setIconState(.recording)
        }
        // When stopping, transcribe() takes over icon state (.processing then
        // .idle on success or .error on failure). Don't overwrite it here.
        toggleMenuItem.title = isRecording ? "Stop Dictation" : "Start Dictation"
    }

    private func preflightBackend() -> String? {
        let prefs = Preferences.shared
        switch prefs.backend {
        case .whisperCpp:
            let binPath = prefs.whisperCliPath
            if !FileManager.default.isExecutableFile(atPath: binPath) {
                return "whisper-cli not found or not executable at \(binPath)"
            }
            let modelPath = prefs.whisperModelPath
            if !FileManager.default.fileExists(atPath: modelPath) {
                return "Model file not found at \(modelPath)"
            }
        case .openAI:
            if prefs.openAIAPIKey.isEmpty {
                return "OpenAI API key is not set. Open Preferences and enter one."
            }
        }
        return nil
    }

    private func showError(title: String, detail: String) {
        Logger.error(title, detail: detail)
        setIconState(.error)
        let notification = NSUserNotification()
        notification.title = title
        notification.informativeText = detail
        NSUserNotificationCenter.default.delegate = self
        NSUserNotificationCenter.default.deliver(notification)
    }

    private func playSound(_ name: String) {
        guard name != Preferences.noSoundName,
              let sound = NSSound(named: NSSound.Name(name)) else { return }
        sound.play()
    }

    private func transcribe(samples: [Float]) {
        guard !samples.isEmpty else {
            setIconState(.idle)
            return
        }
        let transcriber = makeTranscriber()
        let backendLabel = Preferences.shared.backend.rawValue
        let startedAt = Date()
        Logger.info("transcribing \(samples.count) samples via \(backendLabel)")
        setIconState(.processing)
        transcriber.transcribe(audio: samples) { [weak self] result in
            let elapsed = Date().timeIntervalSince(startedAt)
            DispatchQueue.main.async {
                switch result {
                case .success(let text):
                    Logger.info(String(format: "transcript (%.2fs): %@", elapsed, text))
                    self?.setIconState(.idle)
                    self?.textInjector.insert(text)
                case .failure(let error):
                    let backend = Preferences.shared.backend
                    let title = (backend == .openAI)
                        ? "Transcription failed (OpenAI)"
                        : "Transcription failed (local whisper.cpp)"
                    self?.showError(
                        title: String(format: "%@ · %.2fs", title, elapsed),
                        detail: error.localizedDescription)
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
                Logger.info(String(format: "mic RMS %.4f", level))
            }
        }
        audioRecorder.onCaptureSaved = { url in
            Logger.info("saved recording to \(url.path)")
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

    @objc private func openPreferences() {
        let controller = PreferencesWindowController.shared
        controller.onHotkeyChanged = { [weak self] in self?.applyHotkeySettings() }
        controller.onColoredIconChanged = { [weak self] in self?.refreshMenuBarIcon() }
        controller.showPreferences()
    }

    private func syncModeMenuState() {
        let current = Preferences.shared.hotkeyMode
        toggleModeItem.state = (current == .toggle) ? .on : .off
        pushToTalkModeItem.state = (current == .pushToTalk) ? .on : .off
    }
}
