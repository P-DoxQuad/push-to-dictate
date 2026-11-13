import Cocoa
import CoreGraphics

final class PreferencesWindowController: NSWindowController, NSTextFieldDelegate {
    static let shared = PreferencesWindowController()

    var onHotkeyChanged: (() -> Void)?

    private let hotkeyButton = NSButton(title: "", target: nil, action: nil)
    private let hotkeyStatusLabel = NSTextField(labelWithString: "")
    private let backendPopup = NSPopUpButton()
    private let modelPopup = NSPopUpButton()
    private let injectionPasteRadio = NSButton(radioButtonWithTitle: "Paste",
                                               target: nil, action: nil)
    private let injectionTypedRadio = NSButton(radioButtonWithTitle: "Typed",
                                               target: nil, action: nil)
    private let inputDevicePopup = NSPopUpButton()
    private let apiKeyField = NSSecureTextField()

    private var inputDevices: [(uid: String, name: String)] = []
    private var hotkeyMonitor: Any?
    private var isRecordingHotkey = false

    private var grid: NSGridView!
    private let modelRowIndex = 2
    private let apiKeyRowIndex = 3

    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 260),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "push-to-dictate — Preferences"
        window.isReleasedWhenClosed = false
        self.init(window: window)
        buildLayout()
        refreshAll()
    }

    func showPreferences() {
        if let window = window {
            window.center()
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    override func close() {
        stopRecordingHotkey()
        super.close()
    }

    // MARK: - Layout

    private func buildLayout() {
        guard let contentView = window?.contentView else { return }

        let hotkeyLabel = NSTextField(labelWithString: "Hotkey:")
        let backendLabel = NSTextField(labelWithString: "Backend:")
        let modelLabel = NSTextField(labelWithString: "Local model:")
        let apiKeyLabel = NSTextField(labelWithString: "OpenAI API key:")
        let injectionLabel = NSTextField(labelWithString: "Text insertion:")
        let inputDeviceLabel = NSTextField(labelWithString: "Input device:")

        hotkeyButton.bezelStyle = .rounded
        hotkeyButton.target = self
        hotkeyButton.action = #selector(hotkeyButtonClicked)

        hotkeyStatusLabel.font = NSFont.systemFont(ofSize: 11)
        hotkeyStatusLabel.textColor = .secondaryLabelColor

        backendPopup.target = self
        backendPopup.action = #selector(backendChanged)
        backendPopup.addItems(withTitles: ["whisper.cpp (local)", "OpenAI API"])

        modelPopup.target = self
        modelPopup.action = #selector(modelChanged)

        injectionPasteRadio.target = self
        injectionPasteRadio.action = #selector(injectionPasteSelected)
        injectionTypedRadio.target = self
        injectionTypedRadio.action = #selector(injectionTypedSelected)
        let injectionStack = NSStackView(views: [injectionPasteRadio, injectionTypedRadio])
        injectionStack.orientation = .horizontal
        injectionStack.spacing = 16

        inputDevicePopup.target = self
        inputDevicePopup.action = #selector(inputDeviceChanged)

        apiKeyField.placeholderString = "sk-..."
        apiKeyField.delegate = self

        grid = NSGridView(views: [
            [hotkeyLabel,      hotkeyButton,     hotkeyStatusLabel],
            [backendLabel,     backendPopup,     NSView()],
            [modelLabel,       modelPopup,       NSView()],
            [apiKeyLabel,      apiKeyField,      NSView()],
            [injectionLabel,   injectionStack,   NSView()],
            [inputDeviceLabel, inputDevicePopup, NSView()]
        ])
        grid.rowSpacing = 12
        grid.columnSpacing = 10
        grid.column(at: 0).xPlacement = .trailing
        grid.translatesAutoresizingMaskIntoConstraints = false

        contentView.addSubview(grid)
        NSLayoutConstraint.activate([
            grid.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            grid.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),
            grid.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 20),
            grid.bottomAnchor.constraint(lessThanOrEqualTo: contentView.bottomAnchor, constant: -20),
            apiKeyField.widthAnchor.constraint(greaterThanOrEqualToConstant: 260)
        ])
    }

    // MARK: - Refresh from Preferences

    private func refreshAll() {
        refreshHotkeyButton()
        hotkeyStatusLabel.stringValue = ""
        refreshBackendPopup()
        refreshModelPopup()
        refreshInjectionPopup()
        refreshInputDevicePopup()
        apiKeyField.stringValue = Preferences.shared.openAIAPIKey
        updateConditionalRows()
    }

    private func updateConditionalRows() {
        let isOpenAI = Preferences.shared.backend == .openAI
        grid.row(at: modelRowIndex).isHidden = isOpenAI
        grid.row(at: apiKeyRowIndex).isHidden = !isOpenAI
    }

    private func refreshBackendPopup() {
        switch Preferences.shared.backend {
        case .whisperCpp: backendPopup.selectItem(at: 0)
        case .openAI:     backendPopup.selectItem(at: 1)
        }
    }

    private func refreshInputDevicePopup() {
        inputDevicePopup.removeAllItems()
        inputDevicePopup.addItem(withTitle: "System default")
        inputDevices = AudioRecorder.availableInputDevices()
        for device in inputDevices {
            inputDevicePopup.addItem(withTitle: device.name)
        }
        let current = Preferences.shared.inputDeviceUID
        if current.isEmpty {
            inputDevicePopup.selectItem(at: 0)
        } else if let idx = inputDevices.firstIndex(where: { $0.uid == current }) {
            inputDevicePopup.selectItem(at: idx + 1)
        } else {
            inputDevicePopup.selectItem(at: 0)
        }
    }

    private func refreshHotkeyButton() {
        let prefs = Preferences.shared
        hotkeyButton.title = PreferencesWindowController.describe(
            keyCode: prefs.hotkeyKeyCode,
            flags: prefs.hotkeyModifierFlags
        )
    }

    private func refreshModelPopup() {
        modelPopup.removeAllItems()
        let models = discoverModels()
        if models.isEmpty {
            modelPopup.addItem(withTitle: "(no models found)")
            modelPopup.isEnabled = false
            return
        }
        modelPopup.isEnabled = true
        for name in models {
            modelPopup.addItem(withTitle: name)
        }
        let current = Preferences.shared.localModelFilename
        if models.contains(current) {
            modelPopup.selectItem(withTitle: current)
        }
    }

    private func refreshInjectionPopup() {
        switch Preferences.shared.injectionMethod {
        case .paste:
            injectionPasteRadio.state = .on
            injectionTypedRadio.state = .off
        case .typed:
            injectionPasteRadio.state = .off
            injectionTypedRadio.state = .on
        }
    }

    private func discoverModels() -> [String] {
        var names = Set<String>()

        if let resources = Bundle.main.resourceURL,
           let items = try? FileManager.default.contentsOfDirectory(
                at: resources, includingPropertiesForKeys: nil) {
            for url in items where url.pathExtension == "bin"
                && url.lastPathComponent.hasPrefix("ggml-") {
                names.insert(url.lastPathComponent)
            }
        }

        let modelsDir = Preferences.defaultSupportDirectory
            .appendingPathComponent("models", isDirectory: true)
        if let items = try? FileManager.default.contentsOfDirectory(
                at: modelsDir, includingPropertiesForKeys: nil) {
            for url in items where url.pathExtension == "bin"
                && url.lastPathComponent.hasPrefix("ggml-") {
                names.insert(url.lastPathComponent)
            }
        }

        return names.sorted()
    }

    // MARK: - Actions

    @objc private func backendChanged() {
        switch backendPopup.indexOfSelectedItem {
        case 0: Preferences.shared.backend = .whisperCpp
        case 1: Preferences.shared.backend = .openAI
        default: break
        }
        updateConditionalRows()
    }

    @objc private func modelChanged() {
        guard let title = modelPopup.selectedItem?.title, title.hasPrefix("ggml-") else { return }
        Preferences.shared.localModelFilename = title
    }

    @objc private func injectionPasteSelected() {
        Preferences.shared.injectionMethod = .paste
    }

    @objc private func injectionTypedSelected() {
        Preferences.shared.injectionMethod = .typed
    }

    @objc private func inputDeviceChanged() {
        let idx = inputDevicePopup.indexOfSelectedItem
        if idx == 0 {
            Preferences.shared.inputDeviceUID = ""
        } else if idx - 1 < inputDevices.count {
            Preferences.shared.inputDeviceUID = inputDevices[idx - 1].uid
        }
    }

    // NSTextFieldDelegate — API key field.
    func controlTextDidChange(_ obj: Notification) {
        guard (obj.object as? NSSecureTextField) === apiKeyField else { return }
        Preferences.shared.openAIAPIKey = apiKeyField.stringValue
    }

    @objc private func hotkeyButtonClicked() {
        if isRecordingHotkey {
            stopRecordingHotkey()
            refreshHotkeyButton()
            hotkeyStatusLabel.stringValue = ""
        } else {
            startRecordingHotkey()
        }
    }

    // MARK: - Hotkey recording

    private func startRecordingHotkey() {
        isRecordingHotkey = true
        hotkeyButton.title = "Press keys…"
        hotkeyStatusLabel.stringValue = "ESC to cancel. At least one modifier required."

        hotkeyMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.keyDown, .flagsChanged, .systemDefined]
        ) { [weak self] event in
            guard let self = self else { return event }
            if event.type == .systemDefined {
                NSLog("push-to-dictate: hotkey recorder saw systemDefined event " +
                      "subtype=%d data1=0x%08lx data2=0x%08lx",
                      Int(event.subtype.rawValue), event.data1, event.data2)
                return event
            }
            if event.type == .keyDown {
                if event.keyCode == 53 {
                    self.stopRecordingHotkey()
                    self.refreshHotkeyButton()
                    self.hotkeyStatusLabel.stringValue = "Cancelled."
                    return nil
                }
                let keyCode = Int(event.keyCode)
                let flags = PreferencesWindowController.cgFlags(from: event.modifierFlags)
                let hasModifier = !flags.intersection([.maskControl, .maskAlternate,
                                                       .maskShift, .maskCommand]).isEmpty
                if !hasModifier && !PreferencesWindowController.isFunctionKey(keyCode) {
                    self.hotkeyStatusLabel.stringValue =
                        "Needs a modifier (⌃ ⌥ ⇧ ⌘), or use an F-key alone."
                    return nil
                }
                Preferences.shared.hotkeyKeyCode = keyCode
                Preferences.shared.hotkeyModifierFlags = flags
                self.stopRecordingHotkey()
                self.refreshHotkeyButton()
                self.hotkeyStatusLabel.stringValue = "Saved."
                self.onHotkeyChanged?()
                return nil
            }
            return event
        }
    }

    private static func isFunctionKey(_ keyCode: Int) -> Bool {
        switch keyCode {
        case 122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111,
             105, 107, 113, 106, 64, 79, 80, 90:
            return true
        default:
            return false
        }
    }

    private func stopRecordingHotkey() {
        isRecordingHotkey = false
        if let monitor = hotkeyMonitor {
            NSEvent.removeMonitor(monitor)
            hotkeyMonitor = nil
        }
    }

    // MARK: - Formatting helpers

    private static func cgFlags(from nsFlags: NSEvent.ModifierFlags) -> CGEventFlags {
        var flags: CGEventFlags = []
        if nsFlags.contains(.control)  { flags.insert(.maskControl) }
        if nsFlags.contains(.option)   { flags.insert(.maskAlternate) }
        if nsFlags.contains(.shift)    { flags.insert(.maskShift) }
        if nsFlags.contains(.command)  { flags.insert(.maskCommand) }
        return flags
    }

    private static func describe(keyCode: Int, flags: CGEventFlags) -> String {
        var parts: [String] = []
        if flags.contains(.maskControl)   { parts.append("⌃") }
        if flags.contains(.maskAlternate) { parts.append("⌥") }
        if flags.contains(.maskShift)     { parts.append("⇧") }
        if flags.contains(.maskCommand)   { parts.append("⌘") }
        parts.append(keyName(for: keyCode))
        return parts.joined()
    }

    private static func keyName(for keyCode: Int) -> String {
        switch keyCode {
        case 0:   return "A"
        case 1:   return "S"
        case 2:   return "D"
        case 3:   return "F"
        case 4:   return "H"
        case 5:   return "G"
        case 6:   return "Z"
        case 7:   return "X"
        case 8:   return "C"
        case 9:   return "V"
        case 11:  return "B"
        case 12:  return "Q"
        case 13:  return "W"
        case 14:  return "E"
        case 15:  return "R"
        case 16:  return "Y"
        case 17:  return "T"
        case 31:  return "O"
        case 32:  return "U"
        case 34:  return "I"
        case 35:  return "P"
        case 37:  return "L"
        case 38:  return "J"
        case 40:  return "K"
        case 45:  return "N"
        case 46:  return "M"
        case 18:  return "1"
        case 19:  return "2"
        case 20:  return "3"
        case 21:  return "4"
        case 22:  return "6"
        case 23:  return "5"
        case 25:  return "9"
        case 26:  return "7"
        case 28:  return "8"
        case 29:  return "0"
        case 33:  return "["
        case 30:  return "]"
        case 41:  return ";"
        case 39:  return "'"
        case 43:  return ","
        case 47:  return "."
        case 44:  return "/"
        case 42:  return "\\"
        case 27:  return "-"
        case 24:  return "="
        case 50:  return "`"
        case 49:  return "Space"
        case 36:  return "Return"
        case 48:  return "Tab"
        case 51:  return "Delete"
        case 53:  return "Esc"
        case 123: return "←"
        case 124: return "→"
        case 125: return "↓"
        case 126: return "↑"
        case 122: return "F1"
        case 120: return "F2"
        case 99:  return "F3"
        case 118: return "F4"
        case 96:  return "F5"
        case 97:  return "F6"
        case 98:  return "F7"
        case 100: return "F8"
        case 101: return "F9"
        case 109: return "F10"
        case 103: return "F11"
        case 111: return "F12"
        default:  return "Key\(keyCode)"
        }
    }
}
