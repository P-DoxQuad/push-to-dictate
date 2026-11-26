import Cocoa

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusController: StatusItemController?
    private var autoUpdateTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        maybeAutoSelectModel()
        AppearanceManager.shared.apply()
        maybePromptMoveToApplications()
        statusController = StatusItemController()
        setupAutomaticUpdateChecks()
    }

    private func setupAutomaticUpdateChecks() {
        let prefs = Preferences.shared
        guard prefs.autoUpdateCheckEnabled else { return }

        // Startup check: always runs on launch when enabled, regardless of
        // frequency choice. For .daily this doubles as the catch-up check
        // if the app was closed for more than a day.
        let shouldCheckAtStartup: Bool
        switch prefs.autoUpdateCheckFrequency {
        case .atStartup:
            shouldCheckAtStartup = true
        case .daily:
            if let last = prefs.lastAutoUpdateCheckDate {
                shouldCheckAtStartup = Date().timeIntervalSince(last) >= 24 * 3600
            } else {
                shouldCheckAtStartup = true
            }
        }
        if shouldCheckAtStartup {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
                self?.statusController?.performSilentUpdateCheck()
            }
        }

        // Daily timer: only armed if that's the configured frequency.
        if prefs.autoUpdateCheckFrequency == .daily {
            autoUpdateTimer?.invalidate()
            autoUpdateTimer = Timer.scheduledTimer(
                timeInterval: 24 * 3600, target: self,
                selector: #selector(dailyAutoUpdateFired),
                userInfo: nil, repeats: true)
        }
    }

    @objc private func dailyAutoUpdateFired() {
        guard Preferences.shared.autoUpdateCheckEnabled else { return }
        statusController?.performSilentUpdateCheck()
    }

    // Called by the preferences UI after the user toggles the checkbox
    // or changes the frequency. Tears down the old timer and reruns
    // setup against the new preference state.
    func reconfigureAutomaticUpdateChecks() {
        autoUpdateTimer?.invalidate()
        autoUpdateTimer = nil
        setupAutomaticUpdateChecks()
    }

    private func maybeAutoSelectModel() {
        let prefs = Preferences.shared
        if prefs.didAutoSelectModel { return }
        let best = ModelCatalog.bestRecommendedPresent()
        prefs.localModelFilename = best.filename
        prefs.didAutoSelectModel = true
    }

    private func maybePromptMoveToApplications() {
        let path = Bundle.main.bundleURL.path
        let home = NSHomeDirectory()

        // Already installed, nothing to do.
        if path.hasPrefix("/Applications/") || path.hasPrefix(home + "/Applications/") {
            return
        }
        // Developer build: don't nag during Xcode run cycles.
        if path.contains("/DerivedData/") || path.contains("/Developer/Xcode/") {
            return
        }
        // User opted out.
        if Preferences.shared.suppressedMoveToApplicationsPrompt {
            return
        }

        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Move Push to Dictate to the Applications folder?"
        alert.informativeText = "Push to Dictate works best when installed in /Applications/. " +
            "Moving it there now lets it launch cleanly, be kept out of Downloads, and remain in " +
            "a stable location for Launch-at-Login."
        alert.addButton(withTitle: "Move to Applications")
        alert.addButton(withTitle: "Not Now")
        alert.addButton(withTitle: "Don't Ask Again")

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            performMoveToApplications()
        case .alertThirdButtonReturn:
            Preferences.shared.suppressedMoveToApplicationsPrompt = true
        default:
            break
        }
    }

    private func performMoveToApplications() {
        let src = Bundle.main.bundleURL
        let dst = URL(fileURLWithPath: "/Applications/")
            .appendingPathComponent(src.lastPathComponent)

        do {
            if FileManager.default.fileExists(atPath: dst.path) {
                try FileManager.default.removeItem(at: dst)
            }
            try FileManager.default.moveItem(at: src, to: dst)
        } catch {
            let alert = NSAlert()
            alert.messageText = "Could not move to Applications"
            alert.informativeText = error.localizedDescription
            alert.runModal()
            return
        }

        // Relaunch from the new location via a detached shell so we can exit cleanly
        // before Launch Services starts the fresh copy.
        let task = Process()
        task.launchPath = "/bin/sh"
        task.arguments = ["-c", "sleep 1; open '\(dst.path)'"]
        task.launch()

        NSApp.terminate(nil)
    }
}
