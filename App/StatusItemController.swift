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
    // True iff the previous emitted chunk was a max-chunk cut. Used by the
    // acoustic-overlap feature to decide whether to run leading-word dedup
    // on the current chunk's raw transcript. Reset on session start.
    private var previousChunkWasMaxCut: Bool = false
    // Case-folded alphanumeric tokens from the end of the previous chunk's
    // raw transcript (up to ~5 tokens). Used to detect and drop duplicate
    // leading words in the next chunk's transcript when acoustic overlap
    // is active. Reset on session start.
    private var previousChunkTailTokens: [String] = []
    // Last word (lowercased) of the string actually injected for the
    // previous chunk. Used by the consecutive-duplicate filter to catch
    // cross-chunk duplicates that the overlap dedup missed (whisper
    // rendered the overlapping word slightly differently in the two
    // chunks, so string-equality dedup didn't fire). Reset on session start.
    private var previousInjectedLastWord: String?
    // Per-session directory for debug WAVs + sidecar text files, one
    // folder per continuous dictation session when Save debug recordings
    // is on. Lazy-created on first chunk; nil otherwise. Reset on session
    // start so each session gets its own folder.
    private var debugSessionDir: URL?
    private var debugChunkCounter: Int = 0

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
            previousChunkWasMaxCut = false
            previousChunkTailTokens = []
            previousInjectedLastWord = nil
            debugSessionDir = nil
            debugChunkCounter = 0
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
                    // Session-end is a clean cut on a user-initiated stop,
                    // not a mid-speech max-chunk cut, so no overlap dedup.
                    enqueueContinuousChunk(samples: samples, gap: 0,
                                           wasMaxChunkCut: false)
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
            let overlap = prefs.continuousDictationChunkOverlapSeconds
            audioRecorder.chunkBoundaryOverlapSeconds = overlap > 0 ? overlap : nil
            audioRecorder.onChunkBoundary = { [weak self] samples, gap, wasMaxChunkCut in
                self?.handleContinuousChunk(samples, gap: gap,
                                            wasMaxChunkCut: wasMaxChunkCut)
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
            audioRecorder.chunkBoundaryOverlapSeconds = nil
            audioRecorder.onChunkBoundary = nil
            audioRecorder.onSpeechBegin = nil
        }
    }

    private func handleContinuousChunk(_ samples: [Float], gap: TimeInterval,
                                       wasMaxChunkCut: Bool) {
        // Mid-recording boundary fire. Final-tail chunk is enqueued directly
        // from setRecording(false) and uses its own length / peak guards.
        let minSamples = Int(AudioRecorder.targetSampleRate * 0.4)
        if samples.count < minSamples { return }
        enqueueContinuousChunk(samples: samples, gap: gap,
                               wasMaxChunkCut: wasMaxChunkCut)
    }

    private func enqueueContinuousChunk(samples: [Float], gap: TimeInterval,
                                        wasMaxChunkCut: Bool) {
        let sessionId = currentContinuousSessionId
        pendingContinuousChunks += 1
        debugChunkCounter += 1
        let chunkNumber = debugChunkCounter
        let debugWavURL = writeChunkDebugWavIfEnabled(samples: samples,
                                                      chunkNumber: chunkNumber,
                                                      wasMaxChunkCut: wasMaxChunkCut)
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
                                             sessionId: sessionId,
                                             wasMaxChunkCut: wasMaxChunkCut,
                                             debugWavURL: debugWavURL)
            }
        }
    }

    // Writes per-chunk audio to disk when `Save debug recordings` is on
    // and we're in continuous mode. Lazy-creates a session folder on the
    // first chunk. Returns the WAV URL so the caller can thread it through
    // to `handleContinuousResult` for the sibling .txt. Nil disables.
    private func writeChunkDebugWavIfEnabled(samples: [Float],
                                             chunkNumber: Int,
                                             wasMaxChunkCut: Bool) -> URL? {
        guard Preferences.shared.saveDebugRecordings else { return nil }
        guard continuousModeActive else { return nil }

        let fm = FileManager.default
        if debugSessionDir == nil {
            guard let appSupport = fm.urls(for: .applicationSupportDirectory,
                                           in: .userDomainMask).first else { return nil }
            let fmt = DateFormatter()
            fmt.dateFormat = "yyyyMMdd-HHmmss"
            let dir = appSupport
                .appendingPathComponent("push-to-dictate/debug", isDirectory: true)
                .appendingPathComponent("session-\(fmt.string(from: Date()))",
                                        isDirectory: true)
            do {
                try fm.createDirectory(at: dir,
                                       withIntermediateDirectories: true,
                                       attributes: nil)
            } catch {
                Logger.error("debug session dir", detail: error.localizedDescription)
                return nil
            }
            debugSessionDir = dir
        }
        guard let dir = debugSessionDir else { return nil }

        let reason = wasMaxChunkCut ? "maxchunk" : "pause"
        let name = String(format: "chunk-%03d-%@.wav", chunkNumber, reason)
        let url = dir.appendingPathComponent(name)
        if AudioRecorder.writeSamplesAsWav(samples: samples, to: url) {
            return url
        } else {
            Logger.error("debug chunk wav", detail: "write failed for \(url.path)")
            return nil
        }
    }

    // Writes the sibling .txt next to `debugWavURL` with all the
    // metadata needed to diagnose what whisper heard and how the
    // overlap/dedup/filter stages shaped the result.
    private func writeChunkDebugMetadataIfEnabled(debugWavURL: URL?,
                                                  gap: TimeInterval,
                                                  elapsed: TimeInterval,
                                                  wasMaxChunkCut: Bool,
                                                  rawText: String,
                                                  dedupedText: String,
                                                  prevTail: [String],
                                                  newHead: [String],
                                                  matchLen: Int,
                                                  cleaned: String,
                                                  injected: String,
                                                  prevInjectedLastWord: String?) {
        guard let wavURL = debugWavURL else { return }
        let txtURL = wavURL.deletingPathExtension().appendingPathExtension("txt")
        let reason = wasMaxChunkCut ? "maxchunk" : "pause"
        var body = ""
        body += "wav: \(wavURL.lastPathComponent)\n"
        body += String(format: "gap: %.2fs\n", gap)
        body += String(format: "elapsed: %.2fs\n", elapsed)
        body += "cut: \(reason)\n"
        body += "raw: \(rawText)\n"
        body += "deduped: \(dedupedText)\n"
        body += "prevTail: \(prevTail)\n"
        body += "newHead: \(newHead)\n"
        body += "matchLen: \(matchLen)\n"
        body += "cleaned: \(cleaned)\n"
        body += "injected: \(injected)\n"
        body += "prevInjectedLastWord: \(prevInjectedLastWord ?? "(nil)")\n"
        do {
            try body.write(to: txtURL, atomically: true, encoding: .utf8)
        } catch {
            Logger.error("debug chunk txt",
                         detail: "write failed for \(txtURL.path): \(error.localizedDescription)")
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

    // Standard-mode counterpart to scheduleTrailingPeriod. Fires once after
    // the configured number of seconds unless the user starts a new recording
    // first (setRecording(true) cancels trailingPeriodWorkItem). Skipped when
    // the injected text already ends with sentence-terminating punctuation, so
    // dictations that naturally resolve (`"Where are you?"`, `"Watch out!"`)
    // aren't followed by a stray period.
    private func scheduleStandardTrailingPeriodIfNeeded(for injected: String) {
        guard Preferences.shared.continuousDictationAutoEndPeriod else { return }
        let seconds = Preferences.shared.continuousDictationTrailingPeriodSeconds
        if seconds <= 0 { return }
        if let last = injected.last, last == "." || last == "?" || last == "!" {
            return
        }
        let work = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            self.textInjector.insert(".")
            self.trailingPeriodWorkItem = nil
            Logger.info("standard: trailing period injected (silence > \(seconds)s)")
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
        let prefs = Preferences.shared
        // Root gate: when off, whisper's raw transcript bypasses every
        // post-processing pass and is returned verbatim. Each nested
        // preference below individually governs its pass when the root
        // is on.
        if !prefs.transcriptProcessingEnabled { return text }

        var cleaned = text
        if prefs.removeNonSpeechAnnotations {
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
        }
        if let ws = try? NSRegularExpression(pattern: "\\s+", options: []) {
            let range = NSRange(cleaned.startIndex..., in: cleaned)
            cleaned = ws.stringByReplacingMatches(
                in: cleaned, options: [], range: range, withTemplate: " ")
        }
        cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        if prefs.removeNonSpeechAnnotations,
           let ellipsis = try? NSRegularExpression(
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
        var out = cleaned
        if prefs.normalizeCapitalization {
            out = normalizeCasing(out)
        }
        if prefs.applyProperNounFixups {
            out = applyCapitalizationFixups(out)
        }
        if prefs.applyTextSubstitutions {
            out = applyTextSubstitutions(out)
        }
        return out
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
    // Lowercase any uppercase letter that is not preceded by sentence-ending
    // punctuation + whitespace (`. `, `! `, `? `). Whisper-emitted capitals at
    // genuine sentence starts are preserved; mid-sentence capitals that whisper
    // introduced (shouty-case artifacts, hallucinated proper nouns) are folded
    // to lowercase. In strip mode the caller has already removed sentence
    // periods before this runs, so there are no `. ` anchors left and the
    // regex collapses to "lowercase everything"; chunk-join logic then adds
    // capitals back at chunk boundaries as needed. First-letter-of-transcript
    // capitalization in toggle mode is applied after this, outside
    // postProcessTranscript, driven by CursorContext.isCursorAtLineStart.
    private static func normalizeCasing(_ text: String) -> String {
        var result = text
        if let regex = try? NSRegularExpression(
            pattern: "(?<![.!?]\\s)[A-Z]", options: []) {
            let range = NSRange(result.startIndex..., in: result)
            let matches = regex.matches(in: result, options: [], range: range)
            // Iterate in reverse so earlier range replacements don't shift
            // the indices of later matches.
            for match in matches.reversed() {
                guard let r = Range(match.range, in: result) else { continue }
                result.replaceSubrange(r, with: result[r].lowercased())
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
                                        sessionId: Int,
                                        wasMaxChunkCut: Bool,
                                        debugWavURL: URL?) {
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
            case .success(let rawText):
                Logger.info(String(format: "continuous transcript (%.2fs, gap=%.2fs): %@",
                                   elapsed, gap, rawText))
                let prefs = Preferences.shared
                // Acoustic-overlap dedup: if the previous chunk was a
                // max-chunk cut and overlap was configured, whisper has
                // transcribed the overlapped leading audio twice. Drop
                // the duplicate leading tokens in the current raw text
                // before any downstream processing (strip, prompt chain).
                let text: String
                let dedupPrevTail = previousChunkTailTokens
                var dedupHeadTokens: [String] = []
                var dedupMatchLen = 0
                if previousChunkWasMaxCut,
                   prefs.continuousDictationChunkOverlapSeconds > 0,
                   !previousChunkTailTokens.isEmpty {
                    dedupHeadTokens = StatusItemController.leadingTokensWithEnd(
                        rawText, upTo: previousChunkTailTokens.count).map { $0.0 }
                    let trimmed = StatusItemController.dedupeOverlapTokens(
                        newText: rawText, previousTail: previousChunkTailTokens)
                    dedupMatchLen = trimmed == rawText
                        ? 0
                        : (dedupHeadTokens.count -
                           StatusItemController.leadingTokensWithEnd(
                               trimmed, upTo: dedupHeadTokens.count).count)
                    Logger.info("continuous: overlap boundary "
                        + "prevTail=\(dedupPrevTail) "
                        + "newHead=\(dedupHeadTokens) "
                        + "matchLen=\(dedupMatchLen)")
                    text = trimmed
                } else {
                    text = rawText
                }
                // Remember trailing tokens of the (possibly dedup'd) raw
                // text so the next chunk can dedup against them. Also
                // remember whether this chunk was a max-chunk cut so the
                // next chunk's handler knows whether to dedup at all.
                previousChunkTailTokens = StatusItemController.trailingTokens(
                    text, count: 5)
                previousChunkWasMaxCut = wasMaxChunkCut
                let stripMode = prefs.continuousDictationStripWhisperPunctuation
                var cleaned = StatusItemController.postProcessTranscript(
                    text, stripPunctuation: stripMode)
                // Consecutive-duplicate filter, two passes:
                // 1. Within-chunk: collapse adjacent identical tokens
                //    separated by whitespace only (not punctuation, which
                //    indicates deliberate emphasis).
                // 2. Cross-chunk: if the first word of this chunk exactly
                //    matches the last word injected in the previous chunk,
                //    drop it. Catches cases where overlap dedup missed a
                //    duplicate because whisper rendered the overlapped
                //    word differently in each chunk.
                if prefs.transcriptProcessingEnabled
                    && prefs.filterConsecutiveDuplicates
                    && !cleaned.isEmpty {
                    let beforeInner = cleaned
                    cleaned = StatusItemController.filterConsecutiveDuplicates(cleaned)
                    if cleaned != beforeInner {
                        Logger.info("continuous: duplicate filter collapsed within-chunk repeats")
                    }
                    if let prev = previousInjectedLastWord,
                       let (firstWord, firstWordEnd) =
                            StatusItemController.firstWord(of: cleaned),
                       firstWord == prev.lowercased() {
                        let remaining = String(cleaned[firstWordEnd...])
                            .trimmingCharacters(in: .whitespaces)
                        Logger.info("continuous: duplicate filter dropped cross-chunk repeat of \(prev)")
                        cleaned = remaining
                    }
                }
                var injectedForDebug = ""
                let prevInjectedLastWordForDebug = previousInjectedLastWord
                if !cleaned.isEmpty {
                    let injected: String
                    if stripMode {
                        // Leading-separator policy per IDEAS.md. Each
                        // chunk is injected immediately when transcribed.
                        // Sentence-break logic has two mechanisms; they
                        // coexist regardless of auto-end-period state:
                        //
                        // Gap-based: chunk arriving with gap in the
                        // new-sentence window [P, W] where P =
                        // pauseSeconds and W = sentencePauseMaxSeconds
                        // (Window threshold in the UI). Prefix is `". "` +
                        // capital. Beyond W, a resuming chunk gets `" "`
                        // continuation. Below P no chunk emits at all,
                        // so there's no sub-P case to handle here.
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
                            gap >= prefs.continuousDictationPauseSeconds
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
                    injectedForDebug = injected
                    previousInjectedLastWord = StatusItemController.lastWord(of: injected)
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
                writeChunkDebugMetadataIfEnabled(
                    debugWavURL: debugWavURL,
                    gap: gap, elapsed: elapsed,
                    wasMaxChunkCut: wasMaxChunkCut,
                    rawText: rawText, dedupedText: text,
                    prevTail: dedupPrevTail,
                    newHead: dedupHeadTokens,
                    matchLen: dedupMatchLen,
                    cleaned: cleaned,
                    injected: injectedForDebug,
                    prevInjectedLastWord: prevInjectedLastWordForDebug)
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

    // Helpers for acoustic-overlap leading-word dedup. A word is a run of
    // Unicode alphanumerics; non-alphanumerics (whitespace, punctuation,
    // apostrophes) separate them. Lowercased so case differences across
    // whisper runs don't block a match.

    private static func isWordChar(_ ch: Character) -> Bool {
        for scalar in ch.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) { return true }
        }
        return false
    }

    // Returns the last `count` alphanumeric tokens from `text`, lowercased.
    private static func trailingTokens(_ text: String, count: Int) -> [String] {
        var tokens: [String] = []
        var i = text.startIndex
        while i < text.endIndex {
            while i < text.endIndex && !isWordChar(text[i]) {
                i = text.index(after: i)
            }
            if i >= text.endIndex { break }
            let start = i
            while i < text.endIndex && isWordChar(text[i]) {
                i = text.index(after: i)
            }
            tokens.append(String(text[start..<i]).lowercased())
        }
        return Array(tokens.suffix(count))
    }

    // Leading alphanumeric tokens from `text`, lowercased, with the end
    // index of each token in the original string so the caller can drop
    // text up to a chosen cut point.
    private static func leadingTokensWithEnd(
        _ text: String, upTo limit: Int) -> [(String, String.Index)] {
        var out: [(String, String.Index)] = []
        var i = text.startIndex
        while i < text.endIndex && out.count < limit {
            while i < text.endIndex && !isWordChar(text[i]) {
                i = text.index(after: i)
            }
            if i >= text.endIndex { break }
            let start = i
            while i < text.endIndex && isWordChar(text[i]) {
                i = text.index(after: i)
            }
            out.append((String(text[start..<i]).lowercased(), i))
        }
        return out
    }

    // Drops the second of any adjacent identical word tokens, where
    // "adjacent" means separated by whitespace only (no intervening
    // punctuation). Comparison is case-insensitive, punctuation-insensitive,
    // on alphanumeric runs. Handles arbitrarily long runs ("no no no" →
    // "no"). Preserves inter-word non-whitespace content, so "very, very
    // good" is left intact: the comma indicates deliberate emphasis.
    static func filterConsecutiveDuplicates(_ text: String) -> String {
        var result = String()
        result.reserveCapacity(text.count)
        var lastWord: String? = nil
        var i = text.startIndex
        while i < text.endIndex {
            let sepStart = i
            while i < text.endIndex && !isWordChar(text[i]) {
                i = text.index(after: i)
            }
            let separator = String(text[sepStart..<i])
            if i >= text.endIndex {
                result.append(separator)
                break
            }
            let wordStart = i
            while i < text.endIndex && isWordChar(text[i]) {
                i = text.index(after: i)
            }
            let word = String(text[wordStart..<i])
            let sepIsWhitespaceOnly = !separator.isEmpty
                && separator.allSatisfy { $0 == " " || $0 == "\t" || $0 == "\n" }
            if let prev = lastWord,
               sepIsWhitespaceOnly,
               prev.lowercased() == word.lowercased() {
                // Drop this word AND its separator. Keep lastWord unchanged
                // so a third consecutive copy is also dropped.
                continue
            }
            result.append(separator)
            result.append(word)
            lastWord = word
        }
        return result
    }

    // Returns the first alphanumeric word of `text`, lowercased, along
    // with the end index just past it. Nil if no word is present.
    private static func firstWord(of text: String) -> (String, String.Index)? {
        var i = text.startIndex
        while i < text.endIndex && !isWordChar(text[i]) {
            i = text.index(after: i)
        }
        if i >= text.endIndex { return nil }
        let start = i
        while i < text.endIndex && isWordChar(text[i]) {
            i = text.index(after: i)
        }
        return (String(text[start..<i]).lowercased(), i)
    }

    // Returns the last alphanumeric word of `text`, lowercased.
    private static func lastWord(of text: String) -> String? {
        let tokens = trailingTokens(text, count: 1)
        return tokens.last
    }

    // If the leading tokens of `newText` match a suffix of `previousTail`,
    // drop the matching leading portion from `newText`. Prefers the
    // longest match. No change if no match is found; accepting an
    // occasional duplicate is safer than silently chopping real words.
    static func dedupeOverlapTokens(newText: String,
                                    previousTail: [String]) -> String {
        if previousTail.isEmpty { return newText }
        let headWithEnds = leadingTokensWithEnd(newText, upTo: previousTail.count)
        if headWithEnds.isEmpty { return newText }
        let head = headWithEnds.map { $0.0 }
        let maxMatch = min(head.count, previousTail.count)
        var matchLen = 0
        for L in stride(from: maxMatch, through: 1, by: -1) {
            if Array(head.prefix(L)) == Array(previousTail.suffix(L)) {
                matchLen = L
                break
            }
        }
        if matchLen == 0 { return newText }
        let dropEnd = headWithEnds[matchLen - 1].1
        let remaining = String(newText[dropEnd...])
        return remaining.trimmingCharacters(in: .whitespaces)
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
                    var cleaned = StatusItemController.postProcessTranscript(text)
                    if !cleaned.isEmpty {
                        // Strip any trailing period whisper itself added. The
                        // Auto trailing period checkbox + its seconds field
                        // together are what govern whether a period appears
                        // and how long after injection it arrives. Preserving
                        // whisper's period would short-circuit the timer and
                        // let the period appear instantly in "Auto trailing
                        // period on" sessions, defeating the configured delay.
                        // Intra-sentence periods stay (so "I went to store.
                        // Then home" reads correctly) and trailing ? or ! stay
                        // (intonation-driven; losing them would change meaning
                        // and they're not what the timer is meant to add).
                        while cleaned.last == "." {
                            cleaned.removeLast()
                        }
                        cleaned = cleaned.trimmingCharacters(in: .whitespaces)
                        // Capitalize the first letter when the cursor is at a
                        // line start (fresh field, or immediately after a
                        // newline the user typed). When the cursor is mid-line
                        // the dictated text is being inserted into an existing
                        // sentence; keep it lowercase. On AX query failure
                        // (nil), default to capitalizing: dictation usually
                        // starts a new thought.
                        if Preferences.shared.capitalizeFirstLetterAtLineStart {
                            let atLineStart = CursorContext.isCursorAtLineStart()
                            if atLineStart != false {
                                cleaned = StatusItemController.capitalizeFirstAlphabetic(cleaned)
                            }
                        }
                        if !cleaned.isEmpty {
                            self?.textInjector.insert(cleaned)
                            self?.scheduleStandardTrailingPeriodIfNeeded(for: cleaned)
                        }
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
        presentAboutTab(startUpdateCheck: false)
    }

    @objc private func openHelp() {
        HelpWindowController.shared.show()
    }

    @objc private func checkForUpdates() {
        presentAboutTab(startUpdateCheck: true)
    }

    private func presentAboutTab(startUpdateCheck: Bool) {
        let controller = PreferencesWindowController.shared
        controller.onHotkeyChanged = { [weak self] in self?.applyHotkeySettings() }
        controller.onColoredIconChanged = { [weak self] in self?.refreshMenuBarIcon() }
        controller.onUpdateCheckResult = { [weak self] result in
            guard let self = self else { return }
            let skipped = Preferences.shared.skippedUpdateVersion
            switch result {
            case .updateAvailable(_, let latest, _, _):
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
        }
        controller.onUpdateSkipped = { [weak self] latest in
            guard let self = self else { return }
            Preferences.shared.skippedUpdateVersion = latest
            self.pendingUpdateVersion = nil
            self.refreshUpdatesMenuItem()
            self.refreshMenuBarIcon()
        }
        controller.showAbout(startUpdateCheck: startUpdateCheck)
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
