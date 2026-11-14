import Cocoa
import CoreGraphics

final class PreferencesWindowController: NSWindowController,
                                         NSTextFieldDelegate,
                                         NSTableViewDataSource,
                                         NSTableViewDelegate,
                                         NSMenuDelegate {
    static let shared = PreferencesWindowController()

    var onHotkeyChanged: (() -> Void)?
    var onColoredIconChanged: (() -> Void)?

    // MARK: - Controls

    private let hotkeyButton: NSButton = {
        let b = NSButton(frame: .zero)
        b.bezelStyle = .rounded
        b.title = ""
        return b
    }()
    private let hotkeyStatusLabel: NSTextField = {
        let f = NSTextField(frame: .zero)
        f.isEditable = false; f.isSelectable = false
        f.isBordered = false; f.drawsBackground = false
        f.font = NSFont.systemFont(ofSize: 11)
        f.textColor = .secondaryLabelColor
        return f
    }()
    private let backendPopup = NSPopUpButton()
    private let modelPopup = NSPopUpButton()
    private let modelsFolderField = NSTextField()
    private let modelsFolderChooseButton: NSButton = {
        let b = NSButton(frame: .zero)
        b.bezelStyle = .rounded
        b.title = "Choose…"
        return b
    }()
    private let modelsFolderClearButton: NSButton = {
        let b = NSButton(frame: .zero)
        b.bezelStyle = .rounded
        b.title = "Default"
        return b
    }()
    private let manageModelsButton: NSButton = {
        let b = NSButton(frame: .zero)
        b.bezelStyle = .rounded
        b.title = "Manage Models…"
        return b
    }()
    private let apiKeyField = NSSecureTextField()
    private let inputDevicePopup = NSPopUpButton()
    private let startSoundPopup = NSPopUpButton()
    private let stopSoundPopup = NSPopUpButton()
    private let injectionPasteRadio: NSButton = {
        let b = NSButton(frame: .zero)
        b.setButtonType(.radio)
        b.title = "Paste"
        return b
    }()
    private let injectionTypedRadio: NSButton = {
        let b = NSButton(frame: .zero)
        b.setButtonType(.radio)
        b.title = "Typed"
        return b
    }()
    private let launchCheckbox: NSButton = {
        let b = NSButton(frame: .zero)
        b.setButtonType(.switch)
        b.title = "Launch at login"
        return b
    }()
    private let coloredIconCheckbox: NSButton = {
        let b = NSButton(frame: .zero)
        b.setButtonType(.switch)
        b.title = "Colored menu bar icon (unchecked, matches light/dark mode)"
        return b
    }()
    private let logEverythingCheckbox: NSButton = {
        let b = NSButton(frame: .zero)
        b.setButtonType(.switch)
        b.title = "Log everything"
        return b
    }()
    private let exportButton: NSButton = {
        let b = NSButton(frame: .zero)
        b.bezelStyle = .rounded
        b.title = "Export…"
        return b
    }()
    private let importButton: NSButton = {
        let b = NSButton(frame: .zero)
        b.bezelStyle = .rounded
        b.title = "Import…"
        return b
    }()
    private let threadsField = NSTextField()
    private let threadsStepper = NSStepper()
    private let beamField = NSTextField()
    private let beamStepper = NSStepper()
    private let saveDebugRecordingsCheckbox: NSButton = {
        let b = NSButton(frame: .zero)
        b.setButtonType(.switch)
        b.title = "Save debug recordings"
        return b
    }()
    private let clearDebugRecordingsButton: NSButton = {
        let b = NSButton(frame: .zero)
        b.bezelStyle = .rounded
        b.title = "Clear Recordings…"
        return b
    }()
    private let clearLogButton: NSButton = {
        let b = NSButton(frame: .zero)
        b.bezelStyle = .rounded
        b.title = "Clear Log…"
        return b
    }()

    // MARK: - State

    private var inputDevices: [(uid: String, name: String)] = []
    private var hotkeyMonitor: Any?
    private var isRecordingHotkey = false

    private let categoryTitles = ["General", "Transcription", "Audio", "Output",
                                  "Interface", "Advanced"]
    private var categoryViews: [NSView] = []
    private let sidebarTable = NSTableView()
    private let contentContainer = NSView()
    private var manageModelsController: ManageModelsWindowController?

    // Transcription pane row wrappers for conditional hiding.
    private var transcriptionModelRow: NSView?
    private var transcriptionModelsFolderRow: NSView?
    private var transcriptionApiKeyRow: NSView?

    // MARK: - Layout constants

    // Column width fits the longest label ("Transcription threads:").
    private static let labelColumnWidth: CGFloat = 160
    private static let labelToControl: CGFloat = 8
    private static let rowGap: CGFloat = 12
    private static let paneInset: CGFloat = 20

    // MARK: - Init

    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 680, height: 420),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false)
        window.title = "Push to Dictate Preferences"
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 600, height: 340)
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
        hotkeyButton.target = self
        hotkeyButton.action = #selector(hotkeyButtonClicked)

        backendPopup.target = self
        backendPopup.action = #selector(backendChanged)
        backendPopup.addItems(withTitles: ["whisper.cpp (local)", "OpenAI API"])

        modelPopup.target = self
        modelPopup.action = #selector(modelChanged)
        modelPopup.menu?.delegate = self

        modelsFolderField.delegate = self
        modelsFolderChooseButton.target = self
        modelsFolderChooseButton.action = #selector(chooseModelsFolder)
        modelsFolderClearButton.target = self
        modelsFolderClearButton.action = #selector(clearModelsFolder)

        manageModelsButton.target = self
        manageModelsButton.action = #selector(openManageModels)

        apiKeyField.placeholderString = "sk-..."
        apiKeyField.delegate = self

        inputDevicePopup.target = self
        inputDevicePopup.action = #selector(inputDeviceChanged)

        startSoundPopup.target = self
        startSoundPopup.action = #selector(startSoundChanged)
        stopSoundPopup.target = self
        stopSoundPopup.action = #selector(stopSoundChanged)

        injectionPasteRadio.target = self
        injectionPasteRadio.action = #selector(injectionPasteSelected)
        injectionTypedRadio.target = self
        injectionTypedRadio.action = #selector(injectionTypedSelected)

        launchCheckbox.target = self
        launchCheckbox.action = #selector(launchAtLoginChanged)

        coloredIconCheckbox.target = self
        coloredIconCheckbox.action = #selector(coloredIconChanged)

        logEverythingCheckbox.target = self
        logEverythingCheckbox.action = #selector(logEverythingChanged)

        exportButton.target = self
        exportButton.action = #selector(exportPreferences)
        importButton.target = self
        importButton.action = #selector(importPreferences)

        threadsStepper.minValue = 1
        threadsStepper.maxValue = Double(ProcessInfo.processInfo.activeProcessorCount)
        threadsStepper.increment = 1
        threadsStepper.valueWraps = false
        threadsStepper.target = self
        threadsStepper.action = #selector(threadsStepperChanged)
        threadsField.delegate = self

        beamStepper.minValue = 1
        beamStepper.maxValue = 10
        beamStepper.increment = 1
        beamStepper.valueWraps = false
        beamStepper.target = self
        beamStepper.action = #selector(beamStepperChanged)
        beamField.delegate = self

        saveDebugRecordingsCheckbox.target = self
        saveDebugRecordingsCheckbox.action = #selector(saveDebugRecordingsChanged)
        clearDebugRecordingsButton.target = self
        clearDebugRecordingsButton.action = #selector(clearDebugRecordings)
        clearLogButton.target = self
        clearLogButton.action = #selector(clearLog)
    }

    // MARK: - Layout (split view: sidebar + content)

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
        let pane = categoryViews[index]
        pane.translatesAutoresizingMaskIntoConstraints = false
        contentContainer.addSubview(pane)
        NSLayoutConstraint.activate([
            pane.topAnchor.constraint(equalTo: contentContainer.topAnchor,
                                      constant: PreferencesWindowController.paneInset),
            pane.leadingAnchor.constraint(equalTo: contentContainer.leadingAnchor,
                                          constant: PreferencesWindowController.paneInset),
            pane.trailingAnchor.constraint(lessThanOrEqualTo: contentContainer.trailingAnchor,
                                           constant: -PreferencesWindowController.paneInset),
            pane.bottomAnchor.constraint(lessThanOrEqualTo: contentContainer.bottomAnchor,
                                         constant: -PreferencesWindowController.paneInset)
        ])
    }

    // MARK: - Pane building

    // Compute the rendered width of the widest label among the given texts
    // using the system font. Used so each pane's column is sized to its own
    // longest label (no wasted whitespace, controls still align).
    private static func widestLabelWidth(_ texts: [String]) -> CGFloat {
        let font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
        let attrs: [NSAttributedString.Key: Any] = [.font: font]
        var maxWidth: CGFloat = 0
        for text in texts {
            let w = (text as NSString).size(withAttributes: attrs).width
            if w > maxWidth { maxWidth = w }
        }
        return ceil(maxWidth)
    }

    private func makeLabel(_ text: String) -> NSTextField {
        let f = NSTextField(frame: .zero)
        f.isEditable = false
        f.isSelectable = false
        f.isBordered = false
        f.drawsBackground = false
        f.alignment = .right
        f.stringValue = text
        f.translatesAutoresizingMaskIntoConstraints = false
        return f
    }

    // Place a label + control pair directly into `pane` at the given top
    // anchor. Label sits in the fixed-width right-aligned column; control
    // follows immediately. Returns the bottom anchor of the row for stacking.
    @discardableResult
    private func placeRow(labelText: String,
                          control: NSView,
                          in pane: NSView,
                          topAnchor: NSLayoutYAxisAnchor,
                          topConstant: CGFloat,
                          labelWidth: CGFloat) -> NSLayoutYAxisAnchor {
        let label = makeLabel(labelText)
        control.translatesAutoresizingMaskIntoConstraints = false
        pane.addSubview(label)
        pane.addSubview(control)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: pane.leadingAnchor),
            label.widthAnchor.constraint(equalToConstant: labelWidth),
            control.leadingAnchor.constraint(equalTo: label.trailingAnchor,
                                             constant: PreferencesWindowController.labelToControl),
            control.centerYAnchor.constraint(equalTo: label.centerYAnchor),
            control.topAnchor.constraint(equalTo: topAnchor, constant: topConstant),
            pane.trailingAnchor.constraint(greaterThanOrEqualTo: control.trailingAnchor)
        ])
        return control.bottomAnchor
    }

    // Variant for conditionally-hidden rows. Wraps the row in an NSView
    // container so it can be hidden as a unit (and so the next row's anchor
    // can collapse when deactivated).
    @discardableResult
    private func placeHidableRow(labelText: String,
                                 control: NSView,
                                 in pane: NSView,
                                 topAnchor: NSLayoutYAxisAnchor,
                                 topConstant: CGFloat,
                                 labelWidth: CGFloat) -> (bottom: NSLayoutYAxisAnchor, row: NSView) {
        let label = makeLabel(labelText)
        control.translatesAutoresizingMaskIntoConstraints = false
        let row = NSView()
        row.translatesAutoresizingMaskIntoConstraints = false
        pane.addSubview(row)
        row.addSubview(label)
        row.addSubview(control)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: pane.leadingAnchor),
            row.topAnchor.constraint(equalTo: topAnchor, constant: topConstant),
            row.trailingAnchor.constraint(equalTo: control.trailingAnchor),
            label.leadingAnchor.constraint(equalTo: row.leadingAnchor),
            label.widthAnchor.constraint(equalToConstant: labelWidth),
            control.leadingAnchor.constraint(equalTo: label.trailingAnchor,
                                             constant: PreferencesWindowController.labelToControl),
            control.centerYAnchor.constraint(equalTo: label.centerYAnchor),
            control.topAnchor.constraint(equalTo: row.topAnchor),
            control.bottomAnchor.constraint(equalTo: row.bottomAnchor),
            pane.trailingAnchor.constraint(greaterThanOrEqualTo: row.trailingAnchor)
        ])
        return (row.bottomAnchor, row)
    }

    private func buildGeneralPane() -> NSView {
        let pane = NSView()
        pane.translatesAutoresizingMaskIntoConstraints = false

        let hotkeyRow = NSStackView(views: [hotkeyButton, hotkeyStatusLabel])
        hotkeyRow.orientation = .horizontal
        hotkeyRow.spacing = 8

        let backupRow = NSStackView(views: [exportButton, importButton])
        backupRow.orientation = .horizontal
        backupRow.spacing = 8

        let lw = PreferencesWindowController.widestLabelWidth(
            ["Hotkey:", "Startup:", "Backup:"])

        let after1 = placeRow(labelText: "Hotkey:", control: hotkeyRow,
                              in: pane, topAnchor: pane.topAnchor, topConstant: 0, labelWidth: lw)
        let after2 = placeRow(labelText: "Startup:", control: launchCheckbox,
                              in: pane, topAnchor: after1,
                              topConstant: PreferencesWindowController.rowGap, labelWidth: lw)
        let after3 = placeRow(labelText: "Backup:", control: backupRow,
                              in: pane, topAnchor: after2,
                              topConstant: PreferencesWindowController.rowGap, labelWidth: lw)
        pane.bottomAnchor.constraint(equalTo: after3).isActive = true
        return pane
    }

    private func buildTranscriptionPane() -> NSView {
        let modelsFolderRow = NSStackView(views: [
            modelsFolderField, modelsFolderChooseButton, modelsFolderClearButton
        ])
        modelsFolderRow.orientation = .horizontal
        modelsFolderRow.spacing = 6
        modelsFolderField.widthAnchor.constraint(equalToConstant: 200).isActive = true

        let modelRow = NSStackView(views: [modelPopup, manageModelsButton])
        modelRow.orientation = .horizontal
        modelRow.spacing = 8

        apiKeyField.widthAnchor.constraint(equalToConstant: 240).isActive = true

        let lw = PreferencesWindowController.widestLabelWidth(
            ["Backend:", "Local model:", "Models folder:", "OpenAI API key:"])

        let row1 = buildRowView(labelText: "Backend:", control: backendPopup, labelWidth: lw)
        let row2 = buildRowView(labelText: "Local model:", control: modelRow, labelWidth: lw)
        let row3 = buildRowView(labelText: "Models folder:", control: modelsFolderRow, labelWidth: lw)
        let row4 = buildRowView(labelText: "OpenAI API key:", control: apiKeyField, labelWidth: lw)

        let pane = NSStackView(views: [row1, row2, row3, row4])
        pane.orientation = .vertical
        pane.alignment = .leading
        pane.spacing = PreferencesWindowController.rowGap
        pane.translatesAutoresizingMaskIntoConstraints = false

        transcriptionModelRow = row2
        transcriptionModelsFolderRow = row3
        transcriptionApiKeyRow = row4
        return pane
    }

    // Builds a single [label, control] row as a self-contained NSView suitable
    // for use as an arranged subview of a vertical NSStackView (which collapses
    // hidden arranged subviews, including their spacing).
    private func buildRowView(labelText: String,
                              control: NSView,
                              labelWidth: CGFloat) -> NSView {
        let label = makeLabel(labelText)
        control.translatesAutoresizingMaskIntoConstraints = false
        let row = NSView()
        row.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(label)
        row.addSubview(control)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: row.leadingAnchor),
            label.widthAnchor.constraint(equalToConstant: labelWidth),
            label.centerYAnchor.constraint(equalTo: control.centerYAnchor),
            control.leadingAnchor.constraint(equalTo: label.trailingAnchor,
                                             constant: PreferencesWindowController.labelToControl),
            control.topAnchor.constraint(equalTo: row.topAnchor),
            control.bottomAnchor.constraint(equalTo: row.bottomAnchor),
            control.trailingAnchor.constraint(equalTo: row.trailingAnchor)
        ])
        return row
    }

    private func buildAudioPane() -> NSView {
        let pane = NSView()
        pane.translatesAutoresizingMaskIntoConstraints = false
        let lw = PreferencesWindowController.widestLabelWidth(
            ["Input device:", "Start sound:", "Stop sound:"])
        let after1 = placeRow(labelText: "Input device:", control: inputDevicePopup,
                              in: pane, topAnchor: pane.topAnchor, topConstant: 0, labelWidth: lw)
        let after2 = placeRow(labelText: "Start sound:", control: startSoundPopup,
                              in: pane, topAnchor: after1,
                              topConstant: PreferencesWindowController.rowGap, labelWidth: lw)
        let after3 = placeRow(labelText: "Stop sound:", control: stopSoundPopup,
                              in: pane, topAnchor: after2,
                              topConstant: PreferencesWindowController.rowGap, labelWidth: lw)
        pane.bottomAnchor.constraint(equalTo: after3).isActive = true
        return pane
    }

    private func buildOutputPane() -> NSView {
        let pane = NSView()
        pane.translatesAutoresizingMaskIntoConstraints = false
        let radios = NSStackView(views: [injectionPasteRadio, injectionTypedRadio])
        radios.orientation = .horizontal
        radios.spacing = 16
        let lw = PreferencesWindowController.widestLabelWidth(["Text insertion:"])
        let after1 = placeRow(labelText: "Text insertion:", control: radios,
                              in: pane, topAnchor: pane.topAnchor, topConstant: 0, labelWidth: lw)
        pane.bottomAnchor.constraint(equalTo: after1).isActive = true
        return pane
    }

    private func buildInterfacePane() -> NSView {
        let pane = NSView()
        pane.translatesAutoresizingMaskIntoConstraints = false
        let lw = PreferencesWindowController.widestLabelWidth(["Appearance:"])
        let after1 = placeRow(labelText: "Appearance:", control: coloredIconCheckbox,
                              in: pane, topAnchor: pane.topAnchor, topConstant: 0, labelWidth: lw)
        pane.bottomAnchor.constraint(equalTo: after1).isActive = true
        return pane
    }

    private func buildAdvancedPane() -> NSView {
        let pane = NSView()
        pane.translatesAutoresizingMaskIntoConstraints = false

        threadsField.translatesAutoresizingMaskIntoConstraints = false
        threadsField.widthAnchor.constraint(equalToConstant: 60).isActive = true

        let threadsHint = NSTextField(frame: .zero)
        threadsHint.isEditable = false; threadsHint.isSelectable = false
        threadsHint.isBordered = false; threadsHint.drawsBackground = false
        threadsHint.textColor = .secondaryLabelColor
        threadsHint.stringValue = PreferencesWindowController.threadsHintString()

        let threadsRow = NSStackView(views: [threadsField, threadsStepper, threadsHint])
        threadsRow.orientation = .horizontal
        threadsRow.spacing = 8

        beamField.translatesAutoresizingMaskIntoConstraints = false
        beamField.widthAnchor.constraint(equalToConstant: 60).isActive = true

        let beamHint = NSTextField(frame: .zero)
        beamHint.isEditable = false; beamHint.isSelectable = false
        beamHint.isBordered = false; beamHint.drawsBackground = false
        beamHint.textColor = .secondaryLabelColor
        beamHint.stringValue = "1 = fastest · 5 = default · 10 = slowest"

        let beamRow = NSStackView(views: [beamField, beamStepper, beamHint])
        beamRow.orientation = .horizontal
        beamRow.spacing = 8

        let debugRow = NSStackView(views: [saveDebugRecordingsCheckbox,
                                           clearDebugRecordingsButton])
        debugRow.orientation = .horizontal
        debugRow.spacing = 12

        let loggingRow = NSStackView(views: [logEverythingCheckbox, clearLogButton])
        loggingRow.orientation = .horizontal
        loggingRow.spacing = 12

        let lw = PreferencesWindowController.widestLabelWidth(
            ["Transcription threads:", "Accuracy:", "Debug recordings:", "Logging:"])

        let after1 = placeRow(labelText: "Transcription threads:", control: threadsRow,
                              in: pane, topAnchor: pane.topAnchor, topConstant: 0,
                              labelWidth: lw)
        let after2 = placeRow(labelText: "Accuracy:", control: beamRow,
                              in: pane, topAnchor: after1,
                              topConstant: PreferencesWindowController.rowGap, labelWidth: lw)
        let after3 = placeRow(labelText: "Debug recordings:", control: debugRow,
                              in: pane, topAnchor: after2,
                              topConstant: PreferencesWindowController.rowGap, labelWidth: lw)
        let after4 = placeRow(labelText: "Logging:", control: loggingRow,
                              in: pane, topAnchor: after3,
                              topConstant: PreferencesWindowController.rowGap, labelWidth: lw)
        pane.bottomAnchor.constraint(equalTo: after4).isActive = true
        return pane
    }

    // MARK: - Sidebar table

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
            let label = NSTextField(frame: .zero)
            label.isEditable = false; label.isSelectable = false
            label.isBordered = false; label.drawsBackground = false
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

    // MARK: - Refresh

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
            ? Preferences.userModelsDirectory.path
            : stored
        launchCheckbox.state = LaunchAtLogin.isEnabled ? .on : .off
        logEverythingCheckbox.state = Preferences.shared.logEverything ? .on : .off
        coloredIconCheckbox.state = Preferences.shared.useColoredMenuBarIcon ? .on : .off
        let threads = Preferences.shared.transcriptionThreads
        threadsField.integerValue = threads
        threadsStepper.integerValue = threads
        let beam = Preferences.shared.beamSize
        beamField.integerValue = beam
        beamStepper.integerValue = beam
        saveDebugRecordingsCheckbox.state = Preferences.shared.saveDebugRecordings ? .on : .off
        updateConditionalRows()
    }

    private func refreshHotkeyButton() {
        let prefs = Preferences.shared
        hotkeyButton.title = PreferencesWindowController.describe(
            keyCode: prefs.hotkeyKeyCode,
            flags: prefs.hotkeyModifierFlags
        )
    }

    private func refreshBackendPopup() {
        switch Preferences.shared.backend {
        case .whisperCpp: backendPopup.selectItem(at: 0)
        case .openAI:     backendPopup.selectItem(at: 1)
        }
    }

    private func refreshModelPopup() {
        modelPopup.removeAllItems()
        let models = discoverModels()
        if models.isEmpty {
            modelPopup.addItem(withTitle: "(no models found)")
            modelPopup.isEnabled = false
            applyModelPopupColor()
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
        applyModelPopupColor()
    }

    private func applyModelPopupColor() {
        let font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
        for item in modelPopup.itemArray {
            let color = ModelCatalog.color(forFilename: item.title) ?? .labelColor
            item.attributedTitle = NSAttributedString(
                string: item.title,
                attributes: [.foregroundColor: color, .font: font]
            )
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

    private func updateConditionalRows() {
        let isOpenAI = Preferences.shared.backend == .openAI
        transcriptionModelRow?.isHidden = isOpenAI
        transcriptionModelsFolderRow?.isHidden = isOpenAI
        transcriptionApiKeyRow?.isHidden = !isOpenAI
    }

    // MARK: - Model discovery

    private func discoverModels() -> [String] {
        var names = Set<String>()
        var roots: [URL] = []
        if let bundle = Bundle.main.resourceURL { roots.append(bundle) }
        roots.append(Preferences.writableModelsDirectory)
        for root in roots {
            guard let items = try? FileManager.default.contentsOfDirectory(
                    at: root, includingPropertiesForKeys: nil) else { continue }
            for url in items where url.pathExtension == "bin"
                && url.lastPathComponent.hasPrefix("ggml-") {
                names.insert(url.lastPathComponent)
            }
        }
        return names.sorted()
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        if menu === modelPopup.menu {
            refreshModelPopup()
        }
    }

    // MARK: - Sounds

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

    private func previewSound(named name: String) {
        guard name != Preferences.noSoundName,
              let sound = NSSound(named: name) else { return }
        sound.play()
    }

    // MARK: - Threads / beam hints

    private static func threadsHintString() -> String {
        let logical = ProcessInfo.processInfo.activeProcessorCount
        let low = max(1, logical / 3)
        let high = max(low, logical / 2)
        let range = low == high ? "\(low)" : "\(low)–\(high)"
        return "Max: \(logical) · Recommended: \(range)"
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
        applyModelPopupColor()
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

    @objc private func threadsStepperChanged() {
        let value = threadsStepper.integerValue
        threadsField.integerValue = value
        Preferences.shared.transcriptionThreads = value
    }

    @objc private func beamStepperChanged() {
        let value = beamStepper.integerValue
        beamField.integerValue = value
        Preferences.shared.beamSize = value
    }

    @objc private func saveDebugRecordingsChanged() {
        Preferences.shared.saveDebugRecordings = (saveDebugRecordingsCheckbox.state == .on)
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

    @objc private func chooseModelsFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Use This Folder"
        panel.message = "Choose a folder containing ggml-*.bin model files."
        if !modelsFolderField.stringValue.isEmpty {
            panel.directoryURL = URL(fileURLWithPath: modelsFolderField.stringValue)
        }
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            self?.modelsFolderField.stringValue = url.path
            Preferences.shared.modelsDirectory = url.path
            self?.refreshModelPopup()
        }
    }

    @objc private func clearModelsFolder() {
        modelsFolderField.stringValue = Preferences.userModelsDirectory.path
        Preferences.shared.modelsDirectory = ""
        refreshModelPopup()
    }

    @objc private func openManageModels() {
        let controller = manageModelsController ?? ManageModelsWindowController()
        manageModelsController = controller
        controller.onDidChange = { [weak self] in self?.refreshModelPopup() }
        controller.refreshAll()
        guard let sheet = controller.window, let parent = window else { return }
        parent.beginSheet(sheet) { [weak self] _ in
            self?.refreshModelPopup()
        }
    }

    @objc private func clearLog() {
        let fm = FileManager.default
        let url = Logger.logFileURL
        let attrs = try? fm.attributesOfItem(atPath: url.path)
        let size = (attrs?[.size] as? NSNumber)?.intValue ?? 0
        guard size > 0 else {
            let alert = NSAlert()
            alert.messageText = "Log is already empty."
            alert.informativeText = url.path
            alert.runModal()
            return
        }
        let confirm = NSAlert()
        confirm.messageText = "Clear the log?"
        confirm.informativeText = "This permanently empties:\n\(url.path)"
        confirm.addButton(withTitle: "Clear")
        confirm.addButton(withTitle: "Cancel")
        guard confirm.runModal() == .alertFirstButtonReturn else { return }
        Logger.clear()
    }

    @objc private func clearDebugRecordings() {
        let fm = FileManager.default
        let dir = Preferences.debugRecordingsDirectory
        let files = (try? fm.contentsOfDirectory(at: dir,
                                                 includingPropertiesForKeys: nil)) ?? []
        let wavs = files.filter { $0.pathExtension.lowercased() == "wav" }
        guard !wavs.isEmpty else {
            let alert = NSAlert()
            alert.messageText = "No debug recordings to clear."
            alert.informativeText = dir.path
            alert.runModal()
            return
        }
        let confirm = NSAlert()
        confirm.messageText = "Delete \(wavs.count) debug recording\(wavs.count == 1 ? "" : "s")?"
        confirm.informativeText = "This permanently removes every .wav in:\n\(dir.path)"
        confirm.addButton(withTitle: "Delete")
        confirm.addButton(withTitle: "Cancel")
        guard confirm.runModal() == .alertFirstButtonReturn else { return }
        for url in wavs {
            try? fm.removeItem(at: url)
        }
    }

    @objc private func exportPreferences() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Push to Dictate Preferences.plist"
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
                presentBackupError("Invalid backup", detail: "File is not a Push to Dictate backup.")
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

    // MARK: - NSTextFieldDelegate

    func controlTextDidChange(_ obj: Notification) {
        if (obj.object as? NSTextField) === apiKeyField {
            Preferences.shared.openAIAPIKey = apiKeyField.stringValue
        } else if (obj.object as? NSTextField) === modelsFolderField {
            let text = modelsFolderField.stringValue
            if text == Preferences.userModelsDirectory.path {
                Preferences.shared.modelsDirectory = ""
            } else {
                Preferences.shared.modelsDirectory = text
            }
            refreshModelPopup()
        } else if (obj.object as? NSTextField) === threadsField {
            let logical = ProcessInfo.processInfo.activeProcessorCount
            let value = max(1, min(logical, threadsField.integerValue))
            threadsStepper.integerValue = value
            Preferences.shared.transcriptionThreads = value
        } else if (obj.object as? NSTextField) === beamField {
            let value = max(1, min(10, beamField.integerValue))
            beamStepper.integerValue = value
            Preferences.shared.beamSize = value
        }
    }

    // MARK: - Hotkey recording

    @objc private func hotkeyButtonClicked() {
        if isRecordingHotkey {
            stopRecordingHotkey()
            refreshHotkeyButton()
            hotkeyStatusLabel.stringValue = ""
        } else {
            startRecordingHotkey()
        }
    }

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

    private func stopRecordingHotkey() {
        isRecordingHotkey = false
        if let monitor = hotkeyMonitor {
            NSEvent.removeMonitor(monitor)
            hotkeyMonitor = nil
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

    // MARK: - Formatting helpers

    private static func cgFlags(from nsFlags: NSEvent.ModifierFlags) -> CGEventFlags {
        var flags: CGEventFlags = []
        if nsFlags.contains(.control)  { flags.insert(.maskControl) }
        if nsFlags.contains(.option)   { flags.insert(.maskAlternate) }
        if nsFlags.contains(.shift)    { flags.insert(.maskShift) }
        if nsFlags.contains(.command)  { flags.insert(.maskCommand) }
        return flags
    }

    static func describe(keyCode: Int, flags: CGEventFlags) -> String {
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
