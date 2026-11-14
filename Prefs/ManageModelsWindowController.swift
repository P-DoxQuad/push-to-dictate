import Cocoa

final class ManageModelsWindowController: NSWindowController {
    var onDidChange: (() -> Void)?

    private let customStack = NSStackView()
    private let customURLField = NSTextField()
    private let emptyCustomLabel = NSTextField(labelWithString:
        "No custom models downloaded yet.")
    private var rowViews: [String: ModelRowView] = [:]
    private var extraRowViews: [String: ModelRowView] = [:]

    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 520),
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
        let catalogHeader = NSTextField(labelWithString: "Available transcription models")
        catalogHeader.font = NSFont.boldSystemFont(ofSize: NSFont.systemFontSize)
        outer.addArrangedSubview(catalogHeader)

        for entry in ModelCatalog.entries {
            let row = ModelRowView(entry: entry)
            row.onDownload = { [weak self] in self?.downloadCatalogEntry(entry) }
            row.onDelete = { [weak self] in self?.deleteDownloaded(entry) }
            row.onCancel = { [weak self] in self?.cancelDownload(entry) }
            rowViews[entry.filename] = row
            outer.addArrangedSubview(row)
        }

        let catalogDivider = NSBox()
        catalogDivider.boxType = .separator
        outer.addArrangedSubview(catalogDivider)
        catalogDivider.widthAnchor.constraint(equalTo: outer.widthAnchor,
                                              constant: -40).isActive = true

        // Fixed "Custom models" header above the scroll area.
        let customHeader = NSTextField(labelWithString: "Custom models")
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
        scroll.borderType = .bezelBorder
        scroll.drawsBackground = false
        scroll.documentView = flipped
        scroll.translatesAutoresizingMaskIntoConstraints = false
        outer.addArrangedSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.widthAnchor.constraint(equalTo: outer.widthAnchor, constant: -40),
            scroll.heightAnchor.constraint(equalToConstant: 240),
            flipped.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor)
        ])

        // Fixed bottom area.
        let divider = NSBox()
        divider.boxType = .separator
        outer.addArrangedSubview(divider)
        divider.widthAnchor.constraint(equalTo: outer.widthAnchor,
                                       constant: -40).isActive = true

        let customLabel = NSTextField(labelWithString: "Download a custom model from a URL:")
        outer.addArrangedSubview(customLabel)

        customURLField.placeholderString = "https://.../ggml-your-model.bin"
        let customDownload = NSButton(title: "Download",
                                       target: self,
                                       action: #selector(downloadCustom))
        let customRow = NSStackView(views: [customURLField, customDownload])
        customRow.orientation = .horizontal
        customRow.spacing = 8
        customURLField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        customRow.translatesAutoresizingMaskIntoConstraints = false
        outer.addArrangedSubview(customRow)
        customRow.widthAnchor.constraint(equalTo: outer.widthAnchor,
                                         constant: -40).isActive = true

        let revealButton = NSButton(title: "Reveal Models Folder",
                                    target: self,
                                    action: #selector(revealModelsFolder))
        let closeButton = NSButton(title: "Close",
                                   target: self,
                                   action: #selector(closeSheet))
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
                                     isBundled: false)
            let row = ModelRowView(entry: entry)
            row.onDelete = { [weak self] in self?.deleteExtra(filename: filename) }
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
            // Custom URL path — no row view, just an alert on completion.
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

// MARK: - ModelRowView

private final class ModelRowView: NSView {
    private let entry: CatalogModel

    private let nameLabel = NSTextField(labelWithString: "")
    private let sizeLabel = NSTextField(labelWithString: "")
    private let statusLabel = NSTextField(labelWithString: "")
    private let progressBar = NSProgressIndicator()
    private let actionButton = NSButton(title: "", target: nil, action: nil)

    private weak var activeDownloader: ModelDownloader?

    var onDownload: (() -> Void)?
    var onDelete: (() -> Void)?
    var onCancel: (() -> Void)?

    init(entry: CatalogModel) {
        self.entry = entry
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        setupSubviews()
        refreshStatus()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func setupSubviews() {
        nameLabel.stringValue = entry.displayName
        nameLabel.font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
        sizeLabel.stringValue = ModelCatalog.formatBytes(entry.sizeBytes)
        sizeLabel.textColor = .secondaryLabelColor
        statusLabel.textColor = .secondaryLabelColor

        progressBar.isIndeterminate = false
        progressBar.minValue = 0
        progressBar.maxValue = 1
        progressBar.doubleValue = 0
        progressBar.controlSize = .small
        progressBar.style = .bar
        progressBar.isHidden = true

        actionButton.bezelStyle = .rounded
        actionButton.target = self
        actionButton.action = #selector(actionTapped)

        let statusContainer = NSView()
        statusContainer.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        progressBar.translatesAutoresizingMaskIntoConstraints = false
        statusContainer.addSubview(statusLabel)
        statusContainer.addSubview(progressBar)
        NSLayoutConstraint.activate([
            statusLabel.leadingAnchor.constraint(equalTo: statusContainer.leadingAnchor),
            statusLabel.trailingAnchor.constraint(equalTo: statusContainer.trailingAnchor),
            statusLabel.centerYAnchor.constraint(equalTo: statusContainer.centerYAnchor),
            progressBar.leadingAnchor.constraint(equalTo: statusContainer.leadingAnchor),
            progressBar.trailingAnchor.constraint(equalTo: statusContainer.trailingAnchor),
            progressBar.centerYAnchor.constraint(equalTo: statusContainer.centerYAnchor)
        ])

        let row = NSStackView(views: [nameLabel, sizeLabel, statusContainer, actionButton])
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
            actionButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 90)
        ])
    }

    func refreshStatus() {
        activeDownloader = nil
        progressBar.isHidden = true
        progressBar.doubleValue = 0
        statusLabel.isHidden = false
        if entry.isBundled {
            statusLabel.stringValue = "Bundled"
            actionButton.title = "—"
            actionButton.isEnabled = false
            return
        }
        switch ModelLocator.status(for: entry.filename) {
        case .bundled:
            statusLabel.stringValue = "Bundled"
            actionButton.title = "—"
            actionButton.isEnabled = false
        case .downloaded:
            statusLabel.stringValue = "Downloaded"
            actionButton.title = "Delete"
            actionButton.isEnabled = true
        case .available:
            statusLabel.stringValue = "Not downloaded"
            actionButton.title = "Download"
            actionButton.isEnabled = true
        }
    }

    func setDownloading(progress: Double, downloader: ModelDownloader) {
        activeDownloader = downloader
        statusLabel.isHidden = true
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
}
