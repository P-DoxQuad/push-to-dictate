import Cocoa

final class UpdateCheckWindowController: NSWindowController {

    private let statusLabel = NSTextField(frame: .zero)
    private let detailLabel = NSTextField(frame: .zero)
    private let spinner = NSProgressIndicator(frame: .zero)
    private let primaryButton = NSButton(frame: .zero)
    private let tertiaryButton = NSButton(frame: .zero)
    private let secondaryButton = NSButton(frame: .zero)

    private var releaseURL: URL?
    private var latestVersion: String?
    private var onResult: ((UpdateCheckResult) -> Void)?
    private var onSkip: ((String) -> Void)?

    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 180),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false)
        window.title = "Software Update"
        window.isReleasedWhenClosed = false
        self.init(window: window)
        buildLayout()
    }

    private static var active: UpdateCheckWindowController?

    static func present(onResult: ((UpdateCheckResult) -> Void)? = nil,
                        onSkip: ((String) -> Void)? = nil) {
        if let existing = active {
            existing.window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let controller = UpdateCheckWindowController()
        controller.onResult = onResult
        controller.onSkip = onSkip
        active = controller
        controller.showWindow(nil)
        controller.window?.center()
        NSApp.activate(ignoringOtherApps: true)
        controller.startCheck()
    }

    private func buildLayout() {
        guard let content = window?.contentView else { return }

        statusLabel.isEditable = false; statusLabel.isSelectable = false
        statusLabel.isBordered = false; statusLabel.drawsBackground = false
        statusLabel.font = NSFont.boldSystemFont(ofSize: 14)
        statusLabel.stringValue = "Checking for updates…"
        statusLabel.alignment = .center

        detailLabel.isEditable = false; detailLabel.isSelectable = false
        detailLabel.isBordered = false; detailLabel.drawsBackground = false
        detailLabel.font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.lineBreakMode = .byWordWrapping
        detailLabel.cell?.wraps = true
        detailLabel.cell?.isScrollable = false
        detailLabel.preferredMaxLayoutWidth = 320
        detailLabel.alignment = .center
        detailLabel.stringValue = ""

        spinner.style = .spinning
        spinner.isIndeterminate = true
        spinner.controlSize = .small
        spinner.startAnimation(nil)

        primaryButton.bezelStyle = .rounded
        primaryButton.title = "OK"
        primaryButton.target = self
        primaryButton.action = #selector(closeWindow)
        primaryButton.isHidden = true

        secondaryButton.bezelStyle = .rounded
        secondaryButton.title = "Later"
        secondaryButton.target = self
        secondaryButton.action = #selector(closeWindow)
        secondaryButton.isHidden = true

        tertiaryButton.bezelStyle = .rounded
        tertiaryButton.title = "Skip This Update"
        tertiaryButton.target = self
        tertiaryButton.action = #selector(skipUpdate)
        tertiaryButton.isHidden = true

        let buttonRow = NSStackView(views: [secondaryButton, tertiaryButton, primaryButton])
        buttonRow.orientation = .horizontal
        buttonRow.spacing = 10

        let stack = NSStackView(views: [statusLabel, spinner, detailLabel, buttonRow])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 22, left: 24, bottom: 22, right: 24)
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            detailLabel.widthAnchor.constraint(equalToConstant: 320)
        ])
    }

    private func startCheck() {
        UpdateChecker.checkForUpdates { [weak self] result in
            self?.render(result: result)
        }
    }

    private func render(result: UpdateCheckResult) {
        onResult?(result)
        spinner.stopAnimation(nil)
        spinner.isHidden = true

        switch result {
        case .upToDate(let current):
            statusLabel.stringValue = "Up to date."
            detailLabel.stringValue = "Installed version: \(current)"
            primaryButton.title = "OK"
            primaryButton.action = #selector(closeWindow)
            primaryButton.isHidden = false
            secondaryButton.isHidden = true
            tertiaryButton.isHidden = true

        case .updateAvailable(let current, let latest, let url):
            releaseURL = url
            latestVersion = latest
            statusLabel.stringValue = "Update available: \(latest)"
            detailLabel.stringValue = "Installed version: \(current)"
            primaryButton.title = "Open Releases Page"
            primaryButton.action = #selector(openReleasesPage)
            primaryButton.isHidden = false
            secondaryButton.title = "Later"
            secondaryButton.action = #selector(closeWindow)
            secondaryButton.isHidden = false
            tertiaryButton.isHidden = false

        case .error(let message):
            statusLabel.stringValue = "Couldn't check for updates."
            detailLabel.stringValue = message
            primaryButton.title = "OK"
            primaryButton.action = #selector(closeWindow)
            primaryButton.isHidden = false
            secondaryButton.isHidden = true
            tertiaryButton.isHidden = true
        }

        window?.makeFirstResponder(primaryButton)
    }

    @objc private func openReleasesPage() {
        if let url = releaseURL {
            NSWorkspace.shared.open(url)
        }
        closeWindow()
    }

    @objc private func skipUpdate() {
        if let latest = latestVersion {
            onSkip?(latest)
        }
        closeWindow()
    }

    @objc private func closeWindow() {
        window?.close()
        UpdateCheckWindowController.active = nil
    }
}
