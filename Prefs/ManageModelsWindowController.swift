import Cocoa

final class ManageModelsWindowController: NSWindowController {
    var onDidChange: (() -> Void)?

    private let customStack = NSStackView()
    private let customURLField = NSTextField()
    private let emptyCustomLabel: NSTextField = {
        let f = NSTextField(frame: .zero)
        f.isEditable = false
        f.isSelectable = false
        f.isBordered = false
        f.drawsBackground = false
        f.stringValue = "No custom models downloaded yet."
        return f
    }()
    private var rowViews: [String: ModelRowView] = [:]
    private var extraRowViews: [String: ModelRowView] = [:]

    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 520),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false)
        window.title = "Models"
        self.init(window: window)
        buildLayout()
        refreshAll()
    }

    private func buildLayout() {
        guard let content = window?.contentView else { return }

        let outer = NSStackView()
        outer.orientation = .vertical
        outer.alignment = .leading
        outer.spacing = 12
        outer.edgeInsets = NSEdgeInsets(top: 16, left: 20, bottom: 16, right: 20)
        outer.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(outer)
        NSLayoutConstraint.activate([
            outer.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            outer.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            outer.topAnchor.constraint(equalTo: content.topAnchor),
            outer.bottomAnchor.constraint(equalTo: content.bottomAnchor)
        ])

        // Fixed catalog section.
        let catalogHeader = NSTextField(frame: .zero)
        catalogHeader.isEditable = false
        catalogHeader.isSelectable = false
        catalogHeader.isBordered = false
        catalogHeader.drawsBackground = false
        catalogHeader.stringValue = "Available transcription models"
        catalogHeader.font = NSFont.boldSystemFont(ofSize: NSFont.systemFontSize)
        outer.addArrangedSubview(catalogHeader)

        let catalogBox = ManageModelsWindowController.makeSectionBox()
        let catalogInner = ManageModelsWindowController.innerStack(in: catalogBox)
        for entry in ModelCatalog.entries {
            let row = ModelRowView(entry: entry)
            row.onDownload = { [weak self] in self?.downloadCatalogEntry(entry) }
            row.onDelete = { [weak self] in self?.deleteDownloaded(entry) }
            row.onCancel = { [weak self] in self?.cancelDownload(entry) }
            row.onUse = { [weak self] in self?.activate(filename: entry.filename) }
            rowViews[entry.filename] = row
            catalogInner.addArrangedSubview(row)
        }
        outer.addArrangedSubview(catalogBox)
        catalogBox.widthAnchor.constraint(equalTo: outer.widthAnchor,
                                          constant: -40).isActive = true

        // Fixed "Custom models" header above the scroll area.
        let customHeader = NSTextField(frame: .zero)
        customHeader.isEditable = false
        customHeader.isSelectable = false
        customHeader.isBordered = false
        customHeader.drawsBackground = false
        customHeader.stringValue = "Custom models"
        customHeader.font = NSFont.boldSystemFont(ofSize: NSFont.systemFontSize)
        outer.addArrangedSubview(customHeader)

        // Scrollable area for custom rows only.
        customStack.orientation = .vertical
        customStack.alignment = .leading
        customStack.spacing = 8
        customStack.edgeInsets = NSEdgeInsets(top: 4, left: 0, bottom: 4, right: 0)
        customStack.translatesAutoresizingMaskIntoConstraints = false

        emptyCustomLabel.textColor = .secondaryLabelColor
        customStack.addArrangedSubview(emptyCustomLabel)

        let flipped = FlippedContainer()
        flipped.translatesAutoresizingMaskIntoConstraints = false
        flipped.addSubview(customStack)
        NSLayoutConstraint.activate([
            customStack.topAnchor.constraint(equalTo: flipped.topAnchor),
            customStack.leadingAnchor.constraint(equalTo: flipped.leadingAnchor),
            customStack.trailingAnchor.constraint(equalTo: flipped.trailingAnchor),
            customStack.bottomAnchor.constraint(lessThanOrEqualTo: flipped.bottomAnchor)
        ])

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = false
        scroll.documentView = flipped
        scroll.translatesAutoresizingMaskIntoConstraints = false

        let customBox = ManageModelsWindowController.makeSectionBox()
        let customInner = ManageModelsWindowController.innerStack(in: customBox)
        customInner.addArrangedSubview(scroll)
        // Width must leave room for the stack's left + right edgeInsets
        // (14 + 14 = 28). Pinning scroll to customInner.width would
        // force autolayout to zero the leading inset, which is what
        // was eating the left padding on custom rows.
        NSLayoutConstraint.activate([
            scroll.heightAnchor.constraint(equalToConstant: 240),
            scroll.widthAnchor.constraint(equalTo: customInner.widthAnchor,
                                          constant: -28),
            flipped.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor)
        ])
        outer.addArrangedSubview(customBox)
        customBox.widthAnchor.constraint(equalTo: outer.widthAnchor,
                                         constant: -40).isActive = true

        let customLabel = NSTextField(frame: .zero)
        customLabel.isEditable = false
        customLabel.isSelectable = false
        customLabel.isBordered = false
        customLabel.drawsBackground = false
        customLabel.stringValue = "Download a custom model from a URL:"
        outer.addArrangedSubview(customLabel)

        customURLField.placeholderString = "https://.../ggml-your-model.bin"
        let customDownload = NSButton(frame: .zero)
        customDownload.bezelStyle = .rounded
        customDownload.title = "Download"
        customDownload.target = self
        customDownload.action = #selector(downloadCustom)
        let customRow = NSStackView(views: [customURLField, customDownload])
        customRow.orientation = .horizontal
        customRow.spacing = 8
        customURLField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        customRow.translatesAutoresizingMaskIntoConstraints = false
        outer.addArrangedSubview(customRow)
        customRow.widthAnchor.constraint(equalTo: outer.widthAnchor,
                                         constant: -40).isActive = true

        let revealButton = NSButton(frame: .zero)
        revealButton.bezelStyle = .rounded
        revealButton.title = "Reveal Models Folder"
        revealButton.target = self
        revealButton.action = #selector(revealModelsFolder)
        let closeButton = NSButton(frame: .zero)
        closeButton.bezelStyle = .rounded
        closeButton.title = "Close"
        closeButton.target = self
        closeButton.action = #selector(closeSheet)
        closeButton.keyEquivalent = "\r"
        let footerSpacer = NSView()
        footerSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let footer = NSStackView(views: [revealButton, footerSpacer, closeButton])
        footer.orientation = .horizontal
        footer.spacing = 8
        footer.translatesAutoresizingMaskIntoConstraints = false
        outer.addArrangedSubview(footer)
        footer.widthAnchor.constraint(equalTo: outer.widthAnchor,
                                      constant: -40).isActive = true
    }

    func refreshAll() {
        for entry in ModelCatalog.entries {
            rowViews[entry.filename]?.refreshStatus()
        }
        rebuildExtrasSection()
        refreshBestPickMarker()
    }

    // Determines the single best-pick filename across every model
    // present on disk (bundled catalog entries, downloaded catalog
    // entries, and custom downloads) and marks exactly one row.
    private func refreshBestPickMarker() {
        var present: [String] = []
        for entry in ModelCatalog.entries {
            if entry.isBundled {
                present.append(entry.filename)
                continue
            }
            if case .downloaded = ModelLocator.status(for: entry.filename) {
                present.append(entry.filename)
            }
        }
        present.append(contentsOf: extraRowViews.keys)
        let best = ModelRecommendation.bestPickFilename(among: present)
        for (fn, row) in rowViews { row.setBestPick(fn == best) }
        for (fn, row) in extraRowViews { row.setBestPick(fn == best) }
    }

    private func rebuildExtrasSection() {
        for (_, view) in extraRowViews {
            view.removeFromSuperview()
        }
        extraRowViews.removeAll()

        let filenames = ModelLocator.extraDownloadedFilenames()
        emptyCustomLabel.isHidden = !filenames.isEmpty

        let fm = FileManager.default
        let dir = Preferences.writableModelsDirectory
        for filename in filenames {
            let url = dir.appendingPathComponent(filename)
            let attrs = try? fm.attributesOfItem(atPath: url.path)
            let size = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
            let entry = CatalogModel(displayName: filename,
                                     filename: filename,
                                     sizeBytes: size,
                                     url: nil,
                                     isBundled: false,
                                     isCustom: true)
            let row = ModelRowView(entry: entry)
            row.onDelete = { [weak self] in self?.deleteExtra(filename: filename) }
            row.onUse = { [weak self] in self?.activate(filename: filename) }
            extraRowViews[filename] = row
            customStack.addArrangedSubview(row)
        }
    }

    private func deleteExtra(filename: String) {
        let url = Preferences.writableModelsDirectory.appendingPathComponent(filename)
        let confirm = NSAlert()
        confirm.messageText = "Delete \(filename)?"
        confirm.informativeText = url.path
        confirm.addButton(withTitle: "Delete")
        confirm.addButton(withTitle: "Cancel")
        guard confirm.runModal() == .alertFirstButtonReturn else { return }
        try? FileManager.default.removeItem(at: url)
        rebuildExtrasSection()
        onDidChange?()
    }

    // MARK: - Actions

    private func downloadCatalogEntry(_ entry: CatalogModel) {
        guard let url = entry.url else { return }
        beginDownload(entry: entry, from: url, destinationFilename: entry.filename)
    }

    @objc private func downloadCustom() {
        let raw = customURLField.stringValue.trimmingCharacters(in: .whitespaces)
        guard !raw.isEmpty, let url = URL(string: raw), url.scheme == "https" else {
            let alert = NSAlert()
            alert.messageText = "Enter a valid https URL."
            alert.runModal()
            return
        }
        let suggested = url.lastPathComponent
        let filename = suggested.hasSuffix(".bin") ? suggested : (suggested + ".bin")
        beginDownload(entry: nil, from: url, destinationFilename: filename)
    }

    private func beginDownload(entry: CatalogModel?, from url: URL, destinationFilename: String) {
        let dest = Preferences.writableModelsDirectory.appendingPathComponent(destinationFilename)
        let downloader = ModelDownloader(destination: dest)

        if let entry = entry, let row = rowViews[entry.filename] {
            row.setDownloading(progress: 0, downloader: downloader)
            downloader.onProgress = { [weak row] p in row?.setDownloading(progress: p, downloader: downloader) }
            downloader.onComplete = { [weak self] result in
                self?.finishedDownload(entry: entry, destination: dest, result: result)
            }
        } else {
            // Custom URL path: no row view, just an alert on completion.
            downloader.onComplete = { [weak self] result in
                self?.finishedCustomDownload(destination: dest, result: result)
            }
        }
        downloader.start(from: url)
    }

    private func finishedDownload(entry: CatalogModel,
                                  destination: URL,
                                  result: ModelDownloader.DownloadResult) {
        switch result {
        case .success:
            rowViews[entry.filename]?.refreshStatus()
            onDidChange?()
        case .failure(let err):
            rowViews[entry.filename]?.refreshStatus()
            showError(message: "Download failed", detail: describe(err))
        }
    }

    private func finishedCustomDownload(destination: URL,
                                        result: ModelDownloader.DownloadResult) {
        switch result {
        case .success(let url):
            customURLField.stringValue = ""
            rebuildExtrasSection()
            onDidChange?()
            let alert = NSAlert()
            alert.messageText = "Downloaded"
            alert.informativeText = "Saved to \(url.path)"
            alert.runModal()
        case .failure(let err):
            showError(message: "Download failed", detail: describe(err))
        }
    }

    private func describe(_ err: ModelDownloader.DownloadError) -> String {
        switch err {
        case .httpStatus(let code): return "Server returned HTTP \(code)."
        case .invalidFile: return "The downloaded file does not look like a whisper ggml model."
        case .ioError(let underlying): return underlying.localizedDescription
        }
    }

    private func showError(message: String, detail: String) {
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = detail
        alert.runModal()
    }

    private func deleteDownloaded(_ entry: CatalogModel) {
        guard case .downloaded(let url) = ModelLocator.status(for: entry.filename) else { return }
        let confirm = NSAlert()
        confirm.messageText = "Delete \(entry.displayName)?"
        confirm.informativeText = url.path
        confirm.addButton(withTitle: "Delete")
        confirm.addButton(withTitle: "Cancel")
        guard confirm.runModal() == .alertFirstButtonReturn else { return }
        try? FileManager.default.removeItem(at: url)
        rowViews[entry.filename]?.refreshStatus()
        onDidChange?()
    }

    private func cancelDownload(_ entry: CatalogModel) {
        rowViews[entry.filename]?.cancelDownload()
    }

    private func activate(filename: String) {
        Preferences.shared.localModelFilename = filename
        refreshAll()
        onDidChange?()
    }

    @objc private func revealModelsFolder() {
        let dir = Preferences.writableModelsDirectory
        try? FileManager.default.createDirectory(at: dir,
                                                 withIntermediateDirectories: true,
                                                 attributes: nil)
        NSWorkspace.shared.open(dir)
    }

    @objc private func closeSheet() {
        guard let sheet = window, let parent = sheet.sheetParent else {
            window?.close()
            return
        }
        parent.endSheet(sheet)
    }
}

// MARK: - FlippedContainer

private final class FlippedContainer: NSView {
    override var isFlipped: Bool { return true }
}

// MARK: - Section helpers

extension ManageModelsWindowController {
    // Creates a rounded, tinted container matching the section boxes in
    // Preferences. Tagged with AppearanceManager.sectionBoxIdentifier so
    // the walker refreshes the tint when the appearance mode changes.
    fileprivate static func makeSectionBox() -> NSView {
        let box = FlippedContainer()
        box.translatesAutoresizingMaskIntoConstraints = false
        box.wantsLayer = true
        box.identifier = AppearanceManager.sectionBoxIdentifier
        box.layer?.backgroundColor = AppearanceManager.shared.sectionBackgroundCGColor()
        box.layer?.cornerRadius = 8
        return box
    }

    // Creates a vertical stack view with Preferences-matching internal
    // padding and attaches it to `box` so added content inherits the
    // section's inset.
    fileprivate static func innerStack(in box: NSView) -> NSStackView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 14, bottom: 12, right: 14)
        stack.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: box.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: box.trailingAnchor),
            stack.topAnchor.constraint(equalTo: box.topAnchor),
            stack.bottomAnchor.constraint(equalTo: box.bottomAnchor)
        ])
        return stack
    }
}

// MARK: - DotView

private final class DotView: NSView {
    var fillColor: NSColor = .clear {
        didSet { needsDisplay = true }
    }
    override var intrinsicContentSize: NSSize { return NSSize(width: 8, height: 8) }
    override func draw(_ dirtyRect: NSRect) {
        fillColor.setFill()
        NSBezierPath(ovalIn: bounds).fill()
    }
}

// MARK: - ModelRowView

private final class ModelRowView: NSView {
    private let entry: CatalogModel

    private let nameLabel: NSTextField = {
        let f = NSTextField(frame: .zero)
        f.isEditable = false; f.isSelectable = false
        f.isBordered = false; f.drawsBackground = false
        return f
    }()
    private let sizeLabel: NSTextField = {
        let f = NSTextField(frame: .zero)
        f.isEditable = false; f.isSelectable = false
        f.isBordered = false; f.drawsBackground = false
        return f
    }()
    private let statusDot = DotView()
    private let statusLabel: NSTextField = {
        let f = NSTextField(frame: .zero)
        f.isEditable = false; f.isSelectable = false
        f.isBordered = false; f.drawsBackground = false
        return f
    }()
    private let progressBar = NSProgressIndicator()
    private let useButton: NSButton = {
        let b = NSButton(frame: .zero)
        b.bezelStyle = .rounded
        b.title = ""
        return b
    }()
    private let actionButton: NSButton = {
        let b = NSButton(frame: .zero)
        b.bezelStyle = .rounded
        b.title = ""
        return b
    }()

    private weak var activeDownloader: ModelDownloader?
    private var isBestPick: Bool = false

    var onDownload: (() -> Void)?
    var onDelete: (() -> Void)?
    var onCancel: (() -> Void)?
    var onUse: (() -> Void)?

    init(entry: CatalogModel) {
        self.entry = entry
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        setupSubviews()
        refreshStatus()
    }

    required init?(coder: NSCoder) { fatalError() }

    // Called by the controller after all rows have been refreshed and
    // the global best-pick filename is known. Marks the single best-fit
    // row by prefixing the name with a blue star and colouring the name
    // in blue.
    func setBestPick(_ isBest: Bool) {
        isBestPick = isBest
        refreshNameLabel()
    }

    private func refreshNameLabel() {
        let prefix = isBestPick ? "\u{2605} " : ""
        nameLabel.stringValue = prefix + entry.displayName
        if isBestPick {
            nameLabel.textColor = .systemBlue
        } else {
            let rec = ModelRecommendation.rate(filename: entry.filename,
                                               sizeBytes: entry.sizeBytes)
            nameLabel.textColor = rec.color
        }
    }

    private func setupSubviews() {
        nameLabel.stringValue = entry.displayName
        nameLabel.font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
        // Tagged so the AppearanceManager text-color walker leaves us
        // alone — we manage these two by speed rating / best-pick.
        nameLabel.identifier = AppearanceManager.customColorIdentifier
        statusLabel.identifier = AppearanceManager.customColorIdentifier
        sizeLabel.stringValue = ModelCatalog.formatBytes(entry.sizeBytes)
        sizeLabel.textColor = .labelColor
        statusLabel.textColor = .labelColor

        progressBar.isIndeterminate = false
        progressBar.minValue = 0
        progressBar.maxValue = 1
        progressBar.doubleValue = 0
        progressBar.controlSize = .small
        progressBar.style = .bar
        progressBar.isHidden = true

        useButton.bezelStyle = .rounded
        useButton.target = self
        useButton.action = #selector(useTapped)

        actionButton.bezelStyle = .rounded
        actionButton.target = self
        actionButton.action = #selector(actionTapped)

        let statusContainer = NSView()
        statusContainer.translatesAutoresizingMaskIntoConstraints = false

        let statusLine = NSStackView(views: [statusDot, statusLabel])
        statusLine.orientation = .horizontal
        statusLine.spacing = 6
        statusLine.alignment = .centerY
        statusLine.translatesAutoresizingMaskIntoConstraints = false

        progressBar.translatesAutoresizingMaskIntoConstraints = false
        statusContainer.addSubview(statusLine)
        statusContainer.addSubview(progressBar)
        NSLayoutConstraint.activate([
            statusLine.leadingAnchor.constraint(equalTo: statusContainer.leadingAnchor),
            statusLine.trailingAnchor.constraint(lessThanOrEqualTo: statusContainer.trailingAnchor),
            statusLine.centerYAnchor.constraint(equalTo: statusContainer.centerYAnchor),
            progressBar.leadingAnchor.constraint(equalTo: statusContainer.leadingAnchor),
            progressBar.trailingAnchor.constraint(equalTo: statusContainer.trailingAnchor),
            progressBar.centerYAnchor.constraint(equalTo: statusContainer.centerYAnchor),
            statusDot.widthAnchor.constraint(equalToConstant: 8),
            statusDot.heightAnchor.constraint(equalToConstant: 8)
        ])

        let row = NSStackView(views: [nameLabel, sizeLabel, statusContainer,
                                      useButton, actionButton])
        row.orientation = .horizontal
        row.spacing = 10
        row.alignment = .centerY
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)

        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.topAnchor.constraint(equalTo: topAnchor),
            row.bottomAnchor.constraint(equalTo: bottomAnchor),
            nameLabel.widthAnchor.constraint(equalToConstant: 170),
            sizeLabel.widthAnchor.constraint(equalToConstant: 70),
            statusContainer.widthAnchor.constraint(equalToConstant: 130),
            useButton.widthAnchor.constraint(equalToConstant: 68),
            actionButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 90)
        ])
    }

    func refreshStatus() {
        activeDownloader = nil
        progressBar.isHidden = true
        progressBar.doubleValue = 0
        statusLabel.isHidden = false

        // Reset to a non-rated appearance; the catalog branch below applies colors.
        statusDot.fillColor = .clear
        statusDot.isHidden = true
        statusLabel.textColor = .secondaryLabelColor

        let isActive = (entry.filename == Preferences.shared.localModelFilename)

        // Every row gets a colored recommendation (catalog, bundled, or
        // custom-downloaded). Rating is computed from the filename-
        // parsed family + quant and the current host's capability
        // (physical cores, SIMD, arch, thread setting); falls back to a
        // size-derived estimate when the filename doesn't match a
        // standard pattern.
        let rec = ModelRecommendation.rate(filename: entry.filename,
                                           sizeBytes: entry.sizeBytes)
        statusDot.isHidden = false
        statusDot.fillColor = rec.color
        statusLabel.stringValue = rec.label
        statusLabel.textColor = rec.color
        refreshNameLabel()

        if entry.isCustom {
            actionButton.title = "Delete"
            actionButton.isEnabled = true
            configureUseButton(available: true, isActive: isActive)
            return
        }

        if entry.isBundled {
            actionButton.title = "-"
            actionButton.isEnabled = false
            configureUseButton(available: true, isActive: isActive)
            return
        }

        switch ModelLocator.status(for: entry.filename) {
        case .downloaded:
            actionButton.title = "Delete"
            actionButton.isEnabled = true
            configureUseButton(available: true, isActive: isActive)
        case .available:
            actionButton.title = "Download"
            actionButton.isEnabled = true
            configureUseButton(available: false, isActive: false)
        case .bundled:
            actionButton.title = "-"
            actionButton.isEnabled = false
            configureUseButton(available: true, isActive: isActive)
        }
    }

    private func configureUseButton(available: Bool, isActive: Bool) {
        if isActive {
            useButton.title = "Active"
            useButton.isEnabled = false
        } else if available {
            useButton.title = "Use"
            useButton.isEnabled = true
        } else {
            useButton.title = "Use"
            useButton.isEnabled = false
        }
    }

    func setDownloading(progress: Double, downloader: ModelDownloader) {
        activeDownloader = downloader
        statusLabel.isHidden = true
        statusDot.isHidden = true
        progressBar.isHidden = false
        progressBar.doubleValue = progress
        actionButton.title = "Cancel"
        actionButton.isEnabled = true
    }

    func cancelDownload() {
        activeDownloader?.cancel()
        refreshStatus()
    }

    @objc private func actionTapped() {
        if activeDownloader != nil {
            onCancel?()
            return
        }
        switch ModelLocator.status(for: entry.filename) {
        case .bundled: break
        case .downloaded: onDelete?()
        case .available: onDownload?()
        }
    }

    @objc private func useTapped() {
        onUse?()
    }
}
