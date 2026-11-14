import Cocoa
import CoreGraphics

final class HelpWindowController: NSWindowController {
    static let shared = HelpWindowController()

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

        // Permissions first. Without them the hotkey does nothing.
        append(out, heading: "Permissions")
        append(out, body:
            "Accessibility is required so the global hotkey works and so the app can insert " +
            "text into other applications. The app prompts on first launch and deep-links to " +
            "System Preferences → Security & Privacy → Privacy → Accessibility.\n\n" +
            "On macOS 10.14 and newer, a Microphone permission prompt appears the first time " +
            "audio capture starts. Grant it for dictation to work.")

        append(out, heading: "Starting and stopping dictation")
        append(out, body:
            "Default hotkey: " + currentHotkey() + "\n\n" +
            "Toggle mode (default): tap the hotkey to start recording. Tap again to stop. " +
            "The transcribed text is inserted into whatever field currently has keyboard focus.\n\n" +
            "Push-to-talk mode: hold the hotkey while speaking. Release to transcribe.\n\n" +
            "Switch modes from the menu bar icon under Mode.")

        append(out, heading: "Changing the hotkey")
        append(out, body:
            "Click the menu bar icon and choose Preferences. In the General section, click " +
            "the Hotkey button and press the key combination you want. At least one modifier " +
            "(⌃ ⌥ ⇧ ⌘) is required unless you pick an F1–F20 key.")

        // The pipeline: audio in -> model -> backend -> text out.
        append(out, heading: "Audio input")
        append(out, body:
            "The system default microphone is used unless another input device is selected in " +
            "Preferences → Audio. Start and stop sounds are configurable there too.")

        append(out, heading: "Transcription models")
        append(out, body:
            "Two models ship inside the app: tiny.en (fastest) and base.en (default). " +
            "More sizes are available from Preferences → Transcription → Manage Models. " +
            "Each entry shows a Recommended / Slow / Not recommended rating based on your " +
            "Mac's CPU capabilities. Click Use to make a downloaded or bundled model active.\n\n" +
            "Manage Models also has a Download from URL field for any ggml-*.bin file you " +
            "can point at. Downloads land in the models folder (default: " +
            "~/Library/Application Support/push-to-dictate/models/).")

        append(out, heading: "Local or cloud")
        append(out, body:
            "The Backend selector in Preferences → Transcription chooses between whisper.cpp " +
            "running on your CPU (local, offline) and OpenAI's Whisper API (cloud, requires " +
            "a paid API key). The local backend is the default and needs no setup.")

        append(out, heading: "Text insertion")
        append(out, body:
            "Transcribed text is inserted into the focused field via synthesized paste (default) " +
            "or by typing each character (fallback for apps that block paste). Choose in " +
            "Preferences → Output.")

        // Convenience and power-user options.
        append(out, heading: "Launch at login")
        append(out, body:
            "Preferences → General → Startup. When enabled, the app launches automatically at " +
            "each user login via a plist dropped into ~/Library/LaunchAgents/.")

        append(out, heading: "Backup and restore")
        append(out, body:
            "Preferences → General → Backup exports every preference to a .plist file, " +
            "including the OpenAI API key (read from the Keychain) and the launch-at-login " +
            "setting. Import restores from that file.")

        append(out, heading: "Troubleshooting")
        append(out, body:
            "Errors are logged to ~/Library/Application Support/push-to-dictate/logs/push-to-dictate.log. " +
            "Toggle Log everything in Preferences → Advanced to capture informational events as well. " +
            "If the hotkey stops responding, verify Accessibility permission is still granted. " +
            "Moving the app to a new location invalidates the previous grant.",
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
        paragraph.paragraphSpacing = 4
        paragraph.lineSpacing = 2
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: NSFont.systemFontSize),
            .paragraphStyle: paragraph,
            .foregroundColor: NSColor.labelColor
        ]
        let suffix = trailingNewline ? "\n" : ""
        dst.append(NSAttributedString(string: body + suffix, attributes: attrs))
    }

    private static func currentHotkey() -> String {
        return PreferencesWindowController.describe(
            keyCode: Preferences.shared.hotkeyKeyCode,
            flags: Preferences.shared.hotkeyModifierFlags
        )
    }
}
