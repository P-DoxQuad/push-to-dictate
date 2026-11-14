import Cocoa
import CoreGraphics

final class PreferencesWindowController: NSWindowController,
                                         NSTextFieldDelegate,
                                         NSTableViewDataSource,
                                         NSTableViewDelegate {
    static let shared = PreferencesWindowController()

    var onHotkeyChanged: (() -> Void)?
    var onColoredIconChanged: (() -> Void)?

    // Controls
    private let hotkeyButton = NSButton(title: "", target: nil, action: nil)
    private let hotkeyStatusLabel = NSTextField(labelWithString: "")
    private let backendPopup = NSPopUpButton()
    private let modelPopup = NSPopUpButton()
    private let injectionPasteRadio = NSButton(radioButtonWithTitle: "Paste",
                                               target: nil, action: nil)
    private let injectionTypedRadio = NSButton(radioButtonWithTitle: "Typed",
                                               target: nil, action: nil)
    private let inputDevicePopup = NSPopUpButton()
    private let startSoundPopup = NSPopUpButton()
    private let stopSoundPopup = NSPopUpButton()
    private let apiKeyField = NSSecureTextField()
    private let modelsFolderField = NSTextField()
    private let modelsFolderChooseButton = NSButton(title: "Choose…",
                                                    target: nil, action: nil)
    private let modelsFolderClearButton = NSButton(title: "Clear",
                                                   target: nil, action: nil)
    private let launchCheckbox = NSButton(checkboxWithTitle: "Launch at login",
                                          target: nil, action: nil)
    private let logEverythingCheckbox = NSButton(
        checkboxWithTitle: "Log everything (unchecked, errors only)",
        target: nil, action: nil)
    private let coloredIconCheckbox = NSButton(
        checkboxWithTitle: "Colored menu bar icon (unchecked, matches light/dark mode)",
        target: nil, action: nil)
    private let exportButton = NSButton(title: "Export…", target: nil, action: nil)
    private let importButton = NSButton(title: "Import…", target: nil, action: nil)

    // State
    private var inputDevices: [(uid: String, name: String)] = []
    private var hotkeyMonitor: Any?
    private var isRecordingHotkey = false

    // Split view / categories
    private let categoryTitles = ["General", "Transcription", "Audio", "Output",
                                  "Interface", "Advanced"]
    private var categoryViews: [NSView] = []
    private let sidebarTable = NSTableView()
    private let contentContainer = NSView()
    private var transcriptionGrid: NSGridView!
    private let transcriptionModelRowIndex = 1
    private let transcriptionModelsFolderRowIndex = 2
    private let transcriptionApiKeyRowIndex = 3

    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 400),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "push-to-dictate — Preferences"
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 640, height: 340)
        self.init(window: window)
        wireActions()
        buildLayout()
        refreshAll()
    }

    func showPreferences() {
        if let window = window {
            if !window.isVisible { window.center() }
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    override func close() {
        stopRecordingHotkey()
        super.close()
    }

    // MARK: - Control wiring

    private func wireActions() {
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

        inputDevicePopup.target = self
        inputDevicePopup.action = #selector(inputDeviceChanged)

        startSoundPopup.target = self
        startSoundPopup.action = #selector(startSoundChanged)
        stopSoundPopup.target = self
        stopSoundPopup.action = #selector(stopSoundChanged)

        launchCheckbox.target = self
        launchCheckbox.action = #selector(launchAtLoginChanged)

        logEverythingCheckbox.target = self
        logEverythingCheckbox.action = #selector(logEverythingChanged)

        coloredIconCheckbox.target = self
        coloredIconCheckbox.action = #selector(coloredIconChanged)

        exportButton.target = self
        exportButton.action = #selector(exportPreferences)
        importButton.target = self
        importButton.action = #selector(importPreferences)

        modelsFolderField.placeholderString = ""
        modelsFolderField.delegate = self
        modelsFolderChooseButton.target = self
        modelsFolderChooseButton.action = #selector(chooseModelsFolder)
        modelsFolderClearButton.target = self
        modelsFolderClearButton.action = #selector(clearModelsFolder)

        apiKeyField.placeholderString = "sk-..."
        apiKeyField.delegate = self
    }

    // MARK: - Layout (split view)

    private func buildLayout() {
        guard let contentView = window?.contentView else { return }

        categoryViews = [
            buildGeneralPane(),
            buildTranscriptionPane(),
            buildAudioPane(),
            buildOutputPane(),
            buildInterfacePane(),
            buildAdvancedPane()
        ]

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("Category"))
        column.title = ""
        column.minWidth = 120
        sidebarTable.addTableColumn(column)
        sidebarTable.headerView = nil
        sidebarTable.rowSizeStyle = .medium
        sidebarTable.selectionHighlightStyle = .sourceList
        sidebarTable.dataSource = self
        sidebarTable.delegate = self
        sidebarTable.allowsEmptySelection = false
        sidebarTable.allowsMultipleSelection = false

        let sidebarScroll = NSScrollView()
        sidebarScroll.documentView = sidebarTable
        sidebarScroll.hasVerticalScroller = true
        sidebarScroll.hasHorizontalScroller = false
        sidebarScroll.borderType = .noBorder
        sidebarScroll.drawsBackground = false

        let split = NSSplitView()
        split.isVertical = true
        split.dividerStyle = .thin
        split.addArrangedSubview(sidebarScroll)
        split.addArrangedSubview(contentContainer)
        split.translatesAutoresizingMaskIntoConstraints = false

        contentView.addSubview(split)
        NSLayoutConstraint.activate([
            split.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            split.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            split.topAnchor.constraint(equalTo: contentView.topAnchor),
            split.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            sidebarScroll.widthAnchor.constraint(equalToConstant: 170)
        ])

        sidebarTable.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        showCategory(at: 0)
    }

    private func showCategory(at index: Int) {
        for sub in contentContainer.subviews { sub.removeFromSuperview() }
        guard index >= 0, index < categoryViews.count else { return }
        let view = categoryViews[index]
        view.translatesAutoresizingMaskIntoConstraints = false
        contentContainer.addSubview(view)
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: contentContainer.topAnchor, constant: 20),
            view.leadingAnchor.constraint(equalTo: contentContainer.leadingAnchor, constant: 20),
            view.trailingAnchor.constraint(lessThanOrEqualTo: contentContainer.trailingAnchor, constant: -20),
            view.bottomAnchor.constraint(lessThanOrEqualTo: contentContainer.bottomAnchor, constant: -20)
        ])
    }

    private func gridView(from rows: [[NSView]]) -> NSGridView {
        let grid = NSGridView(views: rows)
        grid.rowSpacing = 12
        grid.columnSpacing = 10
        grid.column(at: 0).xPlacement = .trailing
        return grid
    }

    private func buildGeneralPane() -> NSView {
        let hotkeyLabel = NSTextField(labelWithString: "Hotkey:")
        let launchLabel = NSTextField(labelWithString: "Startup:")
        let backupLabel = NSTextField(labelWithString: "Backup:")
        let backupStack = NSStackView(views: [exportButton, importButton])
        backupStack.orientation = .horizontal
        backupStack.spacing = 8
        return gridView(from: [
            [hotkeyLabel, hotkeyButton, hotkeyStatusLabel],
            [launchLabel, launchCheckbox, NSView()],
            [backupLabel, backupStack, NSView()]
        ])
    }

    private func buildTranscriptionPane() -> NSView {
        let backendLabel = NSTextField(labelWithString: "Backend:")
        let modelLabel = NSTextField(labelWithString: "Local model:")
        let modelsFolderLabel = NSTextField(labelWithString: "Models folder:")
        let apiKeyLabel = NSTextField(labelWithString: "OpenAI API key:")

        let modelsFolderStack = NSStackView(views: [
            modelsFolderField, modelsFolderChooseButton, modelsFolderClearButton
        ])
        modelsFolderStack.orientation = .horizontal
        modelsFolderStack.spacing = 6
        modelsFolderStack.setHuggingPriority(.defaultLow, for: .horizontal)

        transcriptionGrid = gridView(from: [
            [backendLabel, backendPopup, NSView()],
            [modelLabel, modelPopup, NSView()],
            [modelsFolderLabel, modelsFolderStack, NSView()],
            [apiKeyLabel, apiKeyField, NSView()]
        ])
        apiKeyField.widthAnchor.constraint(greaterThanOrEqualToConstant: 260).isActive = true
        modelsFolderField.widthAnchor.constraint(greaterThanOrEqualToConstant: 220).isActive = true
        return transcriptionGrid
    }

    private func buildAudioPane() -> NSView {
        let inputDeviceLabel = NSTextField(labelWithString: "Input device:")
        let startSoundLabel = NSTextField(labelWithString: "Start sound:")
        let stopSoundLabel = NSTextField(labelWithString: "Stop sound:")
        return gridView(from: [
            [inputDeviceLabel, inputDevicePopup, NSView()],
            [startSoundLabel, startSoundPopup, NSView()],
            [stopSoundLabel, stopSoundPopup, NSView()]
        ])
    }

    private func buildOutputPane() -> NSView {
        let injectionLabel = NSTextField(labelWithString: "Text insertion:")
        let injectionStack = NSStackView(views: [injectionPasteRadio, injectionTypedRadio])
        injectionStack.orientation = .horizontal
        injectionStack.spacing = 16
        return gridView(from: [
            [injectionLabel, injectionStack, NSView()]
        ])
    }

    private func buildInterfacePane() -> NSView {
        let appearanceLabel = NSTextField(labelWithString: "Appearance:")
        return gridView(from: [
            [appearanceLabel, coloredIconCheckbox, NSView()]
        ])
    }

    private func buildAdvancedPane() -> NSView {
        let logEverythingLabel = NSTextField(labelWithString: "Logging:")
        return gridView(from: [
            [logEverythingLabel, logEverythingCheckbox, NSView()]
        ])
    }

    // MARK: - NSTableViewDataSource / Delegate (sidebar)

    func numberOfRows(in tableView: NSTableView) -> Int {
        return categoryTitles.count
    }

    func tableView(_ tableView: NSTableView,
                   viewFor tableColumn: NSTableColumn?,
                   row: Int) -> NSView? {
        let identifier = NSUserInterfaceItemIdentifier("Category")
        let cell: NSTableCellView
        if let reused = tableView.makeView(withIdentifier: identifier, owner: self)
            as? NSTableCellView {
            cell = reused
        } else {
            cell = NSTableCellView()
            cell.identifier = identifier
            let label = NSTextField(labelWithString: "")
            label.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(label)
            NSLayoutConstraint.activate([
                label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 10),
                label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -10),
                label.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
            ])
            cell.textField = label
        }
        cell.textField?.stringValue = categoryTitles[row]
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        showCategory(at: sidebarTable.selectedRow)
    }

    // MARK: - Refresh from Preferences

    private func refreshAll() {
        refreshHotkeyButton()
        hotkeyStatusLabel.stringValue = ""
        refreshBackendPopup()
        refreshModelPopup()
        refreshInjectionPopup()
        refreshInputDevicePopup()
        refreshSoundPopups()
        apiKeyField.stringValue = Preferences.shared.openAIAPIKey
        let stored = Preferences.shared.modelsDirectory
        modelsFolderField.stringValue = stored.isEmpty
            ? (Bundle.main.resourcePath ?? "")
            : stored
        launchCheckbox.state = LaunchAtLogin.isEnabled ? .on : .off
        logEverythingCheckbox.state = Preferences.shared.logEverything ? .on : .off
        coloredIconCheckbox.state = Preferences.shared.useColoredMenuBarIcon ? .on : .off
        updateConditionalRows()
    }

    private func refreshSoundPopups() {
        let names = [Preferences.noSoundName] + PreferencesWindowController.availableSystemSounds()
        startSoundPopup.removeAllItems()
        stopSoundPopup.removeAllItems()
        startSoundPopup.addItems(withTitles: names)
        stopSoundPopup.addItems(withTitles: names)
        let start = Preferences.shared.startSound
        let stop = Preferences.shared.stopSound
        if names.contains(start) { startSoundPopup.selectItem(withTitle: start) }
        if names.contains(stop)  { stopSoundPopup.selectItem(withTitle: stop) }
    }

    private static func availableSystemSounds() -> [String] {
        let dirs = [
            "/System/Library/Sounds",
            (NSHomeDirectory() as NSString).appendingPathComponent("Library/Sounds")
        ]
        var names = Set<String>()
        for dir in dirs {
            guard let items = try? FileManager.default.contentsOfDirectory(atPath: dir) else {
                continue
            }
            for item in items where
                item.hasSuffix(".aiff") || item.hasSuffix(".caf") || item.hasSuffix(".wav") {
                names.insert((item as NSString).deletingPathExtension)
            }
        }
        return names.sorted()
    }

    private func updateConditionalRows() {
        guard let grid = transcriptionGrid else { return }
        let isOpenAI = Preferences.shared.backend == .openAI
        grid.row(at: transcriptionModelRowIndex).isHidden = isOpenAI
        grid.row(at: transcriptionModelsFolderRowIndex).isHidden = isOpenAI
        grid.row(at: transcriptionApiKeyRowIndex).isHidden = !isOpenAI
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
        let override = Preferences.shared.modelsDirectory
        let searchURL: URL? = override.isEmpty
            ? Bundle.main.resourceURL
            : URL(fileURLWithPath: override, isDirectory: true)
        guard let root = searchURL,
              let items = try? FileManager.default.contentsOfDirectory(
                at: root, includingPropertiesForKeys: nil) else {
            return []
        }
        for url in items where url.pathExtension == "bin"
            && url.lastPathComponent.hasPrefix("ggml-") {
            names.insert(url.lastPathComponent)
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
        refreshInjectionPopup()
    }

    @objc private func injectionTypedSelected() {
        Preferences.shared.injectionMethod = .typed
        refreshInjectionPopup()
    }

    @objc private func inputDeviceChanged() {
        let idx = inputDevicePopup.indexOfSelectedItem
        if idx == 0 {
            Preferences.shared.inputDeviceUID = ""
        } else if idx - 1 < inputDevices.count {
            Preferences.shared.inputDeviceUID = inputDevices[idx - 1].uid
        }
    }

    @objc private func launchAtLoginChanged() {
        LaunchAtLogin.setEnabled(launchCheckbox.state == .on)
        launchCheckbox.state = LaunchAtLogin.isEnabled ? .on : .off
    }

    @objc private func logEverythingChanged() {
        Preferences.shared.logEverything = (logEverythingCheckbox.state == .on)
    }

    @objc private func coloredIconChanged() {
        Preferences.shared.useColoredMenuBarIcon = (coloredIconCheckbox.state == .on)
        onColoredIconChanged?()
    }

    @objc private func exportPreferences() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "push-to-dictate-preferences.plist"
        panel.allowedFileTypes = ["plist"]
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            self.writeBackup(to: url)
        }
    }

    @objc private func importPreferences() {
        let panel = NSOpenPanel()
        panel.allowedFileTypes = ["plist"]
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            self.readBackup(from: url)
        }
    }

    private func writeBackup(to url: URL) {
        var userDefaults: [String: Any] = [:]
        for key in Preferences.allUserDefaultsKeys {
            if let value = UserDefaults.standard.object(forKey: key) {
                userDefaults[key] = value
            }
        }
        let payload: [String: Any] = [
            "version": 1,
            "userDefaults": userDefaults,
            "openAIAPIKey": Preferences.shared.openAIAPIKey,
            "launchAtLogin": LaunchAtLogin.isEnabled
        ]
        do {
            let data = try PropertyListSerialization.data(fromPropertyList: payload,
                                                          format: .xml, options: 0)
            try data.write(to: url, options: [.atomic])
        } catch {
            presentBackupError("Could not write backup", detail: error.localizedDescription)
        }
    }

    private func readBackup(from url: URL) {
        do {
            let data = try Data(contentsOf: url)
            let obj = try PropertyListSerialization.propertyList(from: data,
                                                                 options: [], format: nil)
            guard let payload = obj as? [String: Any] else {
                presentBackupError("Invalid backup", detail: "File is not a push-to-dictate backup.")
                return
            }
            if let dict = payload["userDefaults"] as? [String: Any] {
                for key in Preferences.allUserDefaultsKeys {
                    if let value = dict[key] {
                        UserDefaults.standard.set(value, forKey: key)
                    } else {
                        UserDefaults.standard.removeObject(forKey: key)
                    }
                }
            }
            if let apiKey = payload["openAIAPIKey"] as? String {
                Preferences.shared.openAIAPIKey = apiKey
            }
            if let launch = payload["launchAtLogin"] as? Bool {
                LaunchAtLogin.setEnabled(launch)
            }
            refreshAll()
            onHotkeyChanged?()
            onColoredIconChanged?()
        } catch {
            presentBackupError("Could not read backup", detail: error.localizedDescription)
        }
    }

    private func presentBackupError(_ title: String, detail: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = detail
        alert.runModal()
    }

    @objc private func startSoundChanged() {
        guard let title = startSoundPopup.selectedItem?.title else { return }
        Preferences.shared.startSound = title
        previewSound(named: title)
    }

    @objc private func stopSoundChanged() {
        guard let title = stopSoundPopup.selectedItem?.title else { return }
        Preferences.shared.stopSound = title
        previewSound(named: title)
    }

    private func previewSound(named name: String) {
        guard name != Preferences.noSoundName,
              let sound = NSSound(named: NSSound.Name(name)) else { return }
        sound.play()
    }

    // NSTextFieldDelegate — API key field + models folder field.
    func controlTextDidChange(_ obj: Notification) {
        if (obj.object as? NSTextField) === apiKeyField {
            Preferences.shared.openAIAPIKey = apiKeyField.stringValue
        } else if (obj.object as? NSTextField) === modelsFolderField {
            let text = modelsFolderField.stringValue
            // Treat text matching the bundle's own Resources path as "no override"
            // so moving the app later doesn't leave a stale absolute path baked in.
            if text == (Bundle.main.resourcePath ?? "<impossible>") {
                Preferences.shared.modelsDirectory = ""
            } else {
                Preferences.shared.modelsDirectory = text
            }
            refreshModelPopup()
        }
    }

    @objc private func chooseModelsFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Use This Folder"
        panel.message = "Choose a folder containing ggml-*.bin model files."
        if let current = modelsFolderField.stringValue as String?, !current.isEmpty {
            panel.directoryURL = URL(fileURLWithPath: current)
        }
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            self?.modelsFolderField.stringValue = url.path
            Preferences.shared.modelsDirectory = url.path
            self?.refreshModelPopup()
        }
    }

    @objc private func clearModelsFolder() {
        modelsFolderField.stringValue = Bundle.main.resourcePath ?? ""
        Preferences.shared.modelsDirectory = ""
        refreshModelPopup()
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
                Logger.info(String(
                    format: "hotkey recorder saw systemDefined event " +
                            "subtype=%d data1=0x%08lx data2=0x%08lx",
                    Int(event.subtype.rawValue), event.data1, event.data2))
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

fileprivate enum LaunchAtLogin {
    static var label: String {
        return Bundle.main.bundleIdentifier ?? "com.paradoxicalquad.push-to-dictate"
    }

    static var plistURL: URL {
        return URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/LaunchAgents", isDirectory: true)
            .appendingPathComponent("\(label).plist")
    }

    static var isEnabled: Bool {
        return FileManager.default.fileExists(atPath: plistURL.path)
    }

    static func setEnabled(_ enabled: Bool) {
        if enabled { install() } else { uninstall() }
    }

    private static func install() {
        guard let exec = Bundle.main.executablePath else { return }
        let dict: [String: Any] = [
            "Label": label,
            "ProgramArguments": [exec],
            "RunAtLoad": true
        ]
        let dir = plistURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir,
                                                 withIntermediateDirectories: true,
                                                 attributes: nil)
        guard let data = try? PropertyListSerialization.data(
                fromPropertyList: dict, format: .xml, options: 0) else { return }
        try? data.write(to: plistURL, options: [.atomic])
    }

    private static func uninstall() {
        try? FileManager.default.removeItem(at: plistURL)
    }
}
