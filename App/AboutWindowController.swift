import Cocoa

final class AboutWindowController: NSWindowController {
    static let shared = AboutWindowController()

    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 480),
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
        let version = (info?["PQDisplayVersion"] as? String) ?? "1.1"
        let appIcon = NSApp.applicationIconImage ?? NSImage(named: "push-to-dictate")
            ?? NSImage(size: NSSize(width: 128, height: 128))

        let iconView = NSImageView()
        iconView.image = appIcon
        iconView.imageScaling = .scaleProportionallyUpOrDown

        let nameLabel = NSTextField(frame: .zero)
        nameLabel.isEditable = false; nameLabel.isSelectable = false
        nameLabel.isBordered = false; nameLabel.drawsBackground = false
        nameLabel.stringValue = "Push to Dictate"
        nameLabel.font = NSFont.boldSystemFont(ofSize: 20)
        nameLabel.alignment = .center

        let versionLabel = NSTextField(frame: .zero)
        versionLabel.isEditable = false; versionLabel.isSelectable = false
        versionLabel.isBordered = false; versionLabel.drawsBackground = false
        versionLabel.stringValue = "Version \(version)"
        versionLabel.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        versionLabel.textColor = .secondaryLabelColor
        versionLabel.alignment = .center

        let description = NSTextField(frame: .zero)
        description.isEditable = false; description.isSelectable = false
        description.isBordered = false; description.drawsBackground = false
        description.stringValue = "A menu-bar dictation app for conventional computers. "
            + "Works offline. No hardware acceleration required."
        description.lineBreakMode = .byWordWrapping
        description.cell?.wraps = true
        description.cell?.isScrollable = false
        description.preferredMaxLayoutWidth = 360
        description.alignment = .center
        description.font = NSFont.systemFont(ofSize: NSFont.systemFontSize)

        let credits = NSTextField(frame: .zero)
        credits.isEditable = false; credits.isSelectable = false
        credits.isBordered = false; credits.drawsBackground = false
        credits.stringValue = "Transcription uses Whisper, OpenAI's open-source speech "
            + "recognition model, adapted by whisper.cpp to run on CPU instead of GPU."
        credits.lineBreakMode = .byWordWrapping
        credits.cell?.wraps = true
        credits.cell?.isScrollable = false
        credits.preferredMaxLayoutWidth = 360
        credits.alignment = .center
        credits.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        credits.textColor = .secondaryLabelColor

        let authorLabel = NSTextField(frame: .zero)
        authorLabel.isEditable = false; authorLabel.isSelectable = false
        authorLabel.isBordered = false; authorLabel.drawsBackground = false
        authorLabel.stringValue = "by Paradoxical Quad"
        authorLabel.font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
        authorLabel.alignment = .center

        let copyright = NSTextField(frame: .zero)
        copyright.isEditable = false; copyright.isSelectable = false
        copyright.isBordered = false; copyright.drawsBackground = false
        copyright.stringValue = "© 2026 Paradoxical Quad"
        copyright.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        copyright.textColor = .secondaryLabelColor
        copyright.alignment = .center

        let spacer1 = NSView()
        spacer1.translatesAutoresizingMaskIntoConstraints = false
        spacer1.heightAnchor.constraint(equalToConstant: 8).isActive = true
        let spacer2 = NSView()
        spacer2.translatesAutoresizingMaskIntoConstraints = false
        spacer2.heightAnchor.constraint(equalToConstant: 8).isActive = true
        let spacer3 = NSView()
        spacer3.translatesAutoresizingMaskIntoConstraints = false
        spacer3.heightAnchor.constraint(equalToConstant: 8).isActive = true
        let spacer4 = NSView()
        spacer4.translatesAutoresizingMaskIntoConstraints = false
        spacer4.heightAnchor.constraint(equalToConstant: 4).isActive = true

        let updateButton = NSButton()
        updateButton.bezelStyle = .rounded
        updateButton.title = "Check for Updates…"
        updateButton.target = self
        updateButton.action = #selector(checkForUpdates)

        let stack = NSStackView(views: [
            iconView,
            spacer1,
            nameLabel, versionLabel, authorLabel,
            spacer2,
            description,
            spacer3,
            credits, copyright,
            spacer4,
            updateButton
        ])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 8
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

    @objc private func checkForUpdates() {
        UpdateCheckWindowController.present()
    }
}
