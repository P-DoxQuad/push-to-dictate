import Cocoa

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusController: StatusItemController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        maybeAutoSelectModel()
        maybePromptMoveToApplications()
        statusController = StatusItemController()
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
