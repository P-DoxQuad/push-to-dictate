import Cocoa
import UserNotifications

final class StatusItemController: NSObject,
                                  NSUserNotificationCenterDelegate,
                                  NSMenuDelegate {

    // Peak RMS below this across the whole recording = treat as silence,
    // skip transcription. Normal speech sits around 0.05–0.3; room noise
    // and dead-air clips are well under 0.005.
    private static let silentPeakThreshold: Float = 0.01

    private let statusItem: NSStatusItem
    private var toggleMenuItem: NSMenuItem!
    private var toggleModeItem: NSMenuItem!
    private var pushToTalkModeItem: NSMenuItem!
    private var accessibilityRequestItem: NSMenuItem!
    private var modelStatusItem: NSMenuItem!
    private var threadsStatusItem: NSMenuItem!
    private var behaviorStatusItem: NSMenuItem!
    private var updatesMenuItem: NSMenuItem!
    private var pendingUpdateVersion: String?
    private var isRecording = false

    private let hotkeyMonitor = HotkeyMonitor()
    private let audioRecorder = AudioRecorder()
    private let textInjector = TextInjector()
    private var lastLevelLog: Date = .distantPast

    private let continuousQueue = DispatchQueue(
        label: "push-to-dictate.continuous", qos: .userInitiated)
    private var pendingContinuousChunks: Int = 0
    private var drainingAfterContinuous: Bool = false
    private var continuousModeActive: Bool = false
    // Rolling tail of transcribed text within the current continuous session.
    // Passed to each subsequent chunk's whisper-cli via --prompt so the model
    // has language-model context across chunk boundaries. Reset on session
    // start. Capped so the whisper prompt token budget isn't exceeded.
    private var continuousPromptBuffer: String = ""
    // True until the first injected chunk of a continuous session. Used
    // by the leading-separator policy (strip-punctuation mode) to suppress
    // the prefix on the very first chunk, where no preceding gap exists.
    private var isFirstContinuousChunk: Bool = true
    // True iff the most recent injected chunk ended with `?` or `!`. Used
    // by the leading-separator policy to avoid stacking a `. ` prefix after
    // a sentence terminator whisper already emitted.
    private var previousInjectedEndedWithSentencePunct: Bool = false
    // Monotonic session counter. Each continuous session start increments
    // it. Chunks capture the session they were enqueued in so late-arriving
    // results from a prior session can be identified and discarded,
    // preventing them from corrupting the new session's first-chunk state.
    private var currentContinuousSessionId: Int = 0
    // Strip-punctuation mode: pending trailing-period injection. Scheduled
    // after each injected chunk; cancelled when a subsequent chunk arrives
    // or the session restarts. Fires only when the user falls fully silent
    // past the configured threshold.
    private var trailingPeriodWorkItem: DispatchWorkItem?

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
        let menu = buildMenu()
        menu.delegate = self
        statusItem.menu = menu
        refreshStatusRows()
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

        let stateImage: NSImage
        switch iconState {
        case .error:
            stateImage = tintedRed(sized)
        case .recording:
            stateImage = dotVisible ? withDot(sized, color: .systemRed) : sized
        case .processing:
            let darkBlue = NSColor(srgbRed: 0.05, green: 0.25, blue: 0.80, alpha: 1.0)
            stateImage = dotVisible ? withDot(sized, color: darkBlue) : sized
        case .idle:
            stateImage = sized
        }

        if pendingUpdateVersion != nil {
            return withUpdateBadge(stateImage)
        }
        return stateImage
    }

    private func withUpdateBadge(_ image: NSImage) -> NSImage {
        let size = image.size
        let result = NSImage(size: size)
        result.lockFocus()
        image.draw(at: .zero, from: NSRect(origin: .zero, size: size),
                   operation: .sourceOver, fraction: 1.0)

        let badgeSize: CGFloat = 15
        let badgeRect = NSRect(x: 0,
                               y: 0,
                               width: badgeSize, height: badgeSize)
        NSColor.systemOrange.setFill()
        NSBezierPath(ovalIn: badgeRect).fill()

        let numeral: NSString = "1"
        let attrs: [NSAttributedString.Key: Any] = [
            .foregroundColor: NSColor.white,
            .font: NSFont.boldSystemFont(ofSize: 11)
        ]
        let textSize = numeral.size(withAttributes: attrs)
        let textRect = NSRect(
            x: badgeRect.midX - textSize.width / 2,
            y: badgeRect.midY - textSize.height / 2,
            width: textSize.width,
            height: textSize.height
        )
        numeral.draw(in: textRect, withAttributes: attrs)

        result.unlockFocus()
        return result
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

    // User clicked the notification banner. Clear the error tint early.
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

        modelStatusItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        modelStatusItem.isEnabled = false
        menu.addItem(modelStatusItem)

        threadsStatusItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        threadsStatusItem.isEnabled = false
        menu.addItem(threadsStatusItem)

        behaviorStatusItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        behaviorStatusItem.isEnabled = false
        menu.addItem(behaviorStatusItem)

        menu.addItem(NSMenuItem.separator())

        toggleMenuItem = NSMenuItem(title: "Start Dictation",
                                    action: #selector(toggleDictation),
                                    keyEquivalent: "")
        toggleMenuItem.target = self
        menu.addItem(toggleMenuItem)
        refreshToggleMenuItemTitle()

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

        let help = NSMenuItem(title: "Help",
                              action: #selector(openHelp),
                              keyEquivalent: "?")
        help.target = self
        menu.addItem(help)

        let about = NSMenuItem(title: "About Push to Dictate",
                               action: #selector(openAbout),
                               keyEquivalent: "")
        about.target = self
        menu.addItem(about)

        menu.addItem(NSMenuItem.separator())

        let attention = NSMutableAttributedString(string: "Grant Accessibility Access…")
        attention.addAttributes(
            [.foregroundColor: NSColor.systemRed,
             .font: NSFont.boldSystemFont(ofSize: NSFont.systemFontSize)],
            range: NSRange(location: 0, length: attention.length)
        )
        accessibilityRequestItem = NSMenuItem(title: "Grant Accessibility Access…",
                                              action: #selector(openAccessibilityRequest),
                                              keyEquivalent: "")
        accessibilityRequestItem.attributedTitle = attention
        accessibilityRequestItem.target = self
        accessibilityRequestItem.isHidden = true
        menu.addItem(accessibilityRequestItem)

        updatesMenuItem = NSMenuItem(title: "Check for Updates…",
                                     action: #selector(checkForUpdates),
                                     keyEquivalent: "")
        updatesMenuItem.target = self
        menu.addItem(updatesMenuItem)

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
        refreshToggleMenuItemTitle()
    }

    private func refreshToggleMenuItemTitle() {
        guard toggleMenuItem != nil else { return }
        let base = isRecording ? "Stop Dictation" : "Start Dictation"
        let hotkey = PreferencesWindowController.describe(
            keyCode: Preferences.shared.hotkeyKeyCode,
            flags: Preferences.shared.hotkeyModifierFlags
        )
        toggleMenuItem.title = "\(base)  \(hotkey)"
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
            // Any pending chunks from a previous continuous session continue
            // draining in the background, but don't want their completion to
            // flip our icon back to .idle while this new session is active.
            drainingAfterContinuous = false
            continuousPromptBuffer = ""
            isFirstContinuousChunk = true
            previousInjectedEndedWithSentencePunct = false
            trailingPeriodWorkItem?.cancel()
            trailingPeriodWorkItem = nil
            currentContinuousSessionId += 1
            continuousModeActive =
                hotkeyMonitor.mode == .toggle &&
                Preferences.shared.continuousDictationEnabled
            configureAutoStop()
            configureChunkBoundary()
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

            if continuousModeActive {
                let minSamples = Int(AudioRecorder.targetSampleRate * 0.4)
                if samples.count >= minSamples
                    && peak >= StatusItemController.silentPeakThreshold {
                    // Final tail chunk from session end has no measured gap.
                    enqueueContinuousChunk(samples: samples, gap: 0)
                }
                if pendingContinuousChunks > 0 {
                    drainingAfterContinuous = true
                    setIconState(.processing)
                } else {
                    setIconState(.idle)
                }
                continuousModeActive = false
            } else if peak < StatusItemController.silentPeakThreshold {
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
        // When stopping, transcribe() or the continuous branch take over icon
        // state (.processing then .idle on success or .error on failure).
        // Don't overwrite it here.
        refreshToggleMenuItemTitle()
    }

    private func configureAutoStop() {
        let prefs = Preferences.shared
        let eligible = hotkeyMonitor.mode == .toggle && prefs.silenceAutoStopEnabled
        if eligible {
            audioRecorder.autoStopThreshold = Float(prefs.silenceAutoStopThreshold)
            audioRecorder.autoStopDuration = prefs.silenceAutoStopSeconds
            audioRecorder.onAutoStopTriggered = { [weak self] in
                self?.setRecording(false)
            }
        } else {
            audioRecorder.autoStopThreshold = nil
            audioRecorder.autoStopDuration = nil
            audioRecorder.onAutoStopTriggered = nil
        }
    }

    private func configureChunkBoundary() {
        let prefs = Preferences.shared
        if continuousModeActive {
            // Reuse the user's silence RMS threshold. "What counts as silence"
            // is a single mental model; no reason to ask for it twice.
            audioRecorder.chunkBoundaryThreshold = Float(prefs.silenceAutoStopThreshold)
            audioRecorder.chunkBoundaryDuration = prefs.continuousDictationPauseSeconds
            audioRecorder.chunkBoundaryMaxDuration = prefs.continuousDictationMaxChunkSeconds
            audioRecorder.onChunkBoundary = { [weak self] samples, gap in
                self?.handleContinuousChunk(samples, gap: gap)
            }
            // Cancel the trailing-period timer the moment speech resumes,
            // rather than when the next chunk finishes transcribing. Without
            // this, a user who resumes talking within trailingPeriodSeconds
            // still gets a period planted before their next chunk lands,
            // because the timer counts wall-clock time from the previous
            // injection regardless of incoming audio.
            audioRecorder.onSpeechBegin = { [weak self] in
                DispatchQueue.main.async {
                    self?.trailingPeriodWorkItem?.cancel()
                    self?.trailingPeriodWorkItem = nil
                }
            }
        } else {
            audioRecorder.chunkBoundaryThreshold = nil
            audioRecorder.chunkBoundaryDuration = nil
            audioRecorder.chunkBoundaryMaxDuration = nil
            audioRecorder.onChunkBoundary = nil
            audioRecorder.onSpeechBegin = nil
        }
    }

    private func handleContinuousChunk(_ samples: [Float], gap: TimeInterval) {
        // Mid-recording boundary fire. Final-tail chunk is enqueued directly
        // from setRecording(false) and uses its own length / peak guards.
        let minSamples = Int(AudioRecorder.targetSampleRate * 0.4)
        if samples.count < minSamples { return }
        enqueueContinuousChunk(samples: samples, gap: gap)
    }

    private func enqueueContinuousChunk(samples: [Float], gap: TimeInterval) {
        let sessionId = currentContinuousSessionId
        pendingContinuousChunks += 1
        let transcriber = makeTranscriber()
        // Beam=2 for continuous chunks. Compromise between beam=1's speed
        // and beam=3's repetition-loop safety; prompt chaining and larger
        // chunks carry most of the quality load now. Override is
        // per-instance so single-shot dictation keeps using the user's
        // saved beamSize preference.
        if let whisper = transcriber as? WhisperCppTranscriber {
            whisper.beamSizeOverride = 1
        }
        let backendLabel = Preferences.shared.backend.rawValue
        let startedAt = Date()
        Logger.info("continuous: transcribing \(samples.count) samples via \(backendLabel)")
        continuousQueue.async { [weak self] in
            // Read the prompt tail at dequeue time: by the time the serial
            // queue runs this task, all previous tasks have completed, and
            // handleContinuousResult (invoked synchronously below) will have
            // appended their text to continuousPromptBuffer.
            DispatchQueue.main.sync {
                guard let self = self else { return }
                if !self.continuousPromptBuffer.isEmpty,
                   let whisper = transcriber as? WhisperCppTranscriber {
                    whisper.initialPrompt = self.continuousPromptBuffer
                }
            }

            // Block the serial queue on the transcriber's async completion
            // so FIFO order is preserved end-to-end.
            let sem = DispatchSemaphore(value: 0)
            var captured: TranscriberResult?
            transcriber.transcribe(audio: samples) { result in
                captured = result
                sem.signal()
            }
            sem.wait()
            let elapsed = Date().timeIntervalSince(startedAt)

            // Synchronous dispatch so this chunk's text is committed to the
            // prompt buffer before the next serial task starts reading it.
            DispatchQueue.main.sync {
                self?.handleContinuousResult(captured, elapsed: elapsed, gap: gap,
                                             sessionId: sessionId)
            }
        }
    }

    private func appendToContinuousPromptBuffer(_ text: String) {
        if !continuousPromptBuffer.isEmpty {
            continuousPromptBuffer.append(" ")
        }
        continuousPromptBuffer.append(text)
        let max = Preferences.shared.continuousDictationPromptChainMaxChars
        if continuousPromptBuffer.count > max {
            let overflow = continuousPromptBuffer.count - max
            let start = continuousPromptBuffer.index(
                continuousPromptBuffer.startIndex, offsetBy: overflow)
            continuousPromptBuffer = String(continuousPromptBuffer[start...])
        }
    }

    // Strip-mode trailing-period: appends "." to the existing prompt
    // buffer tail without a word-separator, after trimming any trailing
    // whitespace, so whisper's context sees "lastWord." as the sentence
    // close rather than "lastWord .".
    private func appendPeriodToContinuousPromptBuffer() {
        while let last = continuousPromptBuffer.last,
              last == " " || last == "\t" || last == "\n" {
            continuousPromptBuffer.removeLast()
        }
        if continuousPromptBuffer.isEmpty { return }
        continuousPromptBuffer.append(".")
        let max = Preferences.shared.continuousDictationPromptChainMaxChars
        if continuousPromptBuffer.count > max {
            let overflow = continuousPromptBuffer.count - max
            let start = continuousPromptBuffer.index(
                continuousPromptBuffer.startIndex, offsetBy: overflow)
            continuousPromptBuffer = String(continuousPromptBuffer[start...])
        }
    }

    private func scheduleTrailingPeriod() {
        let seconds = Preferences.shared.continuousDictationTrailingPeriodSeconds
        if seconds <= 0 { return }
        let sessionId = currentContinuousSessionId
        let work = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            if sessionId != self.currentContinuousSessionId { return }
            self.textInjector.insert(".")
            self.previousInjectedEndedWithSentencePunct = true
            if Preferences.shared.continuousDictationPromptChainEnabled {
                self.appendPeriodToContinuousPromptBuffer()
            }
            self.trailingPeriodWorkItem = nil
            Logger.info("continuous: trailing period injected (silence > \(seconds)s)")
        }
        trailingPeriodWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    // Removes whisper's non-speech annotation tokens that leak into the
    // transcript on silent / near-silent chunks: things like [BLANK_AUDIO],
    // [MUSIC], (soft music), (laughter). In single-shot dictation these are
    // rare because the whole recording tends to have speech; in continuous
    // mode the chunk-on-pause flow routinely feeds whisper short low-signal
    // fragments and the tokens show up frequently. Also drops pure-ellipsis
    // or punctuation-only results that would otherwise inject stray dots,
    // strips trailing ellipses (whisper's way of marking partial speech at
    // a chunk tail), and normalizes casing to lowercase with capitals only
    // at sentence starts.
    private static func postProcessTranscript(_ text: String,
                                              stripPunctuation: Bool = false) -> String {
        var cleaned = text
        let patterns = [
            "\\[[^\\]]*\\]",
            "\\([^\\)]*\\)",
            // Asterisk-delimited sound annotations whisper emits on
            // near-silent or non-speech chunks: *cough*, *laughs*,
            // *sighs*, *music playing*, etc. Match a `*` followed by
            // non-`*` content and a closing `*`.
            "\\*[^*]*\\*",
            // Leading angle-bracket artifacts whisper emits on silent or
            // near-silent chunks (e.g. ">> I" when transcribing a long
            // silence). Strip them along with any surrounding whitespace.
            "^\\s*>+\\s*"
        ]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
                continue
            }
            let range = NSRange(cleaned.startIndex..., in: cleaned)
            cleaned = regex.stringByReplacingMatches(
                in: cleaned, options: [], range: range, withTemplate: "")
        }
        if let ws = try? NSRegularExpression(pattern: "\\s+", options: []) {
            let range = NSRange(cleaned.startIndex..., in: cleaned)
            cleaned = ws.stringByReplacingMatches(
                in: cleaned, options: [], range: range, withTemplate: " ")
        }
        cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        if let ellipsis = try? NSRegularExpression(
            pattern: "(?:\\.{3,}|…+)\\s*$", options: []) {
            let range = NSRange(cleaned.startIndex..., in: cleaned)
            cleaned = ellipsis.stringByReplacingMatches(
                in: cleaned, options: [], range: range, withTemplate: "")
            cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if stripPunctuation {
            // Strip sentence-ending periods only: a period followed by
            // whitespace or end-of-string. Periods inside words are
            // preserved so proper nouns like "whisper.cpp" and "Node.js"
            // survive. Question marks and exclamation marks are preserved
            // too: their intonation-driven signal from whisper is kept.
            if let regex = try? NSRegularExpression(pattern: "\\.+(?=\\s|$)", options: []) {
                let range = NSRange(cleaned.startIndex..., in: cleaned)
                cleaned = regex.stringByReplacingMatches(
                    in: cleaned, options: [], range: range, withTemplate: " ")
            }
            if let ws = try? NSRegularExpression(pattern: "\\s+", options: []) {
                let range = NSRange(cleaned.startIndex..., in: cleaned)
                cleaned = ws.stringByReplacingMatches(
                    in: cleaned, options: [], range: range, withTemplate: " ")
            }
            cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        // Require at least one letter or digit, else treat as empty (drops
        // whisper outputs that boil down to just "..." or similar).
        let hasContent = cleaned.unicodeScalars.contains {
            CharacterSet.alphanumerics.contains($0)
        }
        if !hasContent { return "" }
        let normalized = normalizeCasing(cleaned,
                                         capitalizeAtSentenceStarts: !stripPunctuation)
        return applyTextSubstitutions(applyCapitalizationFixups(normalized))
    }

    // Applies pattern -> replacement substitutions where the matched
    // form and the produced form differ. Used for unit abbreviations
    // (spoken "megabytes" -> "MB") and for multi-word whisper tokens
    // that the single-word capitalization fixup can't handle ("mac os"
    // -> "macOS"). Case-insensitive, word-boundary matched. List lives
    // on Preferences so it can be made user-editable without touching
    // this function.
    private static func applyTextSubstitutions(_ text: String) -> String {
        var result = text
        for (pattern, replacement) in Preferences.shared.textSubstitutions {
            let escaped = NSRegularExpression.escapedPattern(for: pattern)
            let regexPattern = "\\b\(escaped)\\b"
            guard let regex = try? NSRegularExpression(
                pattern: regexPattern, options: [.caseInsensitive]) else {
                continue
            }
            let range = NSRange(result.startIndex..., in: result)
            let template = NSRegularExpression.escapedTemplate(for: replacement)
            result = regex.stringByReplacingMatches(
                in: result, options: [], range: range, withTemplate: template)
        }
        return result
    }

    // Restores canonical casing for a curated list of proper nouns,
    // brand names, and acronyms that the lowercase pass folded. Each
    // entry is matched case-insensitively with word boundaries so
    // internal letters (e.g. the "us" in "trust") are not disturbed.
    // The list lives on Preferences so it can be made user-editable
    // without touching this function.
    private static func applyCapitalizationFixups(_ text: String) -> String {
        var result = text
        for canonical in Preferences.shared.capitalizationFixups {
            let escaped = NSRegularExpression.escapedPattern(for: canonical)
            let pattern = "\\b\(escaped)\\b"
            guard let regex = try? NSRegularExpression(
                pattern: pattern, options: [.caseInsensitive]) else {
                continue
            }
            let range = NSRange(result.startIndex..., in: result)
            let template = NSRegularExpression.escapedTemplate(for: canonical)
            result = regex.stringByReplacingMatches(
                in: result, options: [], range: range, withTemplate: template)
        }
        return result
    }

    // Lowercases the text, then re-uppercases the first alphabetic
    // character and any letter following sentence-ending punctuation
    // (. ! ?) across intervening whitespace. Mid-word punctuation like
    // commas, apostrophes, and hyphens do not trigger capitalization.
    // In continuous mode this means the first word of every chunk is
    // capitalized even when it is a mid-sentence continuation of the
    // previous chunk; acceptable because pauses long enough to trigger
    // a chunk boundary usually fall on sentence breaks anyway.
    private static func normalizeCasing(_ text: String,
                                        capitalizeAtSentenceStarts: Bool = true) -> String {
        var result = String()
        result.reserveCapacity(text.count)
        // When capitalizeAtSentenceStarts is false (strip-punctuation mode)
        // the initial state is "don't capitalize"; period-driven
        // capitalization is also suppressed. Even in strip mode, however,
        // the alpha character immediately following a `?` or `!` preserves
        // whisper's original case, so a legitimate next-sentence capital
        // that whisper emitted inside a chunk is not destroyed.
        var needsCapital = capitalizeAtSentenceStarts
        var preserveNextOriginalCase = false
        for ch in text {
            if ch == "." || ch == "!" || ch == "?" {
                result.append(ch)
                needsCapital = capitalizeAtSentenceStarts
                preserveNextOriginalCase = (ch == "!" || ch == "?")
            } else if ch == " " || ch == "\t" || ch == "\n" {
                result.append(ch)
            } else {
                let isUpperAlpha = ch >= "A" && ch <= "Z"
                let isLowerAlpha = ch >= "a" && ch <= "z"
                if needsCapital && isLowerAlpha {
                    result.append(String(ch).uppercased())
                } else if preserveNextOriginalCase {
                    result.append(ch)
                } else if isUpperAlpha {
                    result.append(String(ch).lowercased())
                } else {
                    result.append(ch)
                }
                needsCapital = false
                preserveNextOriginalCase = false
            }
        }
        // Re-uppercase the standalone pronoun "i" and its contractions
        // (i'll, i've, i'm, i'd) which the lowercase pass folded. \b
        // treats the apostrophe as a word boundary, so \bi\b matches the
        // "i" in "i'll" but not the "i" inside words like "apply" or "is".
        if let regex = try? NSRegularExpression(pattern: "\\bi\\b", options: []) {
            let range = NSRange(result.startIndex..., in: result)
            result = regex.stringByReplacingMatches(
                in: result, options: [], range: range, withTemplate: "I")
        }
        return result
    }

    private func handleContinuousResult(_ result: TranscriberResult?,
                                        elapsed: TimeInterval,
                                        gap: TimeInterval,
                                        sessionId: Int) {
        pendingContinuousChunks -= 1
        // Stale chunk from a prior session (user stopped and restarted
        // before this one finished transcribing). Drop it rather than
        // injecting into the new session, which would corrupt the new
        // session's first-chunk state and visually plant leftover text
        // where the user didn't dictate it.
        let isStale = sessionId != currentContinuousSessionId
        if isStale {
            if let result = result, case .success(let text) = result {
                Logger.info(String(format: "continuous: dropping stale chunk from prior session (%.2fs, gap=%.2fs): %@",
                                   elapsed, gap, text))
            }
            if drainingAfterContinuous && pendingContinuousChunks == 0 {
                drainingAfterContinuous = false
                setIconState(.idle)
            }
            return
        }
        // New chunk is landing: cancel any pending trailing-period that was
        // armed by the previous chunk. If this chunk itself warrants one,
        // we re-arm at the bottom of the strip-mode branch.
        trailingPeriodWorkItem?.cancel()
        trailingPeriodWorkItem = nil
        if let result = result {
            switch result {
            case .success(let text):
                Logger.info(String(format: "continuous transcript (%.2fs, gap=%.2fs): %@",
                                   elapsed, gap, text))
                let prefs = Preferences.shared
                let stripMode = prefs.continuousDictationStripWhisperPunctuation
                var cleaned = StatusItemController.postProcessTranscript(
                    text, stripPunctuation: stripMode)
                if !cleaned.isEmpty {
                    let injected: String
                    if stripMode {
                        // Leading-separator policy per IDEAS.md. Each
                        // chunk is injected immediately when transcribed.
                        // Sentence-break logic has two mechanisms; they
                        // coexist regardless of auto-end-period state:
                        //
                        // Gap-based: chunk arriving with gap in the
                        // new-sentence window [P, 2P] where P =
                        // sentencePauseSeconds. Prefix is `". "` +
                        // capital. Outside the window (gap < P or gap
                        // > 2P) is just `" "` continuation.
                        //
                        // Trailing-period timer: when auto-end-period is
                        // ON, a timer fires after 4P of silence from
                        // speech-end and injects `.`. Subsequent chunks
                        // observe `previousInjectedEndedWithSentencePunct`
                        // and prefix `" "` + capital.
                        cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
                        let prefix: String
                        // AX query: if the target field's cursor is at a
                        // line start, treat as fresh start. Returns nil
                        // when the app doesn't support text AX; fall
                        // through to the normal logic in that case.
                        let atLineStart = CursorContext.isCursorAtLineStart()
                        let gapIsSentenceBreak =
                            gap >= prefs.continuousDictationSentencePauseSeconds
                            && gap <= prefs.continuousDictationSentencePauseMaxSeconds
                        if isFirstContinuousChunk {
                            prefix = ""
                            isFirstContinuousChunk = false
                            cleaned = StatusItemController.capitalizeFirstAlphabetic(cleaned)
                        } else if atLineStart == true {
                            prefix = ""
                            cleaned = StatusItemController.capitalizeFirstAlphabetic(cleaned)
                        } else if previousInjectedEndedWithSentencePunct {
                            // Prior injection already ended with `.`/`?`/`!`
                            // (whisper's own, or the trailing-period timer
                            // firing). Never stack punctuation; always
                            // capitalize because a new sentence is starting.
                            prefix = " "
                            cleaned = StatusItemController.capitalizeFirstAlphabetic(cleaned)
                        } else if gapIsSentenceBreak {
                            prefix = ". "
                            cleaned = StatusItemController.capitalizeFirstAlphabetic(cleaned)
                        } else {
                            prefix = " "
                        }
                        injected = prefix + cleaned
                        if let last = cleaned.last {
                            previousInjectedEndedWithSentencePunct =
                                (last == "?" || last == "!")
                        } else {
                            previousInjectedEndedWithSentencePunct = false
                        }
                    } else {
                        // Current / stable behavior: trailing space per chunk.
                        injected = "\(cleaned) "
                    }
                    textInjector.insert(injected)
                    if prefs.continuousDictationPromptChainEnabled {
                        // Feed whisper a non-stripped, fully-punctuated,
                        // sentence-case form as context, regardless of
                        // what we injected to the user. The prompt steers
                        // whisper's language model; richer punctuation
                        // and capitalization give it stronger signal for
                        // acoustically-ambiguous word choices (an/and,
                        // to/too, their/there). Only used for the prompt;
                        // the user's visible text stays in the chosen
                        // mode's form.
                        let promptText: String
                        if stripMode {
                            let fullyPunctuated =
                                StatusItemController.postProcessTranscript(
                                    text, stripPunctuation: false)
                            promptText = fullyPunctuated.isEmpty
                                ? injected
                                : "\(fullyPunctuated) "
                        } else {
                            promptText = injected
                        }
                        appendToContinuousPromptBuffer(promptText)
                    }
                    // Arm the trailing-period timer. If the user stays
                    // silent past trailingPeriodSeconds, a `.` is
                    // appended to close the sentence. Strip mode +
                    // auto-end-period only; skipped if the chunk already
                    // ended with sentence-terminating punctuation, and
                    // skipped if the user is currently still speaking
                    // (this chunk was a max-chunk force-emit mid-speech,
                    // not an actual pause).
                    if stripMode
                        && prefs.continuousDictationAutoEndPeriod
                        && !audioRecorder.isSpeaking {
                        let endsTerminal: Bool
                        if let last = cleaned.last {
                            endsTerminal = (last == "." || last == "?" || last == "!")
                        } else {
                            endsTerminal = false
                        }
                        if !endsTerminal {
                            scheduleTrailingPeriod()
                        }
                    }
                }
            case .failure(let error):
                Logger.error("continuous chunk transcription failed",
                             detail: String(format: "%.2fs: %@",
                                            elapsed, error.localizedDescription))
            }
        }
        if drainingAfterContinuous && pendingContinuousChunks == 0 {
            drainingAfterContinuous = false
            setIconState(.idle)
        }
    }

    // Uppercases the first alphabetic character of the string, leaving
    // the rest untouched. Used by strip-punctuation mode to re-cap the
    // leading letter of a chunk that follows a detected sentence pause.
    private static func capitalizeFirstAlphabetic(_ text: String) -> String {
        var result = String()
        result.reserveCapacity(text.count)
        var capitalized = false
        for ch in text {
            if !capitalized && ch >= "a" && ch <= "z" {
                result.append(String(ch).uppercased())
                capitalized = true
            } else {
                result.append(ch)
                if ch >= "A" && ch <= "Z" {
                    capitalized = true
                }
            }
        }
        return result
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
                    let cleaned = StatusItemController.postProcessTranscript(text)
                    if !cleaned.isEmpty {
                        self?.textInjector.insert(cleaned)
                    }
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
        showAccessibilityRequestWindow()
    }

    private func showAccessibilityRequestWindow() {
        AccessibilityRequestWindowController.present(
            onTrustGranted: { [weak self] in
                guard let self = self else { return false }
                self.hotkeyMonitor.start()
                return self.hotkeyMonitor.isActive
            },
            onMenuShouldRefresh: { [weak self] in
                self?.refreshAccessibilityMenuItem()
            }
        )
    }

    private func maybeShowWelcomePopover() {
        if Preferences.shared.didShowWelcomeTooltip { return }
        // Delay so the status-item button is fully placed before the popover
        // tries to anchor to it.
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
        body.stringValue = "Press \(hotkey) to start dictation. Click the icon for Help and more options."
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

    @objc private func openHelp() {
        HelpWindowController.shared.show()
    }

    @objc private func checkForUpdates() {
        UpdateCheckWindowController.present(
            onResult: { [weak self] result in
                guard let self = self else { return }
                let skipped = Preferences.shared.skippedUpdateVersion
                switch result {
                case .updateAvailable(_, let latest, _):
                    self.pendingUpdateVersion = (latest == skipped) ? nil : latest
                case .upToDate:
                    self.pendingUpdateVersion = nil
                    if !skipped.isEmpty {
                        Preferences.shared.skippedUpdateVersion = ""
                    }
                case .error:
                    break
                }
                self.refreshUpdatesMenuItem()
                self.refreshMenuBarIcon()
            },
            onSkip: { [weak self] latest in
                guard let self = self else { return }
                Preferences.shared.skippedUpdateVersion = latest
                self.pendingUpdateVersion = nil
                self.refreshUpdatesMenuItem()
                self.refreshMenuBarIcon()
            }
        )
    }

    private func refreshUpdatesMenuItem() {
        if let latest = pendingUpdateVersion {
            let title = "Update available: \(latest)"
            let attributed = NSMutableAttributedString(string: title)
            attributed.addAttributes(
                [.foregroundColor: NSColor.systemBlue,
                 .font: NSFont.boldSystemFont(ofSize: NSFont.systemFontSize)],
                range: NSRange(location: 0, length: attributed.length)
            )
            updatesMenuItem.attributedTitle = attributed
            updatesMenuItem.title = title
        } else {
            updatesMenuItem.attributedTitle = nil
            updatesMenuItem.title = "Check for Updates…"
        }
    }

    @objc private func openAccessibilityRequest() {
        showAccessibilityRequestWindow()
    }

    private func refreshAccessibilityMenuItem() {
        let needsAttention =
            !HotkeyMonitor.hasAccessibilityPermission() &&
            AccessibilityRequestWindowController.active == nil
        accessibilityRequestItem.isHidden = !needsAttention
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        refreshAccessibilityMenuItem()
        refreshStatusRows()
    }

    private func refreshStatusRows() {
        let prefs = Preferences.shared

        switch prefs.backend {
        case .whisperCpp:
            let stem = (prefs.localModelFilename as NSString).deletingPathExtension
            modelStatusItem.title = "Model: \(stem)"
            threadsStatusItem.title = "Thread Usage: \(prefs.transcriptionThreads)"
            threadsStatusItem.isHidden = false
        case .openAI:
            modelStatusItem.title = "Model: whisper-1 (OpenAI)"
            threadsStatusItem.isHidden = true
        }

        let mode = (prefs.hotkeyMode == .pushToTalk) ? "Push-to-talk" : "Toggle"
        let method = (prefs.injectionMethod == .typed) ? "Typed" : "Pasted"
        behaviorStatusItem.title = "Modes: \(mode) · \(method)"
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
