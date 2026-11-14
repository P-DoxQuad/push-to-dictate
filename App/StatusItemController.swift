import Cocoa
import UserNotifications

final class StatusItemController: NSObject,
                                  NSUserNotificationCenterDelegate {

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

    private var welcomePopover: NSPopover?
    private var welcomeDismissTimer: Timer?
    private var hoverShowTimer: Timer?
    private var hoverHideTimer: Timer?
    private var hoverTracker: HoverTracker?

    override init() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()
        configureButton()
        statusItem.menu = buildMenu()
        configureHotkey()
        configureAudio()
        observeAppearanceChanges()
        promptForAccessibilityIfNeeded()
        installHoverTracking()
        maybeShowWelcomePopover()
        if #available(macOS 10.14, *) {
            requestModernNotificationAuthorization()
        }
    }

    private func configureButton() {
        guard let button = statusItem.button else { return }
        button.image = currentMenuBarImage()
        button.imageScaling = .scaleProportionallyDown
        button.toolTip = "Push to Dictate"
    }

    func refreshMenuBarIcon() {
        statusItem.button?.image = currentMenuBarImage()
    }

    private func currentMenuBarImage() -> NSImage? {
        let base: NSImage?
        if Preferences.shared.useColoredMenuBarIcon {
            base = NSImage(named: "Push_to_Dictate_Keycap_Color_44")
        } else {
            let isDark = isDarkMenuBar()
            let name = isDark ? "Push_to_Dictate_Keycap_White_44"
                              : "Push_to_Dictate_Keycap_Black_44"
            base = NSImage(named: name)
        }
        guard let image = base else { return nil }
        let sized = image.copy() as? NSImage ?? image
        sized.size = NSSize(width: 24, height: 24)

        switch iconState {
        case .error:
            return tintedRed(sized)
        case .recording:
            return dotVisible ? withDot(sized, color: .systemRed) : sized
        case .processing:
            let darkBlue = NSColor(srgbRed: 0.05, green: 0.25, blue: 0.80, alpha: 1.0)
            return dotVisible ? withDot(sized, color: darkBlue) : sized
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
        let dotSize: CGFloat = 10
        color.setFill()
        let dot = NSBezierPath(ovalIn: NSRect(x: size.width - dotSize - 1, y: 0,
                                              width: dotSize, height: dotSize))
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
            dotTimer = Timer.scheduledTimer(timeInterval: 0.5,
                                            target: self,
                                            selector: #selector(dotTick),
                                            userInfo: nil,
                                            repeats: true)
        case .error:
            errorClearTimer = Timer.scheduledTimer(timeInterval: 5.0,
                                                   target: self,
                                                   selector: #selector(errorClearTick),
                                                   userInfo: nil,
                                                   repeats: false)
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

        let about = NSMenuItem(title: "About Push to Dictate",
                               action: #selector(openAbout),
                               keyEquivalent: "")
        about.target = self
        menu.addItem(about)

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
        if #available(macOS 10.14, *) {
            postModernNotification(title: title, body: detail)
        } else {
            postLegacyNotification(title: title, body: detail)
        }
    }

    private func postLegacyNotification(title: String, body: String) {
        let notification = NSUserNotification()
        notification.title = title
        notification.informativeText = body
        NSUserNotificationCenter.default.delegate = self
        NSUserNotificationCenter.default.deliver(notification)
    }

    @available(macOS 10.14, *)
    private func postModernNotification(title: String, body: String) {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        let request = UNNotificationRequest(identifier: UUID().uuidString,
                                            content: content,
                                            trigger: nil)
        center.add(request, withCompletionHandler: nil)
    }

    @available(macOS 10.14, *)
    private func requestModernNotificationAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(
            options: [.alert, .sound]
        ) { _, _ in }
    }

    private func playSound(_ name: String) {
        guard name != Preferences.noSoundName,
              let sound = NSSound(named: name) else { return }
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
            "Push to Dictate needs Accessibility access to listen for its global hotkey " +
            "and to insert transcribed text into other apps.\n\n" +
            "Open System Preferences → Security & Privacy → Privacy → Accessibility and " +
            "add Push to Dictate, then relaunch the app."
        alert.addButton(withTitle: "Open Accessibility Preferences")
        alert.addButton(withTitle: "Later")
        if alert.runModal() == .alertFirstButtonReturn {
            let url = URL(string:
                "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
            NSWorkspace.shared.open(url)
        }
    }

    private func maybeShowWelcomePopover() {
        if Preferences.shared.didShowWelcomeTooltip { return }
        // Delay so any launch-time alerts (Accessibility, Move to Applications)
        // have a chance to come and go before the popover tries to anchor.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            guard let self = self else { return }
            self.showInfoPopover(autoDismissAfter: 12)
            Preferences.shared.didShowWelcomeTooltip = true
        }
    }

    private func showInfoPopover(autoDismissAfter seconds: TimeInterval?) {
        guard let button = statusItem.button, button.window != nil else { return }
        if welcomePopover?.isShown == true { return }

        let hotkey = PreferencesWindowController.describe(
            keyCode: Preferences.shared.hotkeyKeyCode,
            flags: Preferences.shared.hotkeyModifierFlags
        )

        let title = NSTextField(frame: .zero)
        title.isEditable = false; title.isSelectable = false
        title.isBordered = false; title.drawsBackground = false
        title.stringValue = "Push to Dictate"
        title.font = NSFont.boldSystemFont(ofSize: NSFont.systemFontSize)

        let body = NSTextField(frame: .zero)
        body.isEditable = false; body.isSelectable = false
        body.isBordered = false; body.drawsBackground = false
        body.stringValue = "Press \(hotkey) to start dictation. Click the icon for more options."
        body.lineBreakMode = .byWordWrapping
        body.cell?.wraps = true
        body.cell?.isScrollable = false
        body.preferredMaxLayoutWidth = 268
        body.font = NSFont.systemFont(ofSize: NSFont.systemFontSize)

        let stack = NSStackView(views: [title, body])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 14, bottom: 12, right: 14)

        let container = NSViewController()
        container.view = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 80))
        container.view.addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: container.view.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: container.view.trailingAnchor),
            stack.topAnchor.constraint(equalTo: container.view.topAnchor),
            stack.bottomAnchor.constraint(equalTo: container.view.bottomAnchor),
            body.widthAnchor.constraint(equalToConstant: 272)
        ])

        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = container
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        welcomePopover = popover

        welcomeDismissTimer?.invalidate()
        if let seconds = seconds {
            welcomeDismissTimer = Timer.scheduledTimer(
                timeInterval: seconds,
                target: self,
                selector: #selector(welcomeDismissTick),
                userInfo: nil,
                repeats: false)
        }
    }

    @objc private func dismissInfoPopover() {
        welcomeDismissTimer?.invalidate()
        welcomeDismissTimer = nil
        welcomePopover?.performClose(nil)
        welcomePopover = nil
    }

    private func installHoverTracking() {
        guard let button = statusItem.button else { return }
        let tracker = HoverTracker(
            onEnter: { [weak self] in self?.scheduleHoverShow() },
            onExit: { [weak self] in self?.scheduleHoverHide() }
        )
        hoverTracker = tracker
        let area = NSTrackingArea(
            rect: button.bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: tracker,
            userInfo: nil
        )
        button.addTrackingArea(area)
    }

    private func scheduleHoverShow() {
        hoverHideTimer?.invalidate()
        hoverHideTimer = nil
        if welcomePopover?.isShown == true { return }
        hoverShowTimer?.invalidate()
        hoverShowTimer = Timer.scheduledTimer(
            timeInterval: 1.5,
            target: self,
            selector: #selector(hoverShowTick),
            userInfo: nil,
            repeats: false)
    }

    private func scheduleHoverHide() {
        hoverShowTimer?.invalidate()
        hoverShowTimer = nil
        hoverHideTimer?.invalidate()
        hoverHideTimer = Timer.scheduledTimer(
            timeInterval: 0.3,
            target: self,
            selector: #selector(hoverHideTick),
            userInfo: nil,
            repeats: false)
    }

    @objc private func dotTick() {
        dotVisible.toggle()
        refreshMenuBarIcon()
    }

    @objc private func errorClearTick() {
        setIconState(.idle)
    }

    @objc private func welcomeDismissTick() {
        dismissInfoPopover()
    }

    @objc private func hoverShowTick() {
        showInfoPopover(autoDismissAfter: nil)
    }

    @objc private func hoverHideTick() {
        dismissInfoPopover()
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

    @objc private func openAbout() {
        AboutWindowController.shared.show()
    }

    private func syncModeMenuState() {
        let current = Preferences.shared.hotkeyMode
        toggleModeItem.state = (current == .toggle) ? .on : .off
        pushToTalkModeItem.state = (current == .pushToTalk) ? .on : .off
    }
}

// MARK: - UNUserNotificationCenterDelegate (macOS 10.14+)

@available(macOS 10.14, *)
extension StatusItemController: UNUserNotificationCenterDelegate {
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler
                                    completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.alert, .sound])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        if iconState == .error {
            setIconState(.idle)
        }
        completionHandler()
    }
}

private final class HoverTracker: NSResponder {
    private let onEnter: () -> Void
    private let onExit: () -> Void

    init(onEnter: @escaping () -> Void, onExit: @escaping () -> Void) {
        self.onEnter = onEnter
        self.onExit = onExit
        super.init()
    }

    required init?(coder: NSCoder) { fatalError() }

    override func mouseEntered(with event: NSEvent) { onEnter() }
    override func mouseExited(with event: NSEvent) { onExit() }
}
