import Cocoa

final class AboutWindowController: NSWindowController {
    static let shared = AboutWindowController()

    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 440),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false)
        window.title = "About Push to Dictate"
        window.isReleasedWhenClosed = false
        self.init(window: window)
        buildLayout()
    }

    func show() {
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func buildLayout() {
        guard let content = window?.contentView else { return }

        let info = Bundle.main.infoDictionary
        let version = (info?["CFBundleShortVersionString"] as? String) ?? "1.0"
        let appIcon = NSApp.applicationIconImage ?? NSImage(named: "push-to-dictate")
            ?? NSImage(size: NSSize(width: 128, height: 128))

        let iconView = NSImageView()
        iconView.image = appIcon
        iconView.imageScaling = .scaleProportionallyUpOrDown

        let nameLabel = NSTextField(labelWithString: "Push to Dictate")
        nameLabel.font = NSFont.boldSystemFont(ofSize: 20)
        nameLabel.alignment = .center

        let versionLabel = NSTextField(labelWithString: "Version \(version)")
        versionLabel.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        versionLabel.textColor = .secondaryLabelColor
        versionLabel.alignment = .center

        let description = NSTextField(wrappingLabelWithString:
            "A menu-bar dictation app for conventional computers. Works offline. "
            + "No hardware acceleration required.")
        description.alignment = .center
        description.font = NSFont.systemFont(ofSize: NSFont.systemFontSize)

        let credits = NSTextField(wrappingLabelWithString:
            "Transcription uses Whisper, OpenAI's open-source speech recognition "
            + "model, adapted by whisper.cpp to run on CPU instead of GPU.")
        credits.alignment = .center
        credits.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        credits.textColor = .secondaryLabelColor

        let authorLabel = NSTextField(labelWithString: "by Paradoxical Quad")
        authorLabel.font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
        authorLabel.alignment = .center

        let copyright = NSTextField(labelWithString: "© 2026 Paradoxical Quad")
        copyright.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        copyright.textColor = .secondaryLabelColor
        copyright.alignment = .center

        let stack = NSStackView(views: [
            iconView, nameLabel, versionLabel, authorLabel,
            description, credits, copyright
        ])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 8
        stack.setCustomSpacing(16, after: iconView)
        stack.setCustomSpacing(16, after: authorLabel)
        stack.setCustomSpacing(16, after: description)
        stack.edgeInsets = NSEdgeInsets(top: 24, left: 24, bottom: 24, right: 24)
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 128),
            iconView.heightAnchor.constraint(equalToConstant: 128),
            description.widthAnchor.constraint(equalToConstant: 360),
            credits.widthAnchor.constraint(equalToConstant: 360)
        ])
    }
}
