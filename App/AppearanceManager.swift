import Cocoa

// Applies the user's chosen appearance mode (system/light/dark) to the app.
//
// On macOS 10.14 and newer: sets `NSApp.appearance` (10.14+ only) to the
// matching `NSAppearance`, and all AppKit windows + dynamic colors
// (`.labelColor`, `.windowBackgroundColor`, etc.) adapt automatically.
//
// On macOS 10.11-10.13: no system dark mode exists, and `NSApp.appearance`
// does not exist. Appearance is set per-window via `NSWindow.appearance`
// (`.vibrantDark` for dark, `.aqua` for light), the window's background
// color is set to a dark gray, and the content view is walked to override
// `textColor` on every non-editable `NSTextField` (labels, captions,
// hints) and tint the section containers to a lighter shade so they
// remain outlined against the darker window.
final class AppearanceManager: NSObject {

    static let shared = AppearanceManager()

    // Resolved current mode. `.system` is reduced to `.light` on pre-Mojave
    // (no system dark mode) and to the current system appearance on 10.14+.
    enum ResolvedMode { case light, dark }

    // View identifier used to mark section container boxes so the walker
    // can find them on appearance change and update their layer tint.
    static let sectionBoxIdentifier = NSUserInterfaceItemIdentifier("PQSectionBox")

    // View identifier used to mark NSTextFields whose `textColor` is
    // managed by their owner (e.g. the model rows' speed/best-pick
    // coloring). The applyTextColors walker skips any field tagged with
    // this identifier so the owner's color sticks.
    static let customColorIdentifier = NSUserInterfaceItemIdentifier("PQCustomColor")

    private var isObservingAppearance = false

    private override init() {
        super.init()
        // Pre-Mojave: listen for "Use dark menu bar and Dock" toggle so
        // Follow System re-applies live.
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(systemAppearanceChanged),
            name: NSNotification.Name("AppleInterfaceThemeChangedNotification"),
            object: nil
        )
        // 10.14+: observe NSApp.effectiveAppearance so Follow System picks
        // up OS-level light/dark flips (the NSAppearance cascade adapts
        // dynamic colors automatically, but our static section tint has
        // to be reapplied by hand).
        if #available(macOS 10.14, *) {
            NSApp.addObserver(self, forKeyPath: "effectiveAppearance",
                              options: [.new], context: nil)
            isObservingAppearance = true
        }
    }

    deinit {
        DistributedNotificationCenter.default().removeObserver(self)
        if isObservingAppearance {
            NSApp.removeObserver(self, forKeyPath: "effectiveAppearance")
        }
    }

    override func observeValue(forKeyPath keyPath: String?,
                               of object: Any?,
                               change: [NSKeyValueChangeKey: Any]?,
                               context: UnsafeMutableRawPointer?) {
        if keyPath == "effectiveAppearance" {
            guard Preferences.shared.appearanceMode == .system else { return }
            DispatchQueue.main.async { [weak self] in self?.apply() }
        }
    }

    @objc private func systemAppearanceChanged() {
        guard Preferences.shared.appearanceMode == .system else { return }
        DispatchQueue.main.async { [weak self] in self?.apply() }
    }

    // Call on launch and whenever the preference changes.
    func apply() {
        let mode = resolvedMode()
        if #available(macOS 10.14, *) {
            setAppAppearance(for: Preferences.shared.appearanceMode)
            // NSAppearance cascades through NSApp for dynamic colors, but
            // static layer tints (section boxes) don't adapt and need a
            // manual pass.
            for window in NSApp.windows {
                if window.contentView != nil { updateSectionTints(in: window, mode: mode) }
            }
            return
        }
        applyManualToAllWindows(mode: mode)
    }

    // Apply appearance to a specific window. On 10.14+ this walks the
    // window to refresh static tints. On pre-Mojave this also sets
    // window.appearance and overrides label text colors.
    func applyToWindow(_ window: NSWindow) {
        let mode = resolvedMode()
        if #available(macOS 10.14, *) {
            updateSectionTints(in: window, mode: mode)
            return
        }
        applyManual(to: window, mode: mode)
    }

    // The CGColor used for section container boxes. Darker than the window
    // background in light mode, lighter than the window background in dark
    // mode, so the section outline is visible in both.
    func sectionBackgroundCGColor() -> CGColor {
        switch resolvedMode() {
        case .light: return NSColor(white: 0.0, alpha: 0.05).cgColor
        // 0.15 over window bg 0.18 = effective ~0.30, distinctly brighter
        // than the AppKit push-button fill (sampled at 0.235) so buttons
        // sit visibly on top of the section instead of disappearing.
        case .dark:  return NSColor(white: 1.0, alpha: 0.15).cgColor
        }
    }

    private func updateSectionTints(in window: NSWindow, mode: ResolvedMode) {
        guard let view = window.contentView else { return }
        let tint = sectionBackgroundCGColor()
        walkAndTintSections(view, tint: tint)
    }

    private func walkAndTintSections(_ view: NSView, tint: CGColor) {
        if view.identifier == AppearanceManager.sectionBoxIdentifier {
            view.layer?.backgroundColor = tint
        }
        for sub in view.subviews { walkAndTintSections(sub, tint: tint) }
    }

    // MARK: - Internal

    func resolvedMode() -> ResolvedMode {
        switch Preferences.shared.appearanceMode {
        case .light: return .light
        case .dark:  return .dark
        case .system:
            if #available(macOS 10.14, *) {
                let name = NSApp.effectiveAppearance.name
                if name == .darkAqua { return .dark }
                return .light
            }
            // On 10.10-10.13, "Use dark menu bar and Dock" writes
            // AppleInterfaceStyle=Dark into NSGlobalDomain. Absent = light.
            let style = UserDefaults.standard.string(forKey: "AppleInterfaceStyle")
            return style == "Dark" ? .dark : .light
        }
    }

    @available(macOS 10.14, *)
    private func setAppAppearance(for pref: Preferences.AppearanceMode) {
        switch pref {
        case .system: NSApp.appearance = nil
        case .light:  NSApp.appearance = NSAppearance(named: .aqua)
        case .dark:   NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }

    private func applyManualToAllWindows(mode: ResolvedMode) {
        for window in NSApp.windows {
            applyManual(to: window, mode: mode)
        }
    }

    private func applyManual(to window: NSWindow, mode: ResolvedMode) {
        // The menu-bar status item owns a hidden window of its own; skip
        // anything that isn't presenting user chrome.
        guard let view = window.contentView else { return }
        switch mode {
        case .light: window.appearance = NSAppearance(named: .aqua)
        case .dark:  window.appearance = NSAppearance(named: .vibrantDark)
        }
        window.backgroundColor = backgroundColor(for: mode)
        applyTextColors(view, mode: mode)
        walkAndTintSections(view, tint: sectionBackgroundCGColor())
    }

    private func applyTextColors(_ view: NSView, mode: ResolvedMode) {
        let primary = foregroundColor(for: mode)
        let secondary = secondaryForegroundColor(for: mode)
        for sub in view.subviews {
            // Skip inside table views: they manage per-row cell colors
            // (e.g. the blue "installed" badge in the releases table, the
            // sidebar selection color) and clobbering them would fight
            // that logic. NSScrollView is intentionally not skipped;
            // Preferences panes live inside one.
            if sub is NSTableView { continue }
            if let tf = sub as? NSTextField, !tf.isEditable {
                // Only override non-editable labels/captions/hints. Editable
                // fields keep their native textColor so typed text stays
                // legible. Fields tagged with the custom-color identifier
                // are managed by their owner (e.g. speed-rated model
                // rows) and we leave them alone.
                if tf.identifier != AppearanceManager.customColorIdentifier {
                    let isSecondary =
                        (tf.textColor == NSColor.secondaryLabelColor)
                        || (tf.font?.pointSize == 11)
                    tf.textColor = isSecondary ? secondary : primary
                }
            }
            applyTextColors(sub, mode: mode)
        }
    }

    // Public subtree helper. Called by owners of view hierarchies that are
    // cached off-window (e.g. preference panes constructed eagerly but
    // only one inserted at a time). Updates section tints always, and on
    // pre-Mojave also updates text colors.
    func applyToSubtree(_ view: NSView) {
        let mode = resolvedMode()
        walkAndTintSections(view, tint: sectionBackgroundCGColor())
        if #available(macOS 10.14, *) { return }
        applyTextColors(view, mode: mode)
    }

    private func backgroundColor(for mode: ResolvedMode) -> NSColor {
        switch mode {
        case .light: return NSColor.windowBackgroundColor
        case .dark:  return NSColor(white: 0.18, alpha: 1.0)
        }
    }

    private func foregroundColor(for mode: ResolvedMode) -> NSColor {
        switch mode {
        case .light: return NSColor.labelColor
        case .dark:  return NSColor(white: 0.95, alpha: 1.0)
        }
    }

    private func secondaryForegroundColor(for mode: ResolvedMode) -> NSColor {
        switch mode {
        case .light: return NSColor.secondaryLabelColor
        case .dark:  return NSColor(white: 0.70, alpha: 1.0)
        }
    }
}
