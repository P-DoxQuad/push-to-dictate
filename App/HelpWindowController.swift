import Cocoa
import CoreGraphics

final class HelpWindowController: NSWindowController {
    static let shared = HelpWindowController()

    private weak var textView: NSTextView?

    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 540),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false)
        window.title = "Push to Dictate Help"
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 420, height: 320)
        self.init(window: window)
        build()
    }

    func show() {
        textView?.textStorage?.setAttributedString(HelpWindowController.helpContent())
        if let w = window { AppearanceManager.shared.applyToWindow(w) }
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func build() {
        guard let content = window?.contentView else { return }

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.borderType = .noBorder
        scroll.drawsBackground = false
        scroll.autohidesScrollers = true
        scroll.translatesAutoresizingMaskIntoConstraints = false

        let text = NSTextView()
        text.isEditable = false
        text.isSelectable = true
        text.isRichText = true
        text.drawsBackground = false
        text.textContainerInset = NSSize(width: 20, height: 20)
        text.textContainer?.widthTracksTextView = true
        text.isVerticallyResizable = true
        text.isHorizontallyResizable = false
        text.autoresizingMask = [.width]
        text.textStorage?.setAttributedString(HelpWindowController.helpContent())
        textView = text

        scroll.documentView = text

        let closeButton = NSButton(frame: .zero)
        closeButton.bezelStyle = .rounded
        closeButton.title = "Close"
        closeButton.keyEquivalent = "\r"
        closeButton.target = self
        closeButton.action = #selector(closeHelp)
        closeButton.translatesAutoresizingMaskIntoConstraints = false

        content.addSubview(scroll)
        content.addSubview(closeButton)

        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: content.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: closeButton.topAnchor, constant: -12),
            closeButton.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            closeButton.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16)
        ])
    }

    @objc private func closeHelp() {
        window?.close()
    }

    // MARK: - Content

    private static func helpContent() -> NSAttributedString {
        let out = NSMutableAttributedString()

        append(out, heading: "Permissions")
        append(out, body:
            "Push to Dictate requires **Accessibility** access to receive its global " +
            "hotkey system-wide and to insert transcribed text into other applications. " +
            "The app prompts for this permission on first launch and provides a direct " +
            "link to System Preferences → Security & Privacy → Privacy → Accessibility.")
        append(out, body:
            "On macOS 10.14 and newer, the system also presents a **Microphone** " +
            "permission prompt the first time audio capture is started. Both permissions " +
            "must be granted before dictation can function.")

        append(out, heading: "Starting and stopping dictation")
        append(out, body:
            "The current hotkey is **" + currentHotkeyVerbose() + "**.")
        append(out, body:
            "**Toggle mode** (default): pressing the hotkey once begins recording, and " +
            "pressing it a second time stops recording. The transcribed text is inserted " +
            "into whichever field currently has keyboard focus.")
        append(out, body:
            "**Push-to-Talk mode**: the hotkey must be held down while speaking. " +
            "Releasing the key stops recording and begins transcription.")
        append(out, body:
            "The active mode can be changed at any time from the menu bar icon under the " +
            "**Mode** submenu.")

        append(out, heading: "Changing the hotkey")
        append(out, body:
            "The hotkey can be reassigned in Preferences → General → Startup & Shortcut. " +
            "Click the **Hotkey** button and press the desired key combination. At least " +
            "one modifier key is required (⌃ Control, ⌥ Option, ⇧ Shift, or ⌘ Command), " +
            "unless the chosen key is one of the function keys F1 through F20, which may " +
            "be used without a modifier.")

        append(out, heading: "Continuous dictation")
        append(out, annotation: "Experimental.")
        append(out, body:
            "Continuous dictation mode, enabled in Preferences → Transcription → " +
            "Behavior, transcribes speech as it is being spoken, streaming text into the " +
            "active field in chunks rather than waiting for the recording to finish. This " +
            "mode is available only when Toggle mode is active, because Push-to-Talk mode " +
            "ends the session the moment the hotkey is released.")
        append(out, body:
            "The following settings govern how the app decides where one phrase ends and " +
            "the next begins.")
        append(out, bullet:
            "**Sentence pause** (default: 1.0 seconds). The minimum length of silence " +
            "that must occur before the current phrase is sent for transcription. A " +
            "pause of at least this length also ends a sentence, so the next phrase " +
            "begins with a period and a capital letter.")
        append(out, bullet:
            "**Window threshold** (default: 2.5 seconds). The maximum length of pause " +
            "still treated as a sentence break. Pauses longer than this value are " +
            "treated as an interruption, and the next phrase continues without an " +
            "inserted period or capital letter.")
        append(out, bullet:
            "**Max chunk** (default: 5.0 seconds, range 5 to 50). The maximum length of " +
            "a single transcription chunk. Continuous speech without a qualifying pause " +
            "is cut at this duration and sent for transcription.")
        append(out, bullet:
            "**Chunk overlap** (default: 0.3 seconds, range 0 to 1.5). Preserves a brief " +
            "tail of audio across Max chunk cuts and prepends it to the next chunk, so " +
            "the word at the boundary retains full context on at least one side. Setting " +
            "this value to 0 disables overlap entirely.")

        append(out, heading: "Audio input")
        append(out, body:
            "The system default microphone is used for recording unless a different " +
            "input device is selected in Preferences → Audio. The sounds played when " +
            "recording starts and stops can also be configured from the same pane, or " +
            "disabled entirely.")

        append(out, heading: "Silence detection and automatic stop")
        append(out, body:
            "The settings in Preferences → Audio → Silence Detection control how the app " +
            "identifies silence in the microphone signal.")
        append(out, bullet:
            "**Silence level** (default: 0.0100). The root-mean-square loudness " +
            "threshold below which microphone input is classified as silence. A lower " +
            "value treats quieter sounds as speech; a higher value treats only louder " +
            "audio as speech.")
        append(out, bullet:
            "**Auto stop**, when enabled, ends standard-mode recording automatically " +
            "after the microphone has been silent continuously for the duration set in " +
            "**Silence duration** (default: 4.0 seconds). The same silence threshold " +
            "also drives chunk detection in continuous dictation.")

        append(out, heading: "Transcription backend")
        append(out, body:
            "The transcription engine is selected in Preferences → Transcription → " +
            "Backend.")
        append(out, bullet:
            "**whisper.cpp (local)**. Runs the transcription engine on the local " +
            "computer's CPU. Audio does not leave the machine, the app works without an " +
            "internet connection, and there is no ongoing cost.")
        append(out, bullet:
            "**OpenAI API**. Sends the audio to OpenAI's servers for transcription. " +
            "Requires a paid OpenAI API key. Billed per minute of audio.")

        append(out, heading: "Transcription models")
        append(out, body:
            "Two speech models are bundled inside the app: `tiny.en`, the fastest, and " +
            "`base.en`, the default, which balances speed and accuracy. Additional model " +
            "sizes can be obtained from Preferences → Transcription → Manage Models. " +
            "Each entry in that window shows a rating of **Recommended**, **Slow**, or " +
            "**Not recommended** based on the local machine's processor capabilities. " +
            "Click the **Use** button next to any downloaded or bundled model to make it " +
            "the active model.")
        append(out, body:
            "The Manage Models window also accepts a direct URL for any whisper.cpp " +
            "model file in the `ggml` format. Downloaded files are saved to the models " +
            "folder, which defaults to " +
            "`~/Library/Application Support/push-to-dictate/models/`.")

        append(out, heading: "Text insertion")
        append(out, body:
            "The method by which transcribed text is inserted into the active field is " +
            "selected in Preferences → Output → Text Insertion.")
        append(out, bullet:
            "**Paste** (default). Copies the transcribed text to the clipboard and " +
            "performs a paste operation. Fast and reliable in most applications. " +
            "Overwrites current clipboard contents. A small number of applications block " +
            "programmatic paste.")
        append(out, bullet:
            "**Typed**. Simulates keyboard keystrokes one character at a time. Slower " +
            "than pasting. Works in applications that block paste, such as some " +
            "terminals, games, and sandboxed applications. The delay between keystrokes " +
            "is set by **Typed delay** (default: 8 milliseconds, range 5 to 100), which " +
            "should be increased if typed output contains missing or garbled characters.")

        append(out, heading: "Sentence handling")
        append(out, body:
            "The settings in Preferences → Output → Sentence Handling control how " +
            "sentences are finalized at the end of a dictation.")
        append(out, body:
            "When **Auto trailing period** is enabled, a period is appended to every " +
            "dictation that does not already end in a question mark or an exclamation " +
            "mark. The period is not inserted immediately; the app waits for the " +
            "duration set in **Trailing period** (default: 4.0 seconds). Starting a new " +
            "dictation within that window cancels the pending period, so the next phrase " +
            "continues the same sentence rather than starting a new one.")

        append(out, heading: "Performance")
        append(out, body:
            "The Preferences → Advanced → Performance section contains settings that " +
            "affect transcription speed and accuracy when using the local backend.")
        append(out, bullet:
            "**Transcription threads**. The number of worker threads used in parallel " +
            "during transcription. The maximum is the machine's logical processor count. " +
            "A recommended value is shown next to the field and is typically one-third " +
            "to one-half of the maximum. Running at the maximum will make the rest of " +
            "the system feel sluggish during transcription.")
        append(out, bullet:
            "**Accuracy** (beam size, default: 3, range 1 to 10). The number of " +
            "candidate word interpretations the speech engine evaluates for each audio " +
            "segment. A higher value produces more accurate transcription at the cost of " +
            "speed. A lower value is faster but more likely to confuse similar-sounding " +
            "words.")

        append(out, heading: "Appearance")
        append(out, body:
            "When **Use colored menu bar icon**, in Preferences → General → Appearance, " +
            "is enabled, the menu bar icon is displayed in its native colors regardless " +
            "of whether the system is in light or dark mode. When this option is " +
            "disabled, the icon follows the current system appearance, appearing black " +
            "in light mode and white in dark mode.")

        append(out, heading: "Launch at login")
        append(out, body:
            "When **Launch at login**, in Preferences → General → Startup & Shortcut, " +
            "is enabled, Push to Dictate starts automatically each time the current user " +
            "logs in. This is implemented by installing a small plist file into " +
            "`~/Library/LaunchAgents/`.")

        append(out, heading: "Backup and restore")
        append(out, body:
            "The Preferences → General → Settings section provides **Export** and " +
            "**Import** buttons for saving and restoring the full set of preferences. " +
            "The exported file is a standard `.plist` file and includes the OpenAI API " +
            "key, which is retrieved from the Keychain for export purposes, as well as " +
            "the launch-at-login setting. The Import button reads a previously exported " +
            "file and applies every setting it contains.")

        append(out, heading: "Updates")
        append(out, body:
            "The Preferences → Updates section controls how the app checks for new " +
            "releases on GitHub. When **Check for updates** is enabled, the app performs " +
            "a background check at the frequency selected in the **Frequency** dropdown, " +
            "either at every startup or once per day. No files are downloaded " +
            "automatically; when a new release is detected, the menu bar icon shows a " +
            "small badge to indicate that an update is available.")
        append(out, body:
            "The **Release history** section of the same pane fetches the full list of " +
            "releases on demand and displays each one in a table. A selected release can " +
            "be downloaded and installed in place using the **Download & install** " +
            "button, which also triggers an automatic relaunch of the application once " +
            "installation is complete. The **Open release page** button opens the " +
            "selected release's page on GitHub in the default web browser.")
        append(out, body:
            "The **About** tab, located to the right of the Updates tab, shows the " +
            "installed version of the application and provides a button for running a " +
            "single update check on demand.")

        append(out, heading: "Diagnostics")
        append(out, body:
            "The Preferences → Advanced → Diagnostics section provides two logging " +
            "options for use when investigating problems.")
        append(out, bullet:
            "**Save debug recordings**. When enabled, every captured audio chunk is " +
            "written to disk as a WAV file, accompanied by a small sidecar text file " +
            "containing metadata about the chunk. These files are useful for diagnosing " +
            "transcription problems after the fact.")
        append(out, bullet:
            "**Log everything**. When enabled, the log is expanded to include " +
            "informational events in addition to errors. The log file is located at " +
            "`~/Library/Application Support/push-to-dictate/logs/push-to-dictate.log`.")

        append(out, heading: "Reset preferences")
        append(out, body:
            "The **Reset to defaults** button in Preferences → Advanced → Reset restores " +
            "every preference to its original value, including the hotkey assignment, " +
            "the transcription backend, and the selected model. The OpenAI API key, " +
            "which is stored in the Keychain rather than in the preferences file, is not " +
            "affected by this operation.")

        append(out, heading: "Troubleshooting")
        append(out, body:
            "If the hotkey stops responding, the first step is to verify that " +
            "Accessibility permission is still granted in System Preferences. Moving the " +
            "application to a new location invalidates the previous grant; the " +
            "permission must then be removed and re-added for the new location.")
        append(out, body:
            "Errors encountered during normal operation are written to " +
            "`~/Library/Application Support/push-to-dictate/logs/push-to-dictate.log`. " +
            "Enabling **Log everything** in Preferences → Advanced → Diagnostics " +
            "expands the log to include informational events, which can help in " +
            "diagnosing less obvious problems.",
            trailingNewline: false)

        return out
    }

    private static func append(_ dst: NSMutableAttributedString, heading: String) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.paragraphSpacingBefore = 16
        paragraph.paragraphSpacing = 6
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.boldSystemFont(ofSize: NSFont.systemFontSize + 2),
            .paragraphStyle: paragraph,
            .foregroundColor: NSColor.labelColor
        ]
        dst.append(NSAttributedString(string: heading + "\n", attributes: attrs))
    }

    private static func append(_ dst: NSMutableAttributedString,
                               body: String,
                               trailingNewline: Bool = true) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.paragraphSpacing = 10
        paragraph.lineSpacing = 2
        dst.append(renderInlines(body, paragraph: paragraph))
        if trailingNewline {
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: NSFont.systemFontSize),
                .paragraphStyle: paragraph,
                .foregroundColor: NSColor.labelColor
            ]
            dst.append(NSAttributedString(string: "\n", attributes: attrs))
        }
    }

    // Bulleted item with a hanging indent so wrapped lines align under the
    // text, not under the bullet glyph.
    private static func append(_ dst: NSMutableAttributedString, bullet: String) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.paragraphSpacing = 6
        paragraph.lineSpacing = 2
        paragraph.firstLineHeadIndent = 4
        paragraph.headIndent = 22
        let rendered = renderInlines("•   " + bullet + "\n", paragraph: paragraph)
        dst.append(rendered)
    }

    // Short annotation line (e.g. "Experimental.") set in bold.
    private static func append(_ dst: NSMutableAttributedString, annotation: String) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.paragraphSpacing = 6
        paragraph.lineSpacing = 2
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.boldSystemFont(ofSize: NSFont.systemFontSize),
            .paragraphStyle: paragraph,
            .foregroundColor: NSColor.labelColor
        ]
        dst.append(NSAttributedString(string: annotation + "\n", attributes: attrs))
    }

    // Parses `**bold**` and `` `code` `` inline markers in body text, applying
    // bold or monospace fonts to the enclosed runs. Marker characters are not
    // emitted. Unmatched markers are left in place as literal characters.
    private static func renderInlines(_ source: String,
                                      paragraph: NSParagraphStyle)
        -> NSMutableAttributedString {
        let bodyFont = NSFont.systemFont(ofSize: NSFont.systemFontSize)
        let boldFont = NSFont.boldSystemFont(ofSize: NSFont.systemFontSize)
        let monoFont = NSFont.userFixedPitchFont(ofSize: NSFont.systemFontSize - 1)
            ?? bodyFont
        func attrs(_ font: NSFont) -> [NSAttributedString.Key: Any] {
            return [
                .font: font,
                .paragraphStyle: paragraph,
                .foregroundColor: NSColor.labelColor
            ]
        }
        let out = NSMutableAttributedString()
        let chars = Array(source)
        var i = 0
        var buffer = ""
        func flushBuffer() {
            if buffer.isEmpty { return }
            out.append(NSAttributedString(string: buffer, attributes: attrs(bodyFont)))
            buffer = ""
        }
        while i < chars.count {
            if i + 1 < chars.count && chars[i] == "*" && chars[i + 1] == "*" {
                // find closing **
                var j = i + 2
                while j + 1 < chars.count {
                    if chars[j] == "*" && chars[j + 1] == "*" { break }
                    j += 1
                }
                if j + 1 < chars.count {
                    flushBuffer()
                    let inner = String(chars[(i + 2)..<j])
                    out.append(NSAttributedString(string: inner, attributes: attrs(boldFont)))
                    i = j + 2
                    continue
                }
            }
            if chars[i] == "`" {
                var j = i + 1
                while j < chars.count && chars[j] != "`" { j += 1 }
                if j < chars.count {
                    flushBuffer()
                    let inner = String(chars[(i + 1)..<j])
                    out.append(NSAttributedString(string: inner, attributes: attrs(monoFont)))
                    i = j + 1
                    continue
                }
            }
            buffer.append(chars[i])
            i += 1
        }
        flushBuffer()
        return out
    }

    private static func currentHotkey() -> String {
        return PreferencesWindowController.describe(
            keyCode: Preferences.shared.hotkeyKeyCode,
            flags: Preferences.shared.hotkeyModifierFlags
        )
    }

    private static func currentHotkeyVerbose() -> String {
        return PreferencesWindowController.describeVerbose(
            keyCode: Preferences.shared.hotkeyKeyCode,
            flags: Preferences.shared.hotkeyModifierFlags
        )
    }
}
