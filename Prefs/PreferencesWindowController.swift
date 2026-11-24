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
    var onUpdateCheckResult: ((UpdateCheckResult) -> Void)?
    var onUpdateSkipped: ((String) -> Void)?

    // MARK: - Inline update check state

    private let updateCheckButton: NSButton = {
        let b = NSButton(frame: .zero)
        b.bezelStyle = .rounded
        b.title = "Check for Updates\u{2026}"
        return b
    }()
    private let updateSpinner: NSProgressIndicator = {
        let s = NSProgressIndicator(frame: .zero)
        s.style = .spinning
        s.isIndeterminate = true
        s.controlSize = .small
        return s
    }()
    private let updateStatusLabel: NSTextField = {
        let f = NSTextField(frame: .zero)
        f.isEditable = false; f.isSelectable = false
        f.isBordered = false; f.drawsBackground = false
        f.font = NSFont.boldSystemFont(ofSize: 14)
        f.alignment = .center
        return f
    }()
    private let updateDetailLabel: NSTextField = {
        let f = NSTextField(frame: .zero)
        f.isEditable = false; f.isSelectable = false
        f.isBordered = false; f.drawsBackground = false
        f.font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
        f.textColor = .secondaryLabelColor
        f.lineBreakMode = .byWordWrapping
        f.cell?.wraps = true
        f.cell?.isScrollable = false
        f.preferredMaxLayoutWidth = 360
        f.alignment = .center
        return f
    }()
    private let updateDownloadButton: NSButton = {
        let b = NSButton(frame: .zero)
        b.bezelStyle = .rounded
        b.title = "Download & Install"
        return b
    }()
    private let updateOpenReleaseButton: NSButton = {
        let b = NSButton(frame: .zero)
        b.bezelStyle = .rounded
        b.title = "Open Release Page"
        return b
    }()
    private let updateSkipButton: NSButton = {
        let b = NSButton(frame: .zero)
        b.bezelStyle = .rounded
        b.title = "Skip This Update"
        return b
    }()
    private let updateProgressBar: NSProgressIndicator = {
        let p = NSProgressIndicator(frame: .zero)
        p.style = .bar
        p.isIndeterminate = false
        p.minValue = 0
        p.maxValue = 1
        p.doubleValue = 0
        p.controlSize = .small
        return p
    }()
    private let updateProgressLabel: NSTextField = {
        let f = NSTextField(frame: .zero)
        f.isEditable = false; f.isSelectable = false
        f.isBordered = false; f.drawsBackground = false
        f.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        f.textColor = .secondaryLabelColor
        f.alignment = .center
        return f
    }()
    private var updateStatusGroup: NSStackView?
    private var updateButtonRow: NSStackView?
    private var updateProgressGroup: NSStackView?
    private var pendingReleaseURL: URL?
    private var pendingDownloadURL: URL?
    private var pendingLatestVersion: String?
    private var updateInstaller: UpdateInstaller?

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
        b.title = "Auto stop (toggle mode only)"
        return b
    }()
    private let silenceThresholdField = NSTextField()
    private let silenceThresholdStepper = NSStepper()
    private let silenceSecondsField = NSTextField()
    private let silenceSecondsStepper = NSStepper()
    private let continuousDictationCheckbox: NSButton = {
        let b = NSButton(frame: .zero)
        b.setButtonType(.switch)
        b.title = "Continuous dictation (experimental)"
        return b
    }()
    private let continuousPauseField = NSTextField()
    private let continuousPauseStepper = NSStepper()
    private let continuousMaxChunkField = NSTextField()
    private let continuousMaxChunkStepper = NSStepper()
    private let continuousPromptChainCheckbox: NSButton = {
        let b = NSButton(frame: .zero)
        b.setButtonType(.switch)
        b.title = "Feed prior transcript to whisper as context"
        return b
    }()
    private let continuousPromptChainMaxCharsField = NSTextField()
    private let continuousPromptChainMaxCharsStepper = NSStepper()
    private let stripWhisperPunctuationCheckbox: NSButton = {
        let b = NSButton(frame: .zero)
        b.setButtonType(.switch)
        b.title = "Strip whisper punctuation, drive sentence breaks from pause length"
        return b
    }()
    private let autoEndPeriodCheckbox: NSButton = {
        let b = NSButton(frame: .zero)
        b.setButtonType(.switch)
        b.title = "Auto trailing period"
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

    private let transcriptProcessingCheckbox: NSButton = {
        let b = NSButton(frame: .zero)
        b.setButtonType(.switch)
        b.title = "Apply transcript processing"
        return b
    }()
    private let removeNonSpeechAnnotationsCheckbox: NSButton = {
        let b = NSButton(frame: .zero)
        b.setButtonType(.switch)
        b.title = "Remove non-speech annotations"
        return b
    }()
    private let normalizeCapitalizationCheckbox: NSButton = {
        let b = NSButton(frame: .zero)
        b.setButtonType(.switch)
        b.title = "Normalize capitalization"
        return b
    }()
    private let applyProperNounFixupsCheckbox: NSButton = {
        let b = NSButton(frame: .zero)
        b.setButtonType(.switch)
        b.title = "Capitalize nouns"
        return b
    }()
    private let applyTextSubstitutionsCheckbox: NSButton = {
        let b = NSButton(frame: .zero)
        b.setButtonType(.switch)
        b.title = "Capitalize abbreviations"
        return b
    }()
    private let capitalizeFirstLetterCheckbox: NSButton = {
        let b = NSButton(frame: .zero)
        b.setButtonType(.switch)
        b.title = "Capitalize first letter at line start"
        return b
    }()

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
                                  "Advanced", "About"]
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

    func showAbout(startUpdateCheck: Bool = false) {
        showPreferences()
        if let index = categoryTitles.firstIndex(of: "About") {
            sidebarTable.selectRowIndexes(IndexSet(integer: index),
                                          byExtendingSelection: false)
            showCategory(at: index)
        }
        if startUpdateCheck {
            runUpdateCheck()
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

        transcriptProcessingCheckbox.target = self
        transcriptProcessingCheckbox.action = #selector(transcriptProcessingChanged)
        removeNonSpeechAnnotationsCheckbox.target = self
        removeNonSpeechAnnotationsCheckbox.action = #selector(removeNonSpeechAnnotationsChanged)
        normalizeCapitalizationCheckbox.target = self
        normalizeCapitalizationCheckbox.action = #selector(normalizeCapitalizationChanged)
        applyProperNounFixupsCheckbox.target = self
        applyProperNounFixupsCheckbox.action = #selector(applyProperNounFixupsChanged)
        applyTextSubstitutionsCheckbox.target = self
        applyTextSubstitutionsCheckbox.action = #selector(applyTextSubstitutionsChanged)
        capitalizeFirstLetterCheckbox.target = self
        capitalizeFirstLetterCheckbox.action = #selector(capitalizeFirstLetterChanged)
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

        silenceThresholdStepper.minValue = 0.0001
        silenceThresholdStepper.maxValue = 0.5
        silenceThresholdStepper.increment = 0.001
        silenceThresholdStepper.valueWraps = false
        silenceThresholdStepper.target = self
        silenceThresholdStepper.action = #selector(silenceThresholdStepperChanged)

        silenceSecondsStepper.minValue = 1.2
        silenceSecondsStepper.maxValue = 10.0
        silenceSecondsStepper.increment = 0.1
        silenceSecondsStepper.valueWraps = false
        silenceSecondsStepper.target = self
        silenceSecondsStepper.action = #selector(silenceSecondsStepperChanged)

        continuousPauseStepper.minValue = 0.3
        continuousPauseStepper.maxValue = 2.0
        continuousPauseStepper.increment = 0.1
        continuousPauseStepper.valueWraps = false
        continuousPauseStepper.target = self
        continuousPauseStepper.action = #selector(continuousPauseStepperChanged)

        continuousMaxChunkStepper.minValue = 5.0
        continuousMaxChunkStepper.maxValue = 30.0
        continuousMaxChunkStepper.increment = 0.5
        continuousMaxChunkStepper.valueWraps = false
        continuousMaxChunkStepper.target = self
        continuousMaxChunkStepper.action = #selector(continuousMaxChunkStepperChanged)

        continuousPromptChainMaxCharsStepper.minValue = 100
        continuousPromptChainMaxCharsStepper.maxValue = 900
        continuousPromptChainMaxCharsStepper.increment = 10
        continuousPromptChainMaxCharsStepper.valueWraps = false
        continuousPromptChainMaxCharsStepper.target = self
        continuousPromptChainMaxCharsStepper.action =
            #selector(continuousPromptChainMaxCharsStepperChanged)
    }

    // MARK: - Layout (split view: sidebar + content)

    private func buildLayout() {
        guard let contentView = window?.contentView else { return }

        categoryViews = [
            buildGeneralPane(),
            buildAudioPane(),
            buildTranscriptionPane(),
            buildOutputPane(),
            buildAdvancedPane(),
            buildAboutPane()
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
             "Silence level:", "Silence duration:"])

        let inputRow = buildRowView(labelText: "Input device:",
                                    control: inputDevicePopup, labelWidth: lw)
        let startRow = buildRowView(labelText: "Start sound:",
                                    control: startSoundPopup, labelWidth: lw)
        let stopRow = buildRowView(labelText: "Stop sound:",
                                   control: stopSoundPopup, labelWidth: lw)


        silenceThresholdField.widthAnchor.constraint(equalToConstant: 80).isActive = true
        let thresholdHint = PreferencesWindowController.makeHint(
            "RMS · default 0.0100")
        let thresholdHelp = HelpButton(text:
            "How quiet the microphone needs to be before the app counts " +
            "it as silence.\n\n" +
            "The number is an audio loudness measure (RMS). Lower = the " +
            "app treats quieter sounds as still being speech. Higher = " +
            "only loud audio counts as speech, and anything softer is " +
            "silence.\n\n" +
            "Used by both auto-stop (standard mode) and chunk detection " +
            "(continuous mode) because \"what counts as silent\" is one " +
            "idea.\n\n" +
            "Example: if auto-stop fires while you're still talking, " +
            "your speech is dipping below this value - lower it (e.g. " +
            "0.0050). If auto-stop never fires when you stop talking, " +
            "background noise is above it - raise it (e.g. 0.0200).")
        let thresholdControl = NSStackView(views: [
            silenceThresholdField, silenceThresholdStepper, thresholdHint, thresholdHelp
        ])
        thresholdControl.orientation = .horizontal
        thresholdControl.spacing = 8
        let (thresholdRow, thresholdLabel) = buildLabeledRow(
            labelText: "Silence level:", control: thresholdControl, labelWidth: lw)
        silenceThresholdLabel = thresholdLabel

        silenceSecondsField.widthAnchor.constraint(equalToConstant: 80).isActive = true
        let secondsHint = PreferencesWindowController.makeHint(
            "seconds · default 4.0")
        let secondsHelp = HelpButton(text:
            "How long silence must last before Auto stop ends the " +
            "recording.\n\n" +
            "Only used when Auto stop is on. The timer starts the moment " +
            "the microphone drops below the Silence level above, and " +
            "resets any time it goes back above.\n\n" +
            "Example: with 4.0 seconds, if you stop talking for 4 full " +
            "seconds, the app finalizes your dictation. A 3-second " +
            "thinking pause mid-sentence won't stop it.")
        let secondsControl = NSStackView(views: [
            silenceSecondsField, silenceSecondsStepper, secondsHint, secondsHelp
        ])
        secondsControl.orientation = .horizontal
        secondsControl.spacing = 8
        let (secondsRow, secondsLabelRef) = buildLabeledRow(
            labelText: "Silence duration:", control: secondsControl, labelWidth: lw)
        silenceSecondsLabel = secondsLabelRef

        let input = buildSection(title: "Input", rows: [inputRow])
        let feedback = buildSection(title: "Feedback", rows: [startRow, stopRow])
        let silence = buildSection(title: "Silence Detection",
                                   rows: [thresholdRow, silenceAutoStopCheckbox, secondsRow])

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
             "Pause:", "Max chunk:", "Sentence pause:", "Window threshold:",
             "Max chars:"])

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

        let continuousHelp = HelpButton(text:
            "A mode that transcribes while you talk, streaming text " +
            "into your document in chunks instead of waiting for you " +
            "to finish.\n\n" +
            "Each natural pause produces another chunk of text. Longer " +
            "pauses are treated as sentence breaks (period + capital), " +
            "shorter pauses as continuations.\n\n" +
            "Only works in toggle mode: press the hotkey once to start " +
            "the session, press again to end it. Not usable in " +
            "push-to-talk mode since the session ends the moment you " +
            "release the key.\n\n" +
            "Still being refined. The settings below control how it " +
            "decides where one phrase ends and the next begins. Expect " +
            "occasional misfires on noisy audio or unusually long " +
            "run-on sentences.")
        let continuousStack = NSStackView(views: [
            continuousDictationCheckbox,
            continuousHelp
        ])
        continuousStack.orientation = .horizontal
        continuousStack.alignment = .centerY
        continuousStack.spacing = 8

        continuousPauseField.widthAnchor.constraint(equalToConstant: 80).isActive = true
        let pauseHint = PreferencesWindowController.makeHint(
            "seconds · default 0.5")
        let pauseHelp = HelpButton(text:
            "How long you need to pause before the app decides a chunk " +
            "of speech is done and sends it off to be transcribed.\n\n" +
            "Shorter = text appears faster but risks chopping sentences " +
            "in half at natural mid-sentence pauses. Longer = text takes " +
            "longer to show up but phrases stay intact.\n\n" +
            "Example: with 0.5 seconds, a quick breath between words " +
            "stays part of the same chunk, but a clear pause between " +
            "two phrases produces a new chunk.")
        let pauseControl = NSStackView(views: [
            continuousPauseField, continuousPauseStepper, pauseHint, pauseHelp
        ])
        pauseControl.orientation = .horizontal
        pauseControl.spacing = 8
        let (pauseRow, pauseLabelRef) = buildLabeledRow(
            labelText: "Pause:", control: pauseControl, labelWidth: lw)
        continuousPauseLabel = pauseLabelRef

        continuousMaxChunkField.widthAnchor.constraint(equalToConstant: 80).isActive = true
        let maxChunkHint = PreferencesWindowController.makeHint(
            "seconds · default 30.0 · 5-30")
        let maxChunkHelp = HelpButton(text:
            "Safety limit on chunk length. If you talk non-stop for " +
            "this long without pausing, the app forces a break anyway " +
            "and sends what it has to be transcribed.\n\n" +
            "Prevents the transcription engine from choking on a huge " +
            "audio clip, and keeps text appearing at a reasonable rate.\n\n" +
            "Example: with 30 seconds, a long run-on sentence gets cut " +
            "after half a minute so you don't wait forever to see it.")
        let maxChunkControl = NSStackView(views: [
            continuousMaxChunkField, continuousMaxChunkStepper, maxChunkHint, maxChunkHelp
        ])
        maxChunkControl.orientation = .horizontal
        maxChunkControl.spacing = 8
        let (maxChunkRow, maxChunkLabelRef) = buildLabeledRow(
            labelText: "Max chunk:", control: maxChunkControl, labelWidth: lw)
        continuousMaxChunkLabel = maxChunkLabelRef

        continuousSentencePauseField.widthAnchor.constraint(equalToConstant: 80).isActive = true
        let sentencePauseHelp = HelpButton(text:
            "How long a pause between two chunks must be before the app " +
            "treats it as the end of a sentence.\n\n" +
            "Shorter pauses are treated as continuations of the same " +
            "sentence (no period, no capital letter). Pauses this long " +
            "or longer get a period and a capital on the next chunk.\n\n" +
            "Example: with 1.0 second, a quick half-second pause between " +
            "phrases stays one sentence; pausing a full second signals " +
            "\"start a new thought.\"")
        let sentencePauseControl = NSStackView(views: [
            continuousSentencePauseField,
            continuousSentencePauseStepper,
            PreferencesWindowController.makeHint("seconds · default 1.0"),
            sentencePauseHelp
        ])
        sentencePauseControl.orientation = .horizontal
        sentencePauseControl.spacing = 8
        let (sentencePauseRow, sentencePauseLabelRef) = buildLabeledRow(
            labelText: "Sentence pause:", control: sentencePauseControl, labelWidth: lw)
        continuousSentencePauseLabel = sentencePauseLabelRef

        continuousSentencePauseMaxField.widthAnchor.constraint(equalToConstant: 80).isActive = true
        let windowThresholdHelp = HelpButton(text:
            "The upper limit on the sentence-break window. Pauses longer " +
            "than this are treated as \"user got distracted\" rather than " +
            "a sentence break.\n\n" +
            "Between the Sentence pause value and this one, the next " +
            "chunk is joined with a period. Beyond this, the next chunk " +
            "is treated as a fresh restart with no join, no period.\n\n" +
            "Example: with Sentence pause 1.0 and Window threshold 2.0, " +
            "pausing 1 to 2 seconds means \"new sentence,\" but pausing " +
            "more than 2 seconds means \"something else happened, just " +
            "continue cleanly.\"")
        let sentencePauseMaxControl = NSStackView(views: [
            continuousSentencePauseMaxField,
            continuousSentencePauseMaxStepper,
            PreferencesWindowController.makeHint("seconds · default 2.0"),
            windowThresholdHelp
        ])
        sentencePauseMaxControl.orientation = .horizontal
        sentencePauseMaxControl.spacing = 8
        let (sentencePauseMaxRow, sentencePauseMaxLabelRef) = buildLabeledRow(
            labelText: "Window threshold:", control: sentencePauseMaxControl, labelWidth: lw)
        continuousSentencePauseMaxLabel = sentencePauseMaxLabelRef

        continuousPromptChainMaxCharsField.widthAnchor.constraint(equalToConstant: 80).isActive = true
        let promptCharsHint = PreferencesWindowController.makeHint(
            "default 200 · 100-900")
        let maxCharsHelp = HelpButton(text:
            "How much of your previous transcription to pass to the " +
            "speech engine as context for the next chunk.\n\n" +
            "More context helps the engine pick between similar-sounding " +
            "words. If you just said \"I went to the beach,\" the next " +
            "chunk is more likely to come out as \"sand\" than \"send.\" " +
            "But more context takes longer to process.\n\n" +
            "Example: 200 characters is roughly 30 to 40 words, enough " +
            "to catch the current topic. Raise if words keep being " +
            "mis-heard despite obvious context; lower if transcription " +
            "feels sluggish.")
        let promptCharsControl = NSStackView(views: [
            continuousPromptChainMaxCharsField, continuousPromptChainMaxCharsStepper,
            promptCharsHint, maxCharsHelp
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
        let stripHelp = HelpButton(text:
            "When on, the app removes any periods the speech engine " +
            "wrote and instead decides where sentences end based purely " +
            "on how long you pause between phrases (using Sentence " +
            "pause and Window threshold above).\n\n" +
            "Why: the speech engine sometimes inserts periods in " +
            "awkward places (lists, mid-phrase pauses, inferred stops). " +
            "Turning this on gives you cleaner, more predictable " +
            "results in continuous dictation.\n\n" +
            "Example: \"I bought milk, eggs, cheese.\" (pause) \"Then " +
            "went home.\" With this off, the engine's own periods and " +
            "capitals land wherever it inferred them. With this on, " +
            "you get \"I bought milk, eggs, cheese. Then went home\" " +
            "because only your long pause counted as a sentence break.")
        let stripRow = NSStackView(views: [stripWhisperPunctuationCheckbox, stripHelp])
        stripRow.orientation = .horizontal
        stripRow.spacing = 8
        stripRow.alignment = .centerY

        let promptChainHelp = HelpButton(text:
            "When on, the app shows the speech engine what it just " +
            "transcribed before it works on the next chunk. Gives the " +
            "engine context so it picks better word spellings.\n\n" +
            "Example: if you just said \"I went to the beach,\" the " +
            "engine is more likely to transcribe \"sand\" rather than " +
            "\"send\" or \"sent\" in the next chunk, because the beach " +
            "context primed it.\n\n" +
            "Trade-off: each transcription takes a tiny bit longer and " +
            "uses a little more memory. For most users the quality " +
            "improvement is worth it.")
        let promptChainRow = NSStackView(views: [continuousPromptChainCheckbox, promptChainHelp])
        promptChainRow.orientation = .horizontal
        promptChainRow.spacing = 8
        promptChainRow.alignment = .centerY

        let behavior = buildSection(title: "Behavior",
                                    rows: [continuousStack, pauseRow, maxChunkRow,
                                           sentencePauseRow, sentencePauseMaxRow,
                                           stripRow,
                                           promptChainRow, promptCharsRow])

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
            ["Method:", "Typed delay:", "Trailing period:"])

        let methodHelp = HelpButton(text:
            "How the app actually puts dictated text into the field " +
            "you're typing in.\n\n" +
            "Paste: copies the text to your clipboard and pastes it. " +
            "Fast and reliable in most apps, but it overwrites whatever " +
            "you had on the clipboard, and a few apps block paste.\n\n" +
            "Typed: simulates keyboard keystrokes, one character at a " +
            "time. Slower, but works in apps where paste is unreliable " +
            "(some terminals, games, sandboxed apps).\n\n" +
            "Start with Paste. Switch to Typed only if a specific app " +
            "drops or ignores the pasted text.")
        let radios = NSStackView(views: [injectionPasteRadio, injectionTypedRadio, methodHelp])
        radios.orientation = .horizontal
        radios.spacing = 16
        let methodRow = buildRowView(labelText: "Method:",
                                     control: radios, labelWidth: lw)

        typedDelayField.widthAnchor.constraint(equalToConstant: 60).isActive = true
        let delayHint = PreferencesWindowController.makeHint(
            "ms · default 8 · 5-100")
        let delayHelp = HelpButton(text:
            "Only used when Method is set to Typed. Controls how long " +
            "the app waits between each simulated keystroke.\n\n" +
            "Some apps can't keep up with keystrokes fired too fast and " +
            "will drop characters, producing garbled text. A small " +
            "delay gives them time to process each one.\n\n" +
            "Example: if typed output comes out with missing letters, " +
            "raise this (e.g. 15 or 20 ms). If text is clean, you can " +
            "lower it to make typing faster.")
        let delayControl = NSStackView(views: [
            typedDelayField, typedDelayStepper, delayHint, delayHelp
        ])
        delayControl.orientation = .horizontal
        delayControl.spacing = 8
        let (delayRow, delayLabelRef) = buildLabeledRow(
            labelText: "Typed delay:", control: delayControl, labelWidth: lw)
        typedDelayLabel = delayLabelRef

        let autoEndHelp = HelpButton(text:
            "When on, the app ensures every dictation ends with a " +
            "period. When off, no trailing period is added, even if " +
            "the speech engine wrote one.\n\n" +
            "The period doesn't appear instantly. There's a short " +
            "wait (set by Trailing period below) so you can start " +
            "another dictation if you weren't actually done. If you " +
            "press the hotkey during that wait, the period is " +
            "cancelled and you continue the same sentence.\n\n" +
            "Exception: sentences that already end with \"?\" or \"!\" " +
            "stay as-is. The app won't tack a period onto them.")
        let autoEndRow = NSStackView(views: [autoEndPeriodCheckbox, autoEndHelp])
        autoEndRow.orientation = .horizontal
        autoEndRow.spacing = 8
        autoEndRow.alignment = .centerY

        continuousTrailingPeriodField.widthAnchor.constraint(equalToConstant: 80).isActive = true
        let trailingPeriodHelp = HelpButton(text:
            "How long the app waits after your dictation finishes " +
            "before actually dropping in the trailing period.\n\n" +
            "This is your grace period. If you press the hotkey within " +
            "this window to start another dictation, the pending " +
            "period is cancelled so you can continue the same thought.\n\n" +
            "Example: with 4.0 seconds, your dictation appears, then 4 " +
            "seconds later a period is added. If you start dictating " +
            "again within those 4 seconds, no period appears and the " +
            "new text joins on cleanly.")
        let trailingPeriodControl = NSStackView(views: [
            continuousTrailingPeriodField,
            continuousTrailingPeriodStepper,
            PreferencesWindowController.makeHint("seconds · default 4.0"),
            trailingPeriodHelp
        ])
        trailingPeriodControl.orientation = .horizontal
        trailingPeriodControl.spacing = 8
        let (trailingPeriodRow, trailingPeriodLabelRef) = buildLabeledRow(
            labelText: "Trailing period:", control: trailingPeriodControl, labelWidth: lw)
        continuousTrailingPeriodLabel = trailingPeriodLabelRef

        let textInsertion = buildSection(title: "Text Insertion",
                                         rows: [methodRow, delayRow])
        let sentenceHandling = buildSection(title: "Sentence Handling",
                                            rows: [autoEndRow,
                                                   trailingPeriodRow])

        let inset = PreferencesWindowController.paneInset
        let gap = PreferencesWindowController.sectionGap
        let after1 = placeSection(textInsertion, in: pane, below: pane.topAnchor, topConstant: inset)
        let after2 = placeSection(sentenceHandling, in: pane, below: after1, topConstant: gap)
        pane.bottomAnchor.constraint(greaterThanOrEqualTo: after2, constant: inset).isActive = true
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
        let threadsHelp = HelpButton(text:
            "How many worker threads the local speech engine runs in " +
            "parallel while transcribing.\n\n" +
            "More threads = faster transcription, up to a point. The " +
            "maximum shown is your Mac's logical processor count. On " +
            "chips with hyperthreading that's roughly double the " +
            "physical core count. Running at max will make the rest " +
            "of your Mac feel sluggish while dictation is being " +
            "processed.\n\n" +
            "The recommendation shown next to this field is typically " +
            "a third to a half of the maximum, which stays responsive. " +
            "Going higher gives diminishing returns past the physical " +
            "core count and can get worse on multi-socket machines. " +
            "Go lower if other apps feel laggy during transcription.")
        let threadsControl = NSStackView(views: [
            threadsField, threadsStepper, threadsHint, threadsHelp
        ])
        threadsControl.orientation = .horizontal
        threadsControl.spacing = 8
        let (threadsRow, threadsLabelRef) = buildLabeledRow(
            labelText: "Transcription threads:", control: threadsControl, labelWidth: lw)
        threadsLabel = threadsLabelRef

        beamField.widthAnchor.constraint(equalToConstant: 60).isActive = true
        let beamHint = PreferencesWindowController.makeHint(
            "default 3 · 1-10")
        let beamHelp = HelpButton(text:
            "How many possible word interpretations the speech engine " +
            "considers at once for each piece of audio.\n\n" +
            "Higher = more accurate but slower. Lower = faster but the " +
            "engine commits to its first guess and can miss the right " +
            "word.\n\n" +
            "Example: with 1, the engine picks the single most likely " +
            "word immediately: fastest but prone to hearing \"to\" " +
            "when you said \"two.\" With 10, it keeps 10 candidates " +
            "alive and picks the best-fitting one: noticeably slower " +
            "but catches these distinctions.")
        let beamControl = NSStackView(views: [
            beamField, beamStepper, beamHint, beamHelp
        ])
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

        let processingRootHelp = HelpButton(text:
            "Governs whether the app cleans up whisper's raw output " +
            "before injecting it. When off, whisper's transcript lands " +
            "in your document exactly as emitted (including any stray " +
            "annotations like \"[BLANK_AUDIO]\" or \"*cough*\" and " +
            "whisper's own choices about capitalization).\n\n" +
            "When on, each of the five passes below runs independently " +
            "according to its own checkbox. For most users, leave this " +
            "and all five below on. The granular toggles are useful " +
            "for debugging or if a specific pass is destroying content " +
            "you want preserved.")

        let removeAnnotationsHelp = HelpButton(text:
            "Strips the non-speech markers whisper inserts when audio " +
            "goes silent or picks up non-speech sound.\n\n" +
            "Examples of what gets removed: \"[BLANK_AUDIO]\", " +
            "\"[MUSIC]\", \"(soft music)\", \"(laughter)\", \"*cough*\", " +
            "\"*laughs*\", leading \">>\" artifacts, and trailing " +
            "\"...\" that whisper uses to mark a partial phrase.\n\n" +
            "Turn off only if you're specifically trying to see these " +
            "markers for debugging.")

        let normalizeCapHelp = HelpButton(text:
            "Lowercases any capital letter that isn't at a sentence " +
            "start (after a period, question mark, or exclamation " +
            "mark). Whisper's natural sentence-start capitals are " +
            "preserved. The pronoun \"i\" and its contractions " +
            "(\"i'll\", \"i've\", \"i'm\", \"i'd\") are then re-uppercased.\n\n" +
            "Why: whisper's title-casing and shouty-case tendencies " +
            "produce text like \"Hello World, This Is A Test\" that " +
            "most users don't want. This folds everything to clean " +
            "sentence case.\n\n" +
            "Turn off if you want whisper's casing preserved as-is " +
            "(e.g. for code dictation where capitalization matters).")

        let fixupsHelp = HelpButton(text:
            "After capitalization is normalized, this re-raises known " +
            "proper nouns and brand names to their canonical form.\n\n" +
            "Examples: \"john\" becomes \"John\", \"toronto\" becomes " +
            "\"Toronto\", \"node.js\" becomes \"Node.js\", \"macos\" " +
            "becomes \"macOS\". Covers common first and last names, " +
            "major cities, US states and capitals, Canadian provinces " +
            "and capitals, and tech brand names.\n\n" +
            "Turn off if the hardcoded list is causing unwanted " +
            "rewrites for your use case.")

        let substitutionsHelp = HelpButton(text:
            "Rewrites spoken forms to their canonical capitalized " +
            "abbreviations and multi-word brand names.\n\n" +
            "Examples: \"megabytes\" becomes \"MB\", \"kilobytes\" " +
            "becomes \"KB\", \"mac os\" becomes \"macOS\", \"st johns\" " +
            "becomes \"St. John's\". Covers unit shortforms and " +
            "multi-word names that the single-word Capitalize nouns " +
            "pass can't handle.\n\n" +
            "Turn off if you want the spoken form preserved verbatim.")

        let firstLetterHelp = HelpButton(text:
            "In standard (non-continuous) dictation only. When the " +
            "cursor is at the start of a line (empty field, or " +
            "immediately after Enter), the first letter of the " +
            "dictated text is capitalized.\n\n" +
            "When the cursor is mid-line (inline dictation), the " +
            "first letter stays lowercase so your dictation joins " +
            "cleanly onto existing text.\n\n" +
            "Turn off if you prefer whisper's own first-letter " +
            "decision to stand regardless of cursor position.")

        let processingRootRow = NSStackView(views: [
            transcriptProcessingCheckbox, processingRootHelp
        ])
        processingRootRow.orientation = .horizontal
        processingRootRow.spacing = 8
        processingRootRow.alignment = .centerY

        let indent: CGFloat = 20
        let removeAnnotationsRow = makeIndentedRow(
            views: [removeNonSpeechAnnotationsCheckbox, removeAnnotationsHelp], indent: indent)
        let normalizeCapRow = makeIndentedRow(
            views: [normalizeCapitalizationCheckbox, normalizeCapHelp], indent: indent)
        let fixupsRow = makeIndentedRow(
            views: [applyProperNounFixupsCheckbox, fixupsHelp], indent: indent)
        let substitutionsRow = makeIndentedRow(
            views: [applyTextSubstitutionsCheckbox, substitutionsHelp], indent: indent)
        let firstLetterRow = makeIndentedRow(
            views: [capitalizeFirstLetterCheckbox, firstLetterHelp], indent: indent)

        let performance = buildSection(title: "Performance",
                                       rows: [threadsRow, beamRow])
        let diagnostics = buildSection(title: "Diagnostics",
                                       rows: [debugRow, loggingRow])
        let processing = buildSection(title: "Transcript Processing",
                                      rows: [processingRootRow,
                                             removeAnnotationsRow,
                                             normalizeCapRow,
                                             fixupsRow,
                                             substitutionsRow,
                                             firstLetterRow])
        let reset = buildSection(title: "Reset", rows: [resetStack])

        let inset = PreferencesWindowController.paneInset
        let gap = PreferencesWindowController.sectionGap
        let after1 = placeSection(performance, in: pane, below: pane.topAnchor, topConstant: inset)
        let after2 = placeSection(diagnostics, in: pane, below: after1, topConstant: gap)
        let after3 = placeSection(processing, in: pane, below: after2, topConstant: gap)
        let after4 = placeSection(reset, in: pane, below: after3, topConstant: gap)
        pane.bottomAnchor.constraint(greaterThanOrEqualTo: after4, constant: inset).isActive = true
        return pane
    }

    private func buildAboutPane() -> NSView {
        let pane = FlippedView()
        pane.translatesAutoresizingMaskIntoConstraints = false

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

        let authorLabel = NSTextField(frame: .zero)
        authorLabel.isEditable = false; authorLabel.isSelectable = false
        authorLabel.isBordered = false; authorLabel.drawsBackground = false
        authorLabel.stringValue = "by Paradoxical Quad"
        authorLabel.font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
        authorLabel.alignment = .center

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

        let copyright = NSTextField(frame: .zero)
        copyright.isEditable = false; copyright.isSelectable = false
        copyright.isBordered = false; copyright.drawsBackground = false
        copyright.stringValue = "\u{00A9} 2026 Paradoxical Quad"
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

        updateCheckButton.target = self
        updateCheckButton.action = #selector(checkForUpdatesClicked)

        updateDownloadButton.target = self
        updateDownloadButton.action = #selector(downloadUpdateClicked)
        updateOpenReleaseButton.target = self
        updateOpenReleaseButton.action = #selector(openReleasesClicked)
        updateSkipButton.target = self
        updateSkipButton.action = #selector(skipUpdateClicked)

        let statusRow = NSStackView(views: [updateSpinner, updateStatusLabel])
        statusRow.orientation = .horizontal
        statusRow.spacing = 8
        statusRow.alignment = .centerY

        let buttonRow = NSStackView(views: [updateDownloadButton,
                                            updateOpenReleaseButton,
                                            updateSkipButton])
        buttonRow.orientation = .horizontal
        buttonRow.spacing = 10

        updateProgressBar.widthAnchor.constraint(equalToConstant: 300).isActive = true
        updateProgressBar.isHidden = true
        updateProgressLabel.isHidden = true
        let progressGroup = NSStackView(views: [updateProgressBar, updateProgressLabel])
        progressGroup.orientation = .vertical
        progressGroup.alignment = .centerX
        progressGroup.spacing = 4
        progressGroup.isHidden = true
        self.updateProgressGroup = progressGroup

        let statusGroup = NSStackView(views: [statusRow, updateDetailLabel,
                                              buttonRow, progressGroup])
        statusGroup.orientation = .vertical
        statusGroup.alignment = .centerX
        statusGroup.spacing = 8
        statusGroup.isHidden = true
        self.updateStatusGroup = statusGroup
        self.updateButtonRow = buttonRow

        let stack = NSStackView(views: [
            iconView,
            spacer1,
            nameLabel, versionLabel, authorLabel,
            spacer2,
            description,
            spacer3,
            credits, copyright,
            spacer4,
            updateCheckButton,
            statusGroup
        ])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        pane.addSubview(stack)

        let inset = PreferencesWindowController.paneInset
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: pane.topAnchor, constant: inset + 8),
            stack.centerXAnchor.constraint(equalTo: pane.centerXAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 128),
            iconView.heightAnchor.constraint(equalToConstant: 128),
            description.widthAnchor.constraint(equalToConstant: 360),
            credits.widthAnchor.constraint(equalToConstant: 360),
            updateDetailLabel.widthAnchor.constraint(equalToConstant: 360),
            pane.bottomAnchor.constraint(greaterThanOrEqualTo: stack.bottomAnchor,
                                         constant: inset)
        ])
        return pane
    }

    // MARK: - Inline update check

    func triggerUpdateCheck() {
        runUpdateCheck()
    }

    @objc private func checkForUpdatesClicked() {
        runUpdateCheck()
    }

    private func runUpdateCheck() {
        pendingReleaseURL = nil
        pendingDownloadURL = nil
        pendingLatestVersion = nil
        updateStatusLabel.stringValue = "Checking for updates\u{2026}"
        updateDetailLabel.stringValue = ""
        updateSpinner.isHidden = false
        updateSpinner.startAnimation(nil)
        updateDownloadButton.isHidden = true
        updateOpenReleaseButton.isHidden = true
        updateSkipButton.isHidden = true
        updateButtonRow?.isHidden = true
        updateProgressGroup?.isHidden = true
        updateProgressBar.isHidden = true
        updateProgressLabel.isHidden = true
        updateProgressBar.doubleValue = 0
        updateProgressLabel.stringValue = ""
        updateStatusGroup?.isHidden = false
        updateCheckButton.isEnabled = false

        UpdateChecker.checkForUpdates { [weak self] result in
            self?.renderUpdateResult(result)
        }
    }

    private func renderUpdateResult(_ result: UpdateCheckResult) {
        onUpdateCheckResult?(result)
        updateSpinner.stopAnimation(nil)
        updateSpinner.isHidden = true
        updateCheckButton.isEnabled = true

        switch result {
        case .upToDate(let current):
            updateStatusLabel.stringValue = "Up to date."
            updateDetailLabel.stringValue = "Installed version: \(current)"
            updateButtonRow?.isHidden = true

        case .updateAvailable(let current, let latest, let url, let downloadURL):
            pendingReleaseURL = url
            pendingDownloadURL = downloadURL
            pendingLatestVersion = latest
            updateStatusLabel.stringValue = "Update available: \(latest)"
            updateDetailLabel.stringValue = "Installed version: \(current)"
            let canInstall = (downloadURL != nil) && UpdateInstaller.canInstallInPlace()
            updateDownloadButton.isHidden = !canInstall
            updateDownloadButton.isEnabled = canInstall
            updateOpenReleaseButton.isHidden = false
            updateSkipButton.isHidden = false
            updateButtonRow?.isHidden = false

        case .error(let message):
            updateStatusLabel.stringValue = "Couldn't check for updates."
            updateDetailLabel.stringValue = message
            updateButtonRow?.isHidden = true
        }
    }

    @objc private func downloadUpdateClicked() {
        guard let url = pendingDownloadURL else { return }
        updateDownloadButton.isEnabled = false
        updateSkipButton.isEnabled = false
        updateProgressGroup?.isHidden = false
        updateProgressBar.isHidden = false
        updateProgressLabel.isHidden = false
        updateProgressBar.doubleValue = 0
        updateProgressLabel.stringValue = "Starting\u{2026}"

        let installer = UpdateInstaller(downloadURL: url)
        updateInstaller = installer
        installer.onStageChange = { [weak self] description in
            DispatchQueue.main.async { self?.updateProgressLabel.stringValue = description }
        }
        installer.onProgress = { [weak self] fraction in
            DispatchQueue.main.async { self?.updateProgressBar.doubleValue = fraction }
        }
        installer.onFailure = { [weak self] message in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.updateProgressLabel.stringValue = "Failed: \(message)"
                self.updateProgressBar.doubleValue = 0
                self.updateDownloadButton.isEnabled = false
                self.updateSkipButton.isEnabled = true
                self.updateInstaller = nil
            }
        }
        installer.onReadyToRelaunch = {
            DispatchQueue.main.async {
                NSApp.terminate(nil)
            }
        }
        installer.start()
    }

    @objc private func openReleasesClicked() {
        if let url = pendingReleaseURL {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func skipUpdateClicked() {
        if let latest = pendingLatestVersion {
            onUpdateSkipped?(latest)
        }
        updateButtonRow?.isHidden = true
        updateStatusLabel.stringValue = "Skipped version \(pendingLatestVersion ?? "")."
        updateDetailLabel.stringValue = ""
    }

    // Wraps a row of controls with left padding so nested checkboxes read
    // as indented beneath their parent toggle.
    private func makeIndentedRow(views: [NSView], indent: CGFloat) -> NSView {
        let inner = NSStackView(views: views)
        inner.orientation = .horizontal
        inner.spacing = 8
        inner.alignment = .centerY
        inner.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(inner)
        NSLayoutConstraint.activate([
            inner.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: indent),
            inner.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor),
            inner.topAnchor.constraint(equalTo: container.topAnchor),
            inner.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])
        return container
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
        silenceThresholdField.stringValue = String(format: "%.4f",
            Preferences.shared.silenceAutoStopThreshold)
        silenceThresholdStepper.doubleValue = Preferences.shared.silenceAutoStopThreshold
        silenceSecondsField.stringValue = String(format: "%.1f",
            Preferences.shared.silenceAutoStopSeconds)
        silenceSecondsStepper.doubleValue = Preferences.shared.silenceAutoStopSeconds
        continuousDictationCheckbox.state =
            Preferences.shared.continuousDictationEnabled ? .on : .off
        continuousPauseField.stringValue = String(format: "%.1f",
            Preferences.shared.continuousDictationPauseSeconds)
        continuousPauseStepper.doubleValue =
            Preferences.shared.continuousDictationPauseSeconds
        continuousMaxChunkField.stringValue = String(format: "%.1f",
            Preferences.shared.continuousDictationMaxChunkSeconds)
        continuousMaxChunkStepper.doubleValue =
            Preferences.shared.continuousDictationMaxChunkSeconds
        continuousPromptChainCheckbox.state =
            Preferences.shared.continuousDictationPromptChainEnabled ? .on : .off
        continuousPromptChainMaxCharsField.integerValue =
            Preferences.shared.continuousDictationPromptChainMaxChars
        continuousPromptChainMaxCharsStepper.integerValue =
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
        transcriptProcessingCheckbox.state =
            Preferences.shared.transcriptProcessingEnabled ? .on : .off
        removeNonSpeechAnnotationsCheckbox.state =
            Preferences.shared.removeNonSpeechAnnotations ? .on : .off
        normalizeCapitalizationCheckbox.state =
            Preferences.shared.normalizeCapitalization ? .on : .off
        applyProperNounFixupsCheckbox.state =
            Preferences.shared.applyProperNounFixups ? .on : .off
        applyTextSubstitutionsCheckbox.state =
            Preferences.shared.applyTextSubstitutions ? .on : .off
        capitalizeFirstLetterCheckbox.state =
            Preferences.shared.capitalizeFirstLetterAtLineStart ? .on : .off
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
        updateContinuousDictationControls()
        updateSilenceDetectionControls()
        updateTranscriptProcessingControls()
    }

    private func updateTranscriptProcessingControls() {
        // Root off = whisper's raw output is passed through verbatim.
        // Grey the five nested passes to reflect that none of them fire,
        // even though their individual pref values stay intact so the
        // user's choices come back when the root is re-enabled.
        let enabled = transcriptProcessingCheckbox.state == .on
        removeNonSpeechAnnotationsCheckbox.isEnabled = enabled
        normalizeCapitalizationCheckbox.isEnabled = enabled
        applyProperNounFixupsCheckbox.isEnabled = enabled
        applyTextSubstitutionsCheckbox.isEnabled = enabled
        capitalizeFirstLetterCheckbox.isEnabled = enabled
    }

    private func updateSilenceDetectionControls() {
        // Silence level is the shared "what counts as silent" RMS definition;
        // both toggle-mode auto-stop and continuous-mode chunk boundary
        // detection read it. Stays enabled regardless of the auto-stop state.
        // Silence duration is auto-stop specific: it only has an effect when
        // the Auto stop checkbox is on.
        let autoStopOn = silenceAutoStopCheckbox.state == .on
        let labelActive = autoStopOn ? NSColor.labelColor : NSColor.disabledControlTextColor
        silenceSecondsField.isEnabled = autoStopOn
        silenceSecondsStepper.isEnabled = autoStopOn
        silenceSecondsLabel?.textColor = labelActive
    }

    private func updateContinuousDictationControls() {
        let enabled = continuousDictationCheckbox.state == .on
        let promptChainOn = enabled && continuousPromptChainCheckbox.state == .on
        let trailingPeriodOn = autoEndPeriodCheckbox.state == .on
        let labelActive = enabled ? NSColor.labelColor : NSColor.disabledControlTextColor
        let promptCharsLabelActive =
            promptChainOn ? NSColor.labelColor : NSColor.disabledControlTextColor
        let trailingPeriodLabelActive =
            trailingPeriodOn ? NSColor.labelColor : NSColor.disabledControlTextColor

        continuousPauseField.isEnabled = enabled
        continuousPauseStepper.isEnabled = enabled
        continuousMaxChunkField.isEnabled = enabled
        continuousMaxChunkStepper.isEnabled = enabled
        continuousSentencePauseField.isEnabled = enabled
        continuousSentencePauseStepper.isEnabled = enabled
        continuousSentencePauseMaxField.isEnabled = enabled
        continuousSentencePauseMaxStepper.isEnabled = enabled
        stripWhisperPunctuationCheckbox.isEnabled = enabled
        continuousPromptChainCheckbox.isEnabled = enabled
        continuousPromptChainMaxCharsField.isEnabled = promptChainOn
        continuousPromptChainMaxCharsStepper.isEnabled = promptChainOn

        // Auto trailing period applies in both modes, so stays enabled
        // regardless of continuous dictation state. The seconds field below
        // gates on the checkbox instead.
        continuousTrailingPeriodField.isEnabled = trailingPeriodOn
        continuousTrailingPeriodStepper.isEnabled = trailingPeriodOn

        continuousPauseLabel?.textColor = labelActive
        continuousMaxChunkLabel?.textColor = labelActive
        continuousSentencePauseLabel?.textColor = labelActive
        continuousSentencePauseMaxLabel?.textColor = labelActive
        continuousPromptChainMaxCharsLabel?.textColor = promptCharsLabelActive
        continuousTrailingPeriodLabel?.textColor = trailingPeriodLabelActive
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
        updateSilenceDetectionControls()
    }

    @objc private func continuousDictationChanged() {
        Preferences.shared.continuousDictationEnabled =
            (continuousDictationCheckbox.state == .on)
        silenceAutoStopCheckbox.state =
            Preferences.shared.silenceAutoStopEnabled ? .on : .off
        updateContinuousDictationControls()
    }

    @objc private func continuousPromptChainChanged() {
        Preferences.shared.continuousDictationPromptChainEnabled =
            (continuousPromptChainCheckbox.state == .on)
        updateContinuousDictationControls()
    }

    @objc private func stripWhisperPunctuationChanged() {
        Preferences.shared.continuousDictationStripWhisperPunctuation =
            (stripWhisperPunctuationCheckbox.state == .on)
    }

    @objc private func autoEndPeriodChanged() {
        Preferences.shared.continuousDictationAutoEndPeriod =
            (autoEndPeriodCheckbox.state == .on)
        updateContinuousDictationControls()
    }

    @objc private func transcriptProcessingChanged() {
        Preferences.shared.transcriptProcessingEnabled =
            (transcriptProcessingCheckbox.state == .on)
        updateTranscriptProcessingControls()
    }

    @objc private func removeNonSpeechAnnotationsChanged() {
        Preferences.shared.removeNonSpeechAnnotations =
            (removeNonSpeechAnnotationsCheckbox.state == .on)
    }

    @objc private func normalizeCapitalizationChanged() {
        Preferences.shared.normalizeCapitalization =
            (normalizeCapitalizationCheckbox.state == .on)
    }

    @objc private func applyProperNounFixupsChanged() {
        Preferences.shared.applyProperNounFixups =
            (applyProperNounFixupsCheckbox.state == .on)
    }

    @objc private func applyTextSubstitutionsChanged() {
        Preferences.shared.applyTextSubstitutions =
            (applyTextSubstitutionsCheckbox.state == .on)
    }

    @objc private func capitalizeFirstLetterChanged() {
        Preferences.shared.capitalizeFirstLetterAtLineStart =
            (capitalizeFirstLetterCheckbox.state == .on)
    }

    @objc private func typedDelayStepperChanged() {
        let value = typedDelayStepper.integerValue
        typedDelayField.integerValue = value
        Preferences.shared.typedKeystrokeDelayMs = value
    }

    @objc private func silenceThresholdStepperChanged() {
        let value = silenceThresholdStepper.doubleValue
        silenceThresholdField.stringValue = String(format: "%.4f", value)
        Preferences.shared.silenceAutoStopThreshold = value
        setNumericFieldValid(field: silenceThresholdField,
                             label: silenceThresholdLabel, valid: true)
    }

    @objc private func silenceSecondsStepperChanged() {
        let value = silenceSecondsStepper.doubleValue
        silenceSecondsField.stringValue = String(format: "%.1f", value)
        Preferences.shared.silenceAutoStopSeconds = value
        setNumericFieldValid(field: silenceSecondsField,
                             label: silenceSecondsLabel, valid: true)
    }

    @objc private func continuousPauseStepperChanged() {
        let value = continuousPauseStepper.doubleValue
        continuousPauseField.stringValue = String(format: "%.1f", value)
        Preferences.shared.continuousDictationPauseSeconds = value
        setNumericFieldValid(field: continuousPauseField,
                             label: continuousPauseLabel, valid: true)
    }

    @objc private func continuousMaxChunkStepperChanged() {
        let value = continuousMaxChunkStepper.doubleValue
        continuousMaxChunkField.stringValue = String(format: "%.1f", value)
        Preferences.shared.continuousDictationMaxChunkSeconds = value
        setNumericFieldValid(field: continuousMaxChunkField,
                             label: continuousMaxChunkLabel, valid: true)
    }

    @objc private func continuousPromptChainMaxCharsStepperChanged() {
        let value = continuousPromptChainMaxCharsStepper.integerValue
        continuousPromptChainMaxCharsField.integerValue = value
        Preferences.shared.continuousDictationPromptChainMaxChars = value
        setNumericFieldValid(field: continuousPromptChainMaxCharsField,
                             label: continuousPromptChainMaxCharsLabel, valid: true)
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
            if let v = Double(silenceThresholdField.stringValue), v >= 0.0001, v <= 0.5 {
                silenceThresholdStepper.doubleValue = v
                Preferences.shared.silenceAutoStopThreshold = v
                setNumericFieldValid(field: silenceThresholdField,
                                     label: silenceThresholdLabel, valid: true)
            } else {
                setNumericFieldValid(field: silenceThresholdField,
                                     label: silenceThresholdLabel, valid: false)
            }
        case silenceSecondsField:
            if let v = Double(silenceSecondsField.stringValue), v >= 1.2, v <= 10.0 {
                silenceSecondsStepper.doubleValue = v
                Preferences.shared.silenceAutoStopSeconds = v
                setNumericFieldValid(field: silenceSecondsField,
                                     label: silenceSecondsLabel, valid: true)
            } else {
                setNumericFieldValid(field: silenceSecondsField,
                                     label: silenceSecondsLabel, valid: false)
            }
        case continuousPauseField:
            if let v = Double(continuousPauseField.stringValue), v >= 0.3, v <= 2.0 {
                continuousPauseStepper.doubleValue = v
                Preferences.shared.continuousDictationPauseSeconds = v
                setNumericFieldValid(field: continuousPauseField,
                                     label: continuousPauseLabel, valid: true)
            } else {
                setNumericFieldValid(field: continuousPauseField,
                                     label: continuousPauseLabel, valid: false)
            }
        case continuousMaxChunkField:
            if let v = Double(continuousMaxChunkField.stringValue), v >= 5.0, v <= 30.0 {
                continuousMaxChunkStepper.doubleValue = v
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
                continuousPromptChainMaxCharsStepper.integerValue = v
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
            return v >= 0.0001 && v <= 0.5
        case silenceSecondsField:
            guard let v = Double(silenceSecondsField.stringValue) else { return false }
            return v >= 1.2 && v <= 10.0
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
            silenceThresholdField.stringValue = String(format: "%.4f",
                Preferences.shared.silenceAutoStopThreshold)
            silenceThresholdStepper.doubleValue =
                Preferences.shared.silenceAutoStopThreshold
            setNumericFieldValid(field: silenceThresholdField,
                                 label: silenceThresholdLabel, valid: true)
        case silenceSecondsField:
            silenceSecondsField.stringValue = String(format: "%.1f",
                Preferences.shared.silenceAutoStopSeconds)
            silenceSecondsStepper.doubleValue =
                Preferences.shared.silenceAutoStopSeconds
            setNumericFieldValid(field: silenceSecondsField,
                                 label: silenceSecondsLabel, valid: true)
        case continuousPauseField:
            continuousPauseField.stringValue = String(format: "%.1f",
                Preferences.shared.continuousDictationPauseSeconds)
            continuousPauseStepper.doubleValue =
                Preferences.shared.continuousDictationPauseSeconds
            setNumericFieldValid(field: continuousPauseField,
                                 label: continuousPauseLabel, valid: true)
        case continuousMaxChunkField:
            continuousMaxChunkField.stringValue = String(format: "%.1f",
                Preferences.shared.continuousDictationMaxChunkSeconds)
            continuousMaxChunkStepper.doubleValue =
                Preferences.shared.continuousDictationMaxChunkSeconds
            setNumericFieldValid(field: continuousMaxChunkField,
                                 label: continuousMaxChunkLabel, valid: true)
        case continuousPromptChainMaxCharsField:
            continuousPromptChainMaxCharsField.integerValue =
                Preferences.shared.continuousDictationPromptChainMaxChars
            continuousPromptChainMaxCharsStepper.integerValue =
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

// Popover content for a single help button. Plain-text body with word
// wrapping. Deliberately avoids the 10.12+ wrappingLabelWithString
// convenience initializer; configures NSTextField manually so it still
// builds against the 10.11 deployment target.
final class HelpPopoverViewController: NSViewController {
    private let helpText: String
    private static let contentWidth: CGFloat = 340
    private static let margin: CGFloat = 14

    init(text: String) {
        self.helpText = text
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func loadView() {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false

        let label = NSTextField()
        label.stringValue = helpText
        label.font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
        label.textColor = NSColor.labelColor
        label.isEditable = false
        label.isSelectable = true
        label.isBordered = false
        label.drawsBackground = false
        label.lineBreakMode = .byWordWrapping
        label.cell?.wraps = true
        label.cell?.isScrollable = false
        label.maximumNumberOfLines = 0
        let textWidth =
            HelpPopoverViewController.contentWidth - 2 * HelpPopoverViewController.margin
        label.preferredMaxLayoutWidth = textWidth
        label.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(label)
        NSLayoutConstraint.activate([
            label.topAnchor.constraint(
                equalTo: container.topAnchor,
                constant: HelpPopoverViewController.margin),
            label.leadingAnchor.constraint(
                equalTo: container.leadingAnchor,
                constant: HelpPopoverViewController.margin),
            label.trailingAnchor.constraint(
                equalTo: container.trailingAnchor,
                constant: -HelpPopoverViewController.margin),
            label.bottomAnchor.constraint(
                equalTo: container.bottomAnchor,
                constant: -HelpPopoverViewController.margin),
            container.widthAnchor.constraint(
                equalToConstant: HelpPopoverViewController.contentWidth)
        ])
        self.view = container
    }
}

// Round "?" button that reveals a popover with the given text on click.
// Toggles the popover: a second click while it's visible closes it.
final class HelpButton: NSButton {
    private let helpText: String
    private var popover: NSPopover?

    init(text: String) {
        self.helpText = text
        super.init(frame: .zero)
        self.bezelStyle = .helpButton
        self.setButtonType(.momentaryPushIn)
        self.title = ""
        self.translatesAutoresizingMaskIntoConstraints = false
        self.target = self
        self.action = #selector(showHelp)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    @objc private func showHelp() {
        if let pop = popover, pop.isShown {
            pop.performClose(nil)
            return
        }
        let pop = NSPopover()
        pop.behavior = .transient
        pop.contentViewController = HelpPopoverViewController(text: helpText)
        pop.show(relativeTo: self.bounds, of: self, preferredEdge: .maxY)
        self.popover = pop
    }
}


