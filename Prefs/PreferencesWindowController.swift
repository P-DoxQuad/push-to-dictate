import Cocoa
import CoreGraphics

// Document / pane view that flips the coordinate system so content
// stacks from the top-left. Needed for any view that hosts chained
// top-down constraints inside an NSScrollView; otherwise content lands
// at the bottom of the visible area.
private final class FlippedView: NSView {
    override var isFlipped: Bool { return true }
}

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
        b.title = "Use colored menu bar icon"
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
    private let resetDefaultsButton: NSButton = {
        let b = NSButton(frame: .zero)
        b.bezelStyle = .rounded
        b.title = "Reset to Defaults"
        return b
    }()
    private let silenceAutoStopCheckbox: NSButton = {
        let b = NSButton(frame: .zero)
        b.setButtonType(.switch)
        b.title = "Auto-stop after silence"
        return b
    }()
    private let silenceThresholdField = NSTextField()
    private let silenceSecondsField = NSTextField()
    private let continuousDictationCheckbox: NSButton = {
        let b = NSButton(frame: .zero)
        b.setButtonType(.switch)
        b.title = "Continuous dictation"
        return b
    }()
    private let continuousPauseField = NSTextField()
    private let continuousMaxChunkField = NSTextField()
    private let continuousPromptChainCheckbox: NSButton = {
        let b = NSButton(frame: .zero)
        b.setButtonType(.switch)
        b.title = "Feed prior transcript to whisper as context"
        return b
    }()
    private let continuousPromptChainMaxCharsField = NSTextField()
    private let stripWhisperPunctuationCheckbox: NSButton = {
        let b = NSButton(frame: .zero)
        b.setButtonType(.switch)
        b.title = "Strip whisper punctuation, drive sentence breaks from pause length"
        return b
    }()
    private let autoEndPeriodCheckbox: NSButton = {
        let b = NSButton(frame: .zero)
        b.setButtonType(.switch)
        b.title = "Automatic trailing period to close final sentence"
        return b
    }()
    private let continuousSentencePauseField = NSTextField()
    private let continuousSentencePauseStepper = NSStepper()
    private let continuousSentencePauseMaxField = NSTextField()
    private let continuousSentencePauseMaxStepper = NSStepper()
    private let continuousTrailingPeriodField = NSTextField()
    private let continuousTrailingPeriodStepper = NSStepper()
    private let typedDelayField = NSTextField()
    private let typedDelayStepper = NSStepper()

    // Labels for numeric fields that use range validation. Captured during
    // layout so the delegate can toggle their text color on invalid input.
    private var threadsLabel: NSTextField?
    private var beamLabel: NSTextField?
    private var typedDelayLabel: NSTextField?
    private var silenceThresholdLabel: NSTextField?
    private var silenceSecondsLabel: NSTextField?
    private var continuousPauseLabel: NSTextField?
    private var continuousMaxChunkLabel: NSTextField?
    private var continuousPromptChainMaxCharsLabel: NSTextField?
    private var continuousSentencePauseLabel: NSTextField?
    private var continuousSentencePauseMaxLabel: NSTextField?
    private var continuousTrailingPeriodLabel: NSTextField?

    // MARK: - State

    private var inputDevices: [(uid: String, name: String)] = []
    private var hotkeyMonitor: Any?
    private var isRecordingHotkey = false

    private let categoryTitles = ["General", "Audio", "Transcription", "Output",
                                  "Advanced"]
    private var categoryViews: [NSView] = []
    private let sidebarTable = NSTableView()
    private let contentContainer = NSView()
    private var manageModelsController: ManageModelsWindowController?

    // Transcription pane row / section wrappers for conditional hiding
    // based on the selected backend.
    private var transcriptionModelRow: NSView?
    private var transcriptionApiKeyRow: NSView?
    private var transcriptionModelsFolderSection: NSView?

    // MARK: - Layout constants

    // Column width fits the longest label ("Transcription threads:").
    private static let labelColumnWidth: CGFloat = 160
    private static let labelToControl: CGFloat = 8
    private static let rowGap: CGFloat = 12
    private static let paneInset: CGFloat = 20
    private static let sectionGap: CGFloat = 18

    // MARK: - Init

    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 560),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false)
        window.title = "Push to Dictate Preferences"
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 640, height: 420)
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
        resetDefaultsButton.target = self
        resetDefaultsButton.action = #selector(resetToDefaults)

        silenceAutoStopCheckbox.target = self
        silenceAutoStopCheckbox.action = #selector(silenceAutoStopChanged)
        silenceThresholdField.delegate = self
        silenceSecondsField.delegate = self

        continuousDictationCheckbox.target = self
        continuousDictationCheckbox.action = #selector(continuousDictationChanged)
        continuousPauseField.delegate = self
        continuousMaxChunkField.delegate = self
        continuousPromptChainCheckbox.target = self
        continuousPromptChainCheckbox.action = #selector(continuousPromptChainChanged)
        continuousPromptChainMaxCharsField.delegate = self
        stripWhisperPunctuationCheckbox.target = self
        stripWhisperPunctuationCheckbox.action = #selector(stripWhisperPunctuationChanged)
        autoEndPeriodCheckbox.target = self
        autoEndPeriodCheckbox.action = #selector(autoEndPeriodChanged)
        continuousSentencePauseField.delegate = self
        continuousSentencePauseStepper.minValue = 0.1
        continuousSentencePauseStepper.maxValue = 5.0
        continuousSentencePauseStepper.increment = 0.1
        continuousSentencePauseStepper.valueWraps = false
        continuousSentencePauseStepper.target = self
        continuousSentencePauseStepper.action = #selector(continuousSentencePauseStepperChanged)

        continuousSentencePauseMaxField.delegate = self
        continuousSentencePauseMaxStepper.minValue = 0.2
        continuousSentencePauseMaxStepper.maxValue = 10.0
        continuousSentencePauseMaxStepper.increment = 0.1
        continuousSentencePauseMaxStepper.valueWraps = false
        continuousSentencePauseMaxStepper.target = self
        continuousSentencePauseMaxStepper.action = #selector(continuousSentencePauseMaxStepperChanged)

        continuousTrailingPeriodField.delegate = self
        continuousTrailingPeriodStepper.minValue = 0.2
        continuousTrailingPeriodStepper.maxValue = 20.0
        continuousTrailingPeriodStepper.increment = 0.1
        continuousTrailingPeriodStepper.valueWraps = false
        continuousTrailingPeriodStepper.target = self
        continuousTrailingPeriodStepper.action = #selector(continuousTrailingPeriodStepperChanged)

        typedDelayStepper.minValue = 5
        typedDelayStepper.maxValue = 100
        typedDelayStepper.increment = 1
        typedDelayStepper.valueWraps = false
        typedDelayStepper.target = self
        typedDelayStepper.action = #selector(typedDelayStepperChanged)
        typedDelayField.delegate = self
    }

    // MARK: - Layout (split view: sidebar + content)

    private func buildLayout() {
        guard let contentView = window?.contentView else { return }

        categoryViews = [
            buildGeneralPane(),
            buildAudioPane(),
            buildTranscriptionPane(),
            buildOutputPane(),
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

        // Wrap the pane in an NSScrollView so sections that exceed the
        // window height remain reachable. Each pane already carries its
        // own section insets via `placeSection`, so the scroll view adds
        // no extra padding of its own.
        let scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = false
        scroll.documentView = pane

        contentContainer.addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: contentContainer.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: contentContainer.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: contentContainer.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: contentContainer.bottomAnchor),
            // Pin the pane's width to the scroll view's clip view so sections
            // stretch across the full content area; let height grow freely so
            // overflow scrolls.
            pane.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            pane.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            pane.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor)
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

    // Bold section header used above each grouped section in the v2
    // preferences layout.
    private static func makeSectionHeader(_ text: String) -> NSTextField {
        let f = NSTextField(frame: .zero)
        f.isEditable = false
        f.isSelectable = false
        f.isBordered = false
        f.drawsBackground = false
        f.stringValue = text
        f.font = NSFont.boldSystemFont(ofSize: NSFont.systemFontSize)
        f.textColor = .labelColor
        f.translatesAutoresizingMaskIntoConstraints = false
        return f
    }

    // Small secondary-label caption used beneath checkboxes and buttons
    // (e.g. "Toggle mode only", "Restores all preferences to their original
    // values."). Wraps if the containing section has a width constraint.
    private static func makeCaption(_ text: String) -> NSTextField {
        let f = NSTextField(frame: .zero)
        f.isEditable = false
        f.isSelectable = false
        f.isBordered = false
        f.drawsBackground = false
        f.stringValue = text
        f.font = NSFont.systemFont(ofSize: 11)
        f.textColor = .secondaryLabelColor
        f.lineBreakMode = .byWordWrapping
        f.cell?.wraps = true
        f.cell?.isScrollable = false
        f.translatesAutoresizingMaskIntoConstraints = false
        return f
    }

    // Wraps a vertical stack of row views in a filled, rounded container
    // (layer-backed NSView instead of NSBox, so content height drives
    // the container's height via plain autolayout constraints) and
    // places a bold section header above it. Returned view is suitable
    // for use with `placeSection` inside a pane.
    private func buildSection(title: String, rows: [NSView]) -> NSView {
        let header = PreferencesWindowController.makeSectionHeader(title)

        let box = FlippedView()
        box.translatesAutoresizingMaskIntoConstraints = false
        box.wantsLayer = true
        // Subtle version-safe tint: works on light and dark backgrounds
        // without needing dynamic colors (which are 10.14+).
        box.layer?.backgroundColor = NSColor(white: 0.0, alpha: 0.05).cgColor
        box.layer?.cornerRadius = 8

        let topPad: CGFloat = 12
        let bottomPad: CGFloat = 12
        let leftPad: CGFloat = 14
        let rightPad: CGFloat = 14

        var previousBottom: NSLayoutYAxisAnchor = box.topAnchor
        var previousGap: CGFloat = topPad
        for row in rows {
            row.translatesAutoresizingMaskIntoConstraints = false
            box.addSubview(row)
            NSLayoutConstraint.activate([
                row.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: leftPad),
                row.topAnchor.constraint(equalTo: previousBottom, constant: previousGap),
                row.trailingAnchor.constraint(lessThanOrEqualTo: box.trailingAnchor,
                                              constant: -rightPad)
            ])
            previousBottom = row.bottomAnchor
            previousGap = PreferencesWindowController.rowGap
        }
        box.bottomAnchor.constraint(equalTo: previousBottom, constant: bottomPad).isActive = true

        let container = FlippedView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(header)
        container.addSubview(box)
        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            header.topAnchor.constraint(equalTo: container.topAnchor),
            box.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            box.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            box.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 6),
            box.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])
        return container
    }

    // Places a section inside a pane, pinned to the pane's leading /
    // trailing edges with `paneInset` and anchored vertically below the
    // given top anchor. Returns the section's bottom anchor so the next
    // section can chain off it.
    @discardableResult
    private func placeSection(_ section: NSView,
                              in pane: NSView,
                              below top: NSLayoutYAxisAnchor,
                              topConstant: CGFloat) -> NSLayoutYAxisAnchor {
        pane.addSubview(section)
        let inset = PreferencesWindowController.paneInset
        NSLayoutConstraint.activate([
            section.leadingAnchor.constraint(equalTo: pane.leadingAnchor, constant: inset),
            section.trailingAnchor.constraint(equalTo: pane.trailingAnchor, constant: -inset),
            section.topAnchor.constraint(equalTo: top, constant: topConstant)
        ])
        return section.bottomAnchor
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
        return placeRowWithLabel(labelText: labelText, control: control, in: pane,
                                 topAnchor: topAnchor, topConstant: topConstant,
                                 labelWidth: labelWidth).bottom
    }

    private func placeRowWithLabel(labelText: String,
                                   control: NSView,
                                   in pane: NSView,
                                   topAnchor: NSLayoutYAxisAnchor,
                                   topConstant: CGFloat,
                                   labelWidth: CGFloat)
        -> (bottom: NSLayoutYAxisAnchor, label: NSTextField) {
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
        return (control.bottomAnchor, label)
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
        let pane = FlippedView()
        pane.translatesAutoresizingMaskIntoConstraints = false

        let hotkeyRow = NSStackView(views: [hotkeyButton, hotkeyStatusLabel])
        hotkeyRow.orientation = .horizontal
        hotkeyRow.spacing = 8
        let backupRow = NSStackView(views: [exportButton, importButton])
        backupRow.orientation = .horizontal
        backupRow.spacing = 8

        let lw = PreferencesWindowController.widestLabelWidth(["Hotkey:"])
        let hotkeyLabeledRow = buildRowView(labelText: "Hotkey:",
                                            control: hotkeyRow, labelWidth: lw)

        let coloredStack = NSStackView(views: [
            coloredIconCheckbox,
            PreferencesWindowController.makeCaption(
                "When off, the icon follows the current light/dark preference.")
        ])
        coloredStack.orientation = .vertical
        coloredStack.alignment = .leading
        coloredStack.spacing = 2

        let startup = buildSection(title: "Startup & Shortcut",
                                   rows: [hotkeyLabeledRow, launchCheckbox])
        let appearance = buildSection(title: "Appearance",
                                      rows: [coloredStack])
        let settings = buildSection(title: "Settings",
                                    rows: [backupRow])

        let inset = PreferencesWindowController.paneInset
        let gap = PreferencesWindowController.sectionGap
        let after1 = placeSection(startup, in: pane, below: pane.topAnchor, topConstant: inset)
        let after2 = placeSection(appearance, in: pane, below: after1, topConstant: gap)
        let after3 = placeSection(settings, in: pane, below: after2, topConstant: gap)
        pane.bottomAnchor.constraint(greaterThanOrEqualTo: after3, constant: inset).isActive = true
        return pane
    }

    private func buildAudioPane() -> NSView {
        let pane = FlippedView()
        pane.translatesAutoresizingMaskIntoConstraints = false

        let lw = PreferencesWindowController.widestLabelWidth(
            ["Input device:", "Start sound:", "Stop sound:",
             "Silence threshold:", "Silence duration:"])

        let inputRow = buildRowView(labelText: "Input device:",
                                    control: inputDevicePopup, labelWidth: lw)
        let startRow = buildRowView(labelText: "Start sound:",
                                    control: startSoundPopup, labelWidth: lw)
        let stopRow = buildRowView(labelText: "Stop sound:",
                                   control: stopSoundPopup, labelWidth: lw)

        let autoStopStack = NSStackView(views: [
            silenceAutoStopCheckbox,
            PreferencesWindowController.makeCaption("Toggle mode only")
        ])
        autoStopStack.orientation = .vertical
        autoStopStack.alignment = .leading
        autoStopStack.spacing = 2

        silenceThresholdField.widthAnchor.constraint(equalToConstant: 80).isActive = true
        let thresholdHint = PreferencesWindowController.makeHint(
            "RMS level · default 0.01 · lower = more sensitive")
        let thresholdControl = NSStackView(views: [silenceThresholdField, thresholdHint])
        thresholdControl.orientation = .horizontal
        thresholdControl.spacing = 8
        let (thresholdRow, thresholdLabel) = buildLabeledRow(
            labelText: "Silence threshold:", control: thresholdControl, labelWidth: lw)
        silenceThresholdLabel = thresholdLabel

        silenceSecondsField.widthAnchor.constraint(equalToConstant: 80).isActive = true
        let secondsHint = PreferencesWindowController.makeHint(
            "seconds · default 4.0 · higher = more tolerant of pauses")
        let secondsControl = NSStackView(views: [silenceSecondsField, secondsHint])
        secondsControl.orientation = .horizontal
        secondsControl.spacing = 8
        let (secondsRow, secondsLabelRef) = buildLabeledRow(
            labelText: "Silence duration:", control: secondsControl, labelWidth: lw)
        silenceSecondsLabel = secondsLabelRef

        let input = buildSection(title: "Input", rows: [inputRow])
        let feedback = buildSection(title: "Feedback", rows: [startRow, stopRow])
        let silence = buildSection(title: "Silence Detection",
                                   rows: [autoStopStack, thresholdRow, secondsRow])

        let inset = PreferencesWindowController.paneInset
        let gap = PreferencesWindowController.sectionGap
        let after1 = placeSection(input, in: pane, below: pane.topAnchor, topConstant: inset)
        let after2 = placeSection(feedback, in: pane, below: after1, topConstant: gap)
        let after3 = placeSection(silence, in: pane, below: after2, topConstant: gap)
        pane.bottomAnchor.constraint(greaterThanOrEqualTo: after3, constant: inset).isActive = true
        return pane
    }

    private func buildTranscriptionPane() -> NSView {
        let pane = FlippedView()
        pane.translatesAutoresizingMaskIntoConstraints = false

        let lw = PreferencesWindowController.widestLabelWidth(
            ["Backend:", "Local model:", "OpenAI API key:", "Location:",
             "Pause:", "Max chunk:", "Max chars:"])

        let backendRow = buildRowView(labelText: "Backend:",
                                      control: backendPopup, labelWidth: lw)
        let modelControl = NSStackView(views: [modelPopup, manageModelsButton])
        modelControl.orientation = .horizontal
        modelControl.spacing = 8
        let modelRow = buildRowView(labelText: "Local model:",
                                    control: modelControl, labelWidth: lw)
        transcriptionModelRow = modelRow

        apiKeyField.widthAnchor.constraint(equalToConstant: 240).isActive = true
        let apiKeyRow = buildRowView(labelText: "OpenAI API key:",
                                     control: apiKeyField, labelWidth: lw)
        transcriptionApiKeyRow = apiKeyRow

        modelsFolderField.widthAnchor.constraint(equalToConstant: 200).isActive = true
        let modelsFolderControl = NSStackView(views: [
            modelsFolderField, modelsFolderChooseButton, modelsFolderClearButton
        ])
        modelsFolderControl.orientation = .horizontal
        modelsFolderControl.spacing = 6
        let modelsFolderRow = buildRowView(labelText: "Location:",
                                           control: modelsFolderControl, labelWidth: lw)

        let continuousStack = NSStackView(views: [
            continuousDictationCheckbox,
            PreferencesWindowController.makeCaption("Toggle mode only · experimental")
        ])
        continuousStack.orientation = .vertical
        continuousStack.alignment = .leading
        continuousStack.spacing = 2

        continuousPauseField.widthAnchor.constraint(equalToConstant: 80).isActive = true
        let pauseHint = PreferencesWindowController.makeHint(
            "seconds · default 0.5 · pause before text appears")
        let pauseControl = NSStackView(views: [continuousPauseField, pauseHint])
        pauseControl.orientation = .horizontal
        pauseControl.spacing = 8
        let (pauseRow, pauseLabelRef) = buildLabeledRow(
            labelText: "Pause:", control: pauseControl, labelWidth: lw)
        continuousPauseLabel = pauseLabelRef

        continuousMaxChunkField.widthAnchor.constraint(equalToConstant: 80).isActive = true
        let maxChunkHint = PreferencesWindowController.makeHint(
            "seconds · default 30.0 · min 5.0 · maximum speech before break")
        let maxChunkControl = NSStackView(views: [continuousMaxChunkField, maxChunkHint])
        maxChunkControl.orientation = .horizontal
        maxChunkControl.spacing = 8
        let (maxChunkRow, maxChunkLabelRef) = buildLabeledRow(
            labelText: "Max chunk:", control: maxChunkControl, labelWidth: lw)
        continuousMaxChunkLabel = maxChunkLabelRef

        continuousPromptChainMaxCharsField.widthAnchor.constraint(equalToConstant: 80).isActive = true
        let promptCharsHint = PreferencesWindowController.makeHint(
            "default 200 · min 100 · max 900 · higher = more context")
        let promptCharsControl = NSStackView(views: [
            continuousPromptChainMaxCharsField, promptCharsHint
        ])
        promptCharsControl.orientation = .horizontal
        promptCharsControl.spacing = 8
        let (promptCharsRow, promptCharsLabelRef) = buildLabeledRow(
            labelText: "Max chars:", control: promptCharsControl, labelWidth: lw)
        continuousPromptChainMaxCharsLabel = promptCharsLabelRef

        let backend = buildSection(title: "Backend",
                                   rows: [backendRow, modelRow, apiKeyRow])
        let modelsFolder = buildSection(title: "Models Folder",
                                        rows: [modelsFolderRow])
        transcriptionModelsFolderSection = modelsFolder
        let behavior = buildSection(title: "Behavior",
                                    rows: [continuousStack, pauseRow, maxChunkRow,
                                           continuousPromptChainCheckbox, promptCharsRow,
                                           stripWhisperPunctuationCheckbox])

        let inset = PreferencesWindowController.paneInset
        let gap = PreferencesWindowController.sectionGap
        let after1 = placeSection(backend, in: pane, below: pane.topAnchor, topConstant: inset)
        let after2 = placeSection(modelsFolder, in: pane, below: after1, topConstant: gap)
        let after3 = placeSection(behavior, in: pane, below: after2, topConstant: gap)
        pane.bottomAnchor.constraint(greaterThanOrEqualTo: after3, constant: inset).isActive = true
        return pane
    }

    // Builds a single [label, control] row as a self-contained NSView suitable
    // for use as an arranged subview of a vertical NSStackView (which collapses
    // hidden arranged subviews, including their spacing).
    private func buildRowView(labelText: String,
                              control: NSView,
                              labelWidth: CGFloat) -> NSView {
        return buildLabeledRow(labelText: labelText,
                               control: control,
                               labelWidth: labelWidth).row
    }

    // Variant that also returns the label so the delegate can toggle its
    // text color on invalid numeric input.
    private func buildLabeledRow(labelText: String,
                                 control: NSView,
                                 labelWidth: CGFloat)
        -> (row: NSView, label: NSTextField) {
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
        return (row, label)
    }

    // Small gray hint text that sits to the right of a numeric field,
    // e.g. "RMS level · default 0.01 · lower = more sensitive".
    private static func makeHint(_ text: String) -> NSTextField {
        let f = NSTextField(frame: .zero)
        f.isEditable = false; f.isSelectable = false
        f.isBordered = false; f.drawsBackground = false
        f.textColor = .secondaryLabelColor
        f.stringValue = text
        return f
    }

    private func buildOutputPane() -> NSView {
        let pane = FlippedView()
        pane.translatesAutoresizingMaskIntoConstraints = false

        let lw = PreferencesWindowController.widestLabelWidth(
            ["Method:", "Typed delay:",
             "Sentence pause:", "Window close:", "Trailing period:"])

        let radios = NSStackView(views: [injectionPasteRadio, injectionTypedRadio])
        radios.orientation = .horizontal
        radios.spacing = 16
        let methodRow = buildRowView(labelText: "Method:",
                                     control: radios, labelWidth: lw)

        typedDelayField.widthAnchor.constraint(equalToConstant: 60).isActive = true
        let delayHint = PreferencesWindowController.makeHint(
            "ms per character · default 8 · max 100 = slower keystrokes")
        let delayControl = NSStackView(views: [typedDelayField, typedDelayStepper, delayHint])
        delayControl.orientation = .horizontal
        delayControl.spacing = 8
        let (delayRow, delayLabelRef) = buildLabeledRow(
            labelText: "Typed delay:", control: delayControl, labelWidth: lw)
        typedDelayLabel = delayLabelRef

        continuousSentencePauseField.widthAnchor.constraint(equalToConstant: 80).isActive = true
        let sentencePauseControl = NSStackView(views: [
            continuousSentencePauseField,
            continuousSentencePauseStepper,
            PreferencesWindowController.makeHint("seconds · default 1.0")
        ])
        sentencePauseControl.orientation = .horizontal
        sentencePauseControl.spacing = 8
        let (sentencePauseRow, sentencePauseLabelRef) = buildLabeledRow(
            labelText: "Sentence pause:", control: sentencePauseControl, labelWidth: lw)
        continuousSentencePauseLabel = sentencePauseLabelRef

        continuousSentencePauseMaxField.widthAnchor.constraint(equalToConstant: 80).isActive = true
        let sentencePauseMaxControl = NSStackView(views: [
            continuousSentencePauseMaxField,
            continuousSentencePauseMaxStepper,
            PreferencesWindowController.makeHint("seconds · default 2.0")
        ])
        sentencePauseMaxControl.orientation = .horizontal
        sentencePauseMaxControl.spacing = 8
        let (sentencePauseMaxRow, sentencePauseMaxLabelRef) = buildLabeledRow(
            labelText: "Window close:", control: sentencePauseMaxControl, labelWidth: lw)
        continuousSentencePauseMaxLabel = sentencePauseMaxLabelRef

        continuousTrailingPeriodField.widthAnchor.constraint(equalToConstant: 80).isActive = true
        let trailingPeriodControl = NSStackView(views: [
            continuousTrailingPeriodField,
            continuousTrailingPeriodStepper,
            PreferencesWindowController.makeHint("seconds · default 4.0")
        ])
        trailingPeriodControl.orientation = .horizontal
        trailingPeriodControl.spacing = 8
        let (trailingPeriodRow, trailingPeriodLabelRef) = buildLabeledRow(
            labelText: "Trailing period:", control: trailingPeriodControl, labelWidth: lw)
        continuousTrailingPeriodLabel = trailingPeriodLabelRef

        let notesText = PreferencesWindowController.makeCaption(
            "Typed insertion is slower but can work better in apps where paste is unreliable.")

        let textInsertion = buildSection(title: "Text Insertion",
                                         rows: [methodRow, delayRow])
        let sentenceHandling = buildSection(title: "Sentence Handling",
                                            rows: [autoEndPeriodCheckbox,
                                                   sentencePauseRow,
                                                   sentencePauseMaxRow,
                                                   trailingPeriodRow])
        let notes = buildSection(title: "Notes", rows: [notesText])

        let inset = PreferencesWindowController.paneInset
        let gap = PreferencesWindowController.sectionGap
        let after1 = placeSection(textInsertion, in: pane, below: pane.topAnchor, topConstant: inset)
        let after2 = placeSection(sentenceHandling, in: pane, below: after1, topConstant: gap)
        let after3 = placeSection(notes, in: pane, below: after2, topConstant: gap)
        pane.bottomAnchor.constraint(greaterThanOrEqualTo: after3, constant: inset).isActive = true
        return pane
    }

    private func buildAdvancedPane() -> NSView {
        let pane = FlippedView()
        pane.translatesAutoresizingMaskIntoConstraints = false

        let lw = PreferencesWindowController.widestLabelWidth(
            ["Transcription threads:", "Accuracy:"])

        threadsField.widthAnchor.constraint(equalToConstant: 60).isActive = true
        let threadsHint = PreferencesWindowController.makeHint(
            PreferencesWindowController.threadsHintString())
        let threadsControl = NSStackView(views: [threadsField, threadsStepper, threadsHint])
        threadsControl.orientation = .horizontal
        threadsControl.spacing = 8
        let (threadsRow, threadsLabelRef) = buildLabeledRow(
            labelText: "Transcription threads:", control: threadsControl, labelWidth: lw)
        threadsLabel = threadsLabelRef

        beamField.widthAnchor.constraint(equalToConstant: 60).isActive = true
        let beamHint = PreferencesWindowController.makeHint(
            "1 = fastest · 3 = default · 10 = slowest")
        let beamControl = NSStackView(views: [beamField, beamStepper, beamHint])
        beamControl.orientation = .horizontal
        beamControl.spacing = 8
        let (beamRow, beamLabelRef) = buildLabeledRow(
            labelText: "Accuracy:", control: beamControl, labelWidth: lw)
        beamLabel = beamLabelRef

        let debugRow = NSStackView(views: [saveDebugRecordingsCheckbox,
                                           clearDebugRecordingsButton])
        debugRow.orientation = .horizontal
        debugRow.spacing = 12
        let loggingRow = NSStackView(views: [logEverythingCheckbox, clearLogButton])
        loggingRow.orientation = .horizontal
        loggingRow.spacing = 12

        let resetStack = NSStackView(views: [
            resetDefaultsButton,
            PreferencesWindowController.makeCaption(
                "Restores all preferences to their original values.")
        ])
        resetStack.orientation = .vertical
        resetStack.alignment = .leading
        resetStack.spacing = 4

        let performance = buildSection(title: "Performance",
                                       rows: [threadsRow, beamRow])
        let diagnostics = buildSection(title: "Diagnostics",
                                       rows: [debugRow, loggingRow])
        let reset = buildSection(title: "Reset", rows: [resetStack])

        let inset = PreferencesWindowController.paneInset
        let gap = PreferencesWindowController.sectionGap
        let after1 = placeSection(performance, in: pane, below: pane.topAnchor, topConstant: inset)
        let after2 = placeSection(diagnostics, in: pane, below: after1, topConstant: gap)
        let after3 = placeSection(reset, in: pane, below: after2, topConstant: gap)
        pane.bottomAnchor.constraint(greaterThanOrEqualTo: after3, constant: inset).isActive = true
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
        silenceAutoStopCheckbox.state = Preferences.shared.silenceAutoStopEnabled ? .on : .off
        silenceThresholdField.stringValue = String(format: "%.3f",
            Preferences.shared.silenceAutoStopThreshold)
        silenceSecondsField.stringValue = String(format: "%.1f",
            Preferences.shared.silenceAutoStopSeconds)
        continuousDictationCheckbox.state =
            Preferences.shared.continuousDictationEnabled ? .on : .off
        continuousPauseField.stringValue = String(format: "%.1f",
            Preferences.shared.continuousDictationPauseSeconds)
        continuousMaxChunkField.stringValue = String(format: "%.1f",
            Preferences.shared.continuousDictationMaxChunkSeconds)
        continuousPromptChainCheckbox.state =
            Preferences.shared.continuousDictationPromptChainEnabled ? .on : .off
        continuousPromptChainMaxCharsField.integerValue =
            Preferences.shared.continuousDictationPromptChainMaxChars
        stripWhisperPunctuationCheckbox.state =
            Preferences.shared.continuousDictationStripWhisperPunctuation ? .on : .off
        autoEndPeriodCheckbox.state =
            Preferences.shared.continuousDictationAutoEndPeriod ? .on : .off
        continuousSentencePauseField.stringValue = String(format: "%.1f",
            Preferences.shared.continuousDictationSentencePauseSeconds)
        continuousSentencePauseStepper.doubleValue =
            Preferences.shared.continuousDictationSentencePauseSeconds
        continuousSentencePauseMaxField.stringValue = String(format: "%.1f",
            Preferences.shared.continuousDictationSentencePauseMaxSeconds)
        continuousSentencePauseMaxStepper.doubleValue =
            Preferences.shared.continuousDictationSentencePauseMaxSeconds
        continuousTrailingPeriodField.stringValue = String(format: "%.1f",
            Preferences.shared.continuousDictationTrailingPeriodSeconds)
        continuousTrailingPeriodStepper.doubleValue =
            Preferences.shared.continuousDictationTrailingPeriodSeconds
        let typedDelay = Preferences.shared.typedKeystrokeDelayMs
        typedDelayField.integerValue = typedDelay
        typedDelayStepper.integerValue = typedDelay
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
        transcriptionModelsFolderSection?.isHidden = isOpenAI
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

    @objc private func silenceAutoStopChanged() {
        Preferences.shared.silenceAutoStopEnabled = (silenceAutoStopCheckbox.state == .on)
        // Mutual exclusion is enforced in the Preferences setter; reflect the
        // flip back in the UI so the user sees the other checkbox clear.
        continuousDictationCheckbox.state =
            Preferences.shared.continuousDictationEnabled ? .on : .off
    }

    @objc private func continuousDictationChanged() {
        Preferences.shared.continuousDictationEnabled =
            (continuousDictationCheckbox.state == .on)
        silenceAutoStopCheckbox.state =
            Preferences.shared.silenceAutoStopEnabled ? .on : .off
    }

    @objc private func continuousPromptChainChanged() {
        Preferences.shared.continuousDictationPromptChainEnabled =
            (continuousPromptChainCheckbox.state == .on)
    }

    @objc private func stripWhisperPunctuationChanged() {
        Preferences.shared.continuousDictationStripWhisperPunctuation =
            (stripWhisperPunctuationCheckbox.state == .on)
    }

    @objc private func autoEndPeriodChanged() {
        Preferences.shared.continuousDictationAutoEndPeriod =
            (autoEndPeriodCheckbox.state == .on)
    }

    @objc private func typedDelayStepperChanged() {
        let value = typedDelayStepper.integerValue
        typedDelayField.integerValue = value
        Preferences.shared.typedKeystrokeDelayMs = value
    }

    @objc private func continuousSentencePauseStepperChanged() {
        let chunkPause = Preferences.shared.continuousDictationPauseSeconds
        let raw = continuousSentencePauseStepper.doubleValue
        let clamped = max(chunkPause + 0.1, min(5.0, raw))
        applyCascadingSentencePause(clamped)
    }

    @objc private func continuousSentencePauseMaxStepperChanged() {
        let minVal = Preferences.shared.continuousDictationSentencePauseSeconds + 0.1
        let raw = continuousSentencePauseMaxStepper.doubleValue
        let clamped = max(minVal, min(10.0, raw))
        continuousSentencePauseMaxField.stringValue = String(format: "%.1f", clamped)
        Preferences.shared.continuousDictationSentencePauseMaxSeconds = clamped
        setNumericFieldValid(field: continuousSentencePauseMaxField,
                             label: continuousSentencePauseMaxLabel, valid: true)
    }

    @objc private func continuousTrailingPeriodStepperChanged() {
        let minVal = Preferences.shared.continuousDictationSentencePauseMaxSeconds + 0.1
        let raw = continuousTrailingPeriodStepper.doubleValue
        let clamped = max(minVal, min(20.0, raw))
        continuousTrailingPeriodField.stringValue = String(format: "%.1f", clamped)
        Preferences.shared.continuousDictationTrailingPeriodSeconds = clamped
        setNumericFieldValid(field: continuousTrailingPeriodField,
                             label: continuousTrailingPeriodLabel, valid: true)
    }

    // Cascade an edit to the Sentence pause field through to Window close
    // and Trailing period, preserving each dependent's current ratio to
    // the old sentence-pause value. Call this whenever the sentence-pause
    // field or stepper validates to a new value.
    private func applyCascadingSentencePause(_ newP: Double) {
        let prefs = Preferences.shared
        let oldP = prefs.continuousDictationSentencePauseSeconds
        continuousSentencePauseField.stringValue = String(format: "%.1f", newP)
        continuousSentencePauseStepper.doubleValue = newP
        prefs.continuousDictationSentencePauseSeconds = newP
        setNumericFieldValid(field: continuousSentencePauseField,
                             label: continuousSentencePauseLabel, valid: true)
        guard oldP > 0 else { return }
        let scale = newP / oldP
        let newMax = min(10.0, max(newP + 0.1,
                                   prefs.continuousDictationSentencePauseMaxSeconds * scale))
        let newTrail = min(20.0, max(newMax + 0.1,
                                     prefs.continuousDictationTrailingPeriodSeconds * scale))
        prefs.continuousDictationSentencePauseMaxSeconds = newMax
        prefs.continuousDictationTrailingPeriodSeconds = newTrail
        continuousSentencePauseMaxField.stringValue = String(format: "%.1f", newMax)
        continuousSentencePauseMaxStepper.doubleValue = newMax
        continuousTrailingPeriodField.stringValue = String(format: "%.1f", newTrail)
        continuousTrailingPeriodStepper.doubleValue = newTrail
        setNumericFieldValid(field: continuousSentencePauseMaxField,
                             label: continuousSentencePauseMaxLabel, valid: true)
        setNumericFieldValid(field: continuousTrailingPeriodField,
                             label: continuousTrailingPeriodLabel, valid: true)
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

    @objc private func resetToDefaults() {
        Preferences.shared.resetUserPreferences()
        // Hotkey, model selection, mode, colored-icon toggle all influence
        // the status-bar UI. Notify the main controller so icon + menu-bar
        // menu re-pick up fresh values along with the Preferences UI itself.
        onHotkeyChanged?()
        onColoredIconChanged?()
        refreshAll()
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

    // Validation: mark field+label red for out-of-range, beep and revert on
    // commit (focus loss). Only one of the five numeric fields can be the
    // sender; the first two branches handle plain text (api key, models folder).
    func controlTextDidChange(_ obj: Notification) {
        guard let field = obj.object as? NSTextField else { return }
        if field === apiKeyField {
            Preferences.shared.openAIAPIKey = apiKeyField.stringValue
            return
        }
        if field === modelsFolderField {
            let text = modelsFolderField.stringValue
            if text == Preferences.userModelsDirectory.path {
                Preferences.shared.modelsDirectory = ""
            } else {
                Preferences.shared.modelsDirectory = text
            }
            refreshModelPopup()
            return
        }
        // Numeric fields: per-keystroke, only color the field red/normal
        // based on current validity. Do NOT write to prefs or cascade here;
        // intermediate states while typing (e.g. "1." on the way to "1.2")
        // would otherwise overwrite the field's stringValue mid-edit.
        markNumericFieldValidity(field)
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        guard let field = obj.object as? NSTextField else { return }
        if field === apiKeyField || field === modelsFolderField { return }
        // Commit point: on Enter / Tab / blur. Write to prefs, sync steppers,
        // apply cascades if valid; beep + revert if not.
        if numericFieldIsValid(field) {
            validateNumericField(field)
        } else {
            NSSound.beep()
            revertNumericFieldToPref(field)
        }
    }

    // Visual-only: color the given numeric field (and its captured label)
    // red if the current text fails `numericFieldIsValid`, normal otherwise.
    // Lookup table mirrors the numeric fields validated elsewhere.
    private func markNumericFieldValidity(_ field: NSTextField) {
        let valid = numericFieldIsValid(field)
        let label: NSTextField?
        switch field {
        case threadsField: label = threadsLabel
        case beamField: label = beamLabel
        case typedDelayField: label = typedDelayLabel
        case silenceThresholdField: label = silenceThresholdLabel
        case silenceSecondsField: label = silenceSecondsLabel
        case continuousPauseField: label = continuousPauseLabel
        case continuousMaxChunkField: label = continuousMaxChunkLabel
        case continuousPromptChainMaxCharsField: label = continuousPromptChainMaxCharsLabel
        case continuousSentencePauseField: label = continuousSentencePauseLabel
        case continuousSentencePauseMaxField: label = continuousSentencePauseMaxLabel
        case continuousTrailingPeriodField: label = continuousTrailingPeriodLabel
        default: return
        }
        setNumericFieldValid(field: field, label: label, valid: valid)
    }

    private func validateNumericField(_ field: NSTextField) {
        switch field {
        case threadsField:
            let logical = ProcessInfo.processInfo.activeProcessorCount
            if let v = Int(threadsField.stringValue), v >= 1, v <= logical {
                threadsStepper.integerValue = v
                Preferences.shared.transcriptionThreads = v
                setNumericFieldValid(field: threadsField, label: threadsLabel, valid: true)
            } else {
                setNumericFieldValid(field: threadsField, label: threadsLabel, valid: false)
            }
        case beamField:
            if let v = Int(beamField.stringValue), v >= 1, v <= 10 {
                beamStepper.integerValue = v
                Preferences.shared.beamSize = v
                setNumericFieldValid(field: beamField, label: beamLabel, valid: true)
            } else {
                setNumericFieldValid(field: beamField, label: beamLabel, valid: false)
            }
        case typedDelayField:
            if let v = Int(typedDelayField.stringValue), v >= 5, v <= 100 {
                typedDelayStepper.integerValue = v
                Preferences.shared.typedKeystrokeDelayMs = v
                setNumericFieldValid(field: typedDelayField, label: typedDelayLabel, valid: true)
            } else {
                setNumericFieldValid(field: typedDelayField, label: typedDelayLabel, valid: false)
            }
        case silenceThresholdField:
            if let v = Double(silenceThresholdField.stringValue), v >= 0.01 {
                Preferences.shared.silenceAutoStopThreshold = v
                setNumericFieldValid(field: silenceThresholdField,
                                     label: silenceThresholdLabel, valid: true)
            } else {
                setNumericFieldValid(field: silenceThresholdField,
                                     label: silenceThresholdLabel, valid: false)
            }
        case silenceSecondsField:
            if let v = Double(silenceSecondsField.stringValue), v >= 1.2 {
                Preferences.shared.silenceAutoStopSeconds = v
                setNumericFieldValid(field: silenceSecondsField,
                                     label: silenceSecondsLabel, valid: true)
            } else {
                setNumericFieldValid(field: silenceSecondsField,
                                     label: silenceSecondsLabel, valid: false)
            }
        case continuousPauseField:
            if let v = Double(continuousPauseField.stringValue), v >= 0.3, v <= 2.0 {
                Preferences.shared.continuousDictationPauseSeconds = v
                setNumericFieldValid(field: continuousPauseField,
                                     label: continuousPauseLabel, valid: true)
            } else {
                setNumericFieldValid(field: continuousPauseField,
                                     label: continuousPauseLabel, valid: false)
            }
        case continuousMaxChunkField:
            if let v = Double(continuousMaxChunkField.stringValue), v >= 5.0, v <= 30.0 {
                Preferences.shared.continuousDictationMaxChunkSeconds = v
                setNumericFieldValid(field: continuousMaxChunkField,
                                     label: continuousMaxChunkLabel, valid: true)
            } else {
                setNumericFieldValid(field: continuousMaxChunkField,
                                     label: continuousMaxChunkLabel, valid: false)
            }
        case continuousPromptChainMaxCharsField:
            if let v = Int(continuousPromptChainMaxCharsField.stringValue),
               v >= 100, v <= 900 {
                Preferences.shared.continuousDictationPromptChainMaxChars = v
                setNumericFieldValid(field: continuousPromptChainMaxCharsField,
                                     label: continuousPromptChainMaxCharsLabel, valid: true)
            } else {
                setNumericFieldValid(field: continuousPromptChainMaxCharsField,
                                     label: continuousPromptChainMaxCharsLabel, valid: false)
            }
        case continuousSentencePauseField:
            let chunkPause = Preferences.shared.continuousDictationPauseSeconds
            if let v = Double(continuousSentencePauseField.stringValue),
               v > chunkPause, v <= 5.0 {
                applyCascadingSentencePause(v)
            } else {
                setNumericFieldValid(field: continuousSentencePauseField,
                                     label: continuousSentencePauseLabel, valid: false)
            }
        case continuousSentencePauseMaxField:
            let minVal = Preferences.shared.continuousDictationSentencePauseSeconds
            if let v = Double(continuousSentencePauseMaxField.stringValue),
               v > minVal, v <= 10.0 {
                Preferences.shared.continuousDictationSentencePauseMaxSeconds = v
                continuousSentencePauseMaxStepper.doubleValue = v
                setNumericFieldValid(field: continuousSentencePauseMaxField,
                                     label: continuousSentencePauseMaxLabel, valid: true)
            } else {
                setNumericFieldValid(field: continuousSentencePauseMaxField,
                                     label: continuousSentencePauseMaxLabel, valid: false)
            }
        case continuousTrailingPeriodField:
            let minVal = Preferences.shared.continuousDictationSentencePauseMaxSeconds
            if let v = Double(continuousTrailingPeriodField.stringValue),
               v > minVal, v <= 20.0 {
                Preferences.shared.continuousDictationTrailingPeriodSeconds = v
                continuousTrailingPeriodStepper.doubleValue = v
                setNumericFieldValid(field: continuousTrailingPeriodField,
                                     label: continuousTrailingPeriodLabel, valid: true)
            } else {
                setNumericFieldValid(field: continuousTrailingPeriodField,
                                     label: continuousTrailingPeriodLabel, valid: false)
            }
        default:
            break
        }
    }

    private func numericFieldIsValid(_ field: NSTextField) -> Bool {
        switch field {
        case threadsField:
            let logical = ProcessInfo.processInfo.activeProcessorCount
            guard let v = Int(threadsField.stringValue) else { return false }
            return v >= 1 && v <= logical
        case beamField:
            guard let v = Int(beamField.stringValue) else { return false }
            return v >= 1 && v <= 10
        case typedDelayField:
            guard let v = Int(typedDelayField.stringValue) else { return false }
            return v >= 5 && v <= 100
        case silenceThresholdField:
            guard let v = Double(silenceThresholdField.stringValue) else { return false }
            return v >= 0.01
        case silenceSecondsField:
            guard let v = Double(silenceSecondsField.stringValue) else { return false }
            return v >= 1.2
        case continuousPauseField:
            guard let v = Double(continuousPauseField.stringValue) else { return false }
            return v >= 0.3 && v <= 2.0
        case continuousMaxChunkField:
            guard let v = Double(continuousMaxChunkField.stringValue) else { return false }
            return v >= 5.0 && v <= 30.0
        case continuousPromptChainMaxCharsField:
            guard let v = Int(continuousPromptChainMaxCharsField.stringValue) else { return false }
            return v >= 100 && v <= 900
        case continuousSentencePauseField:
            let chunkPause = Preferences.shared.continuousDictationPauseSeconds
            guard let v = Double(continuousSentencePauseField.stringValue) else { return false }
            return v > chunkPause && v <= 5.0
        case continuousSentencePauseMaxField:
            let minVal = Preferences.shared.continuousDictationSentencePauseSeconds
            guard let v = Double(continuousSentencePauseMaxField.stringValue) else { return false }
            return v > minVal && v <= 10.0
        case continuousTrailingPeriodField:
            let minVal = Preferences.shared.continuousDictationSentencePauseMaxSeconds
            guard let v = Double(continuousTrailingPeriodField.stringValue) else { return false }
            return v > minVal && v <= 20.0
        default:
            return true
        }
    }

    private func revertNumericFieldToPref(_ field: NSTextField) {
        switch field {
        case threadsField:
            let v = Preferences.shared.transcriptionThreads
            threadsField.integerValue = v
            threadsStepper.integerValue = v
            setNumericFieldValid(field: threadsField, label: threadsLabel, valid: true)
        case beamField:
            let v = Preferences.shared.beamSize
            beamField.integerValue = v
            beamStepper.integerValue = v
            setNumericFieldValid(field: beamField, label: beamLabel, valid: true)
        case typedDelayField:
            let v = Preferences.shared.typedKeystrokeDelayMs
            typedDelayField.integerValue = v
            typedDelayStepper.integerValue = v
            setNumericFieldValid(field: typedDelayField, label: typedDelayLabel, valid: true)
        case silenceThresholdField:
            silenceThresholdField.stringValue = String(format: "%.3f",
                Preferences.shared.silenceAutoStopThreshold)
            setNumericFieldValid(field: silenceThresholdField,
                                 label: silenceThresholdLabel, valid: true)
        case silenceSecondsField:
            silenceSecondsField.stringValue = String(format: "%.1f",
                Preferences.shared.silenceAutoStopSeconds)
            setNumericFieldValid(field: silenceSecondsField,
                                 label: silenceSecondsLabel, valid: true)
        case continuousPauseField:
            continuousPauseField.stringValue = String(format: "%.1f",
                Preferences.shared.continuousDictationPauseSeconds)
            setNumericFieldValid(field: continuousPauseField,
                                 label: continuousPauseLabel, valid: true)
        case continuousMaxChunkField:
            continuousMaxChunkField.stringValue = String(format: "%.1f",
                Preferences.shared.continuousDictationMaxChunkSeconds)
            setNumericFieldValid(field: continuousMaxChunkField,
                                 label: continuousMaxChunkLabel, valid: true)
        case continuousPromptChainMaxCharsField:
            continuousPromptChainMaxCharsField.integerValue =
                Preferences.shared.continuousDictationPromptChainMaxChars
            setNumericFieldValid(field: continuousPromptChainMaxCharsField,
                                 label: continuousPromptChainMaxCharsLabel, valid: true)
        case continuousSentencePauseField:
            continuousSentencePauseField.stringValue = String(format: "%.1f",
                Preferences.shared.continuousDictationSentencePauseSeconds)
            continuousSentencePauseStepper.doubleValue =
                Preferences.shared.continuousDictationSentencePauseSeconds
            setNumericFieldValid(field: continuousSentencePauseField,
                                 label: continuousSentencePauseLabel, valid: true)
        case continuousSentencePauseMaxField:
            continuousSentencePauseMaxField.stringValue = String(format: "%.1f",
                Preferences.shared.continuousDictationSentencePauseMaxSeconds)
            continuousSentencePauseMaxStepper.doubleValue =
                Preferences.shared.continuousDictationSentencePauseMaxSeconds
            setNumericFieldValid(field: continuousSentencePauseMaxField,
                                 label: continuousSentencePauseMaxLabel, valid: true)
        case continuousTrailingPeriodField:
            continuousTrailingPeriodField.stringValue = String(format: "%.1f",
                Preferences.shared.continuousDictationTrailingPeriodSeconds)
            continuousTrailingPeriodStepper.doubleValue =
                Preferences.shared.continuousDictationTrailingPeriodSeconds
            setNumericFieldValid(field: continuousTrailingPeriodField,
                                 label: continuousTrailingPeriodLabel, valid: true)
        default:
            break
        }
    }

    private func setNumericFieldValid(field: NSTextField, label: NSTextField?, valid: Bool) {
        field.textColor = valid ? NSColor.textColor : NSColor.systemRed
        label?.textColor = valid ? NSColor.labelColor : NSColor.systemRed
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


