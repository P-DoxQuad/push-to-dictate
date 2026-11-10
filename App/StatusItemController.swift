import Cocoa

final class StatusItemController: NSObject {
    private let statusItem: NSStatusItem
    private var isRecording = false

    override init() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        configureButton()
        statusItem.menu = buildMenu()
    }

    private func configureButton() {
        guard let button = statusItem.button else { return }
        button.title = "\u{25CB}"
        button.toolTip = "push-to-dictate"
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()

        let toggle = NSMenuItem(title: "Start Dictation",
                                action: #selector(toggleDictation),
                                keyEquivalent: "")
        toggle.target = self
        menu.addItem(toggle)

        menu.addItem(NSMenuItem.separator())

        let modeItem = NSMenuItem(title: "Mode", action: nil, keyEquivalent: "")
        let modeSubmenu = NSMenu()
        let toggleMode = NSMenuItem(title: "Toggle",
                                    action: #selector(selectToggleMode),
                                    keyEquivalent: "")
        toggleMode.target = self
        toggleMode.state = .on
        let pttMode = NSMenuItem(title: "Push-to-talk",
                                 action: #selector(selectPushToTalkMode),
                                 keyEquivalent: "")
        pttMode.target = self
        modeSubmenu.addItem(toggleMode)
        modeSubmenu.addItem(pttMode)
        modeItem.submenu = modeSubmenu
        menu.addItem(modeItem)

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

    @objc private func toggleDictation() {
        isRecording.toggle()
        statusItem.button?.title = isRecording ? "\u{25CF}" : "\u{25CB}"
    }

    @objc private func selectToggleMode() {}
    @objc private func selectPushToTalkMode() {}
    @objc private func openPreferences() {}
}
