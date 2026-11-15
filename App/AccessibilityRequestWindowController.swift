import Cocoa

final class AccessibilityRequestWindowController: NSWindowController {

    static private(set) var active: AccessibilityRequestWindowController?

    private let statusLabel = NSTextField(frame: .zero)
    private let bodyLabel = NSTextField(frame: .zero)
    private let primaryButton = NSButton(frame: .zero)
    private let secondaryButton = NSButton(frame: .zero)
    private var pollTimer: Timer?
    private var onTrustGranted: (() -> Bool)?
    private var onMenuShouldRefresh: (() -> Void)?

    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 240),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false)
        window.title = "Accessibility Access"
        window.isReleasedWhenClosed = false
        self.init(window: window)
        buildLayout()
    }

    // onTrustGranted: called on the main thread when AXIsProcessTrusted() flips to true.
    //   Should attempt in-place re-init of the event tap and return true if it succeeded.
    // onMenuShouldRefresh: called when the window closes (grant or dismiss) so the
    //   status menu can re-evaluate whether to show its "Request Accessibility…" item.
    static func present(onTrustGranted: @escaping () -> Bool,
                        onMenuShouldRefresh: @escaping () -> Void) {
        if let existing = active {
            existing.window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let controller = AccessibilityRequestWindowController()
        controller.onTrustGranted = onTrustGranted
        controller.onMenuShouldRefresh = onMenuShouldRefresh
        active = controller
        controller.showWindow(nil)
        controller.window?.center()
        NSApp.activate(ignoringOtherApps: true)
        onMenuShouldRefresh()
        controller.startPolling()
    }

    private func buildLayout() {
        guard let content = window?.contentView else { return }

        statusLabel.isEditable = false; statusLabel.isSelectable = false
        statusLabel.isBordered = false; statusLabel.drawsBackground = false
        statusLabel.font = NSFont.boldSystemFont(ofSize: 14)
        statusLabel.alignment = .center
        statusLabel.stringValue = "Accessibility access required"

        bodyLabel.isEditable = false; bodyLabel.isSelectable = false
        bodyLabel.isBordered = false; bodyLabel.drawsBackground = false
        bodyLabel.font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
        bodyLabel.textColor = .secondaryLabelColor
        bodyLabel.lineBreakMode = .byWordWrapping
        bodyLabel.cell?.wraps = true
        bodyLabel.cell?.isScrollable = false
        bodyLabel.preferredMaxLayoutWidth = 420
        bodyLabel.alignment = .center
        bodyLabel.stringValue = "Push to Dictate needs Accessibility access to listen for its "
            + "global hotkey and to insert transcribed text into other apps.\n\n"
            + "Open System Preferences, add Push to Dictate to the Accessibility list, "
            + "then check the box. This window will update automatically once access is granted."

        primaryButton.bezelStyle = .rounded
        primaryButton.title = "Open Accessibility Preferences"
        primaryButton.target = self
        primaryButton.action = #selector(openAccessibilityPreferences)

        secondaryButton.bezelStyle = .rounded
        secondaryButton.title = "Later"
        secondaryButton.target = self
        secondaryButton.action = #selector(dismiss)

        let buttonRow = NSStackView(views: [secondaryButton, primaryButton])
        buttonRow.orientation = .horizontal
        buttonRow.spacing = 10

        let stack = NSStackView(views: [statusLabel, bodyLabel, buttonRow])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 14
        stack.edgeInsets = NSEdgeInsets(top: 22, left: 24, bottom: 22, right: 24)
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            bodyLabel.widthAnchor.constraint(equalToConstant: 420)
        ])
    }

    private func startPolling() {
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(
            timeInterval: 1.0,
            target: self,
            selector: #selector(pollTick),
            userInfo: nil,
            repeats: true)
    }

    private func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    @objc private func pollTick() {
        guard HotkeyMonitor.hasAccessibilityPermission() else { return }
        stopPolling()
        handleTrustGranted()
    }

    private func handleTrustGranted() {
        let succeeded = onTrustGranted?() ?? false
        if succeeded {
            showGrantedState()
        } else {
            showRestartRequiredState()
        }
    }

    private func showGrantedState() {
        statusLabel.stringValue = "You're all set."
        bodyLabel.stringValue = "Accessibility access was granted. The hotkey is active."
        primaryButton.title = "Done"
        primaryButton.action = #selector(dismiss)
        secondaryButton.isHidden = true
    }

    private func showRestartRequiredState() {
        statusLabel.stringValue = "Accessibility access granted"
        bodyLabel.stringValue = "Restarting Push to Dictate to finish applying the permission…"
        primaryButton.isHidden = true
        secondaryButton.isHidden = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) { [weak self] in
            self?.restartApp()
        }
    }

    @objc private func openAccessibilityPreferences() {
        if let url = URL(string:
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func restartApp() {
        let bundlePath = Bundle.main.bundlePath
        let task = Process()
        task.launchPath = "/bin/sh"
        task.arguments = ["-c", "sleep 1; open '\(bundlePath)'"]
        task.launch()
        NSApp.terminate(nil)
    }

    @objc private func dismiss() {
        stopPolling()
        window?.close()
        AccessibilityRequestWindowController.active = nil
        onMenuShouldRefresh?()
    }
}
