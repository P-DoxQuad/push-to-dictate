import Cocoa
import Foundation

final class UpdateInstaller: NSObject, URLSessionDownloadDelegate {

    // Callbacks are invoked on arbitrary background threads; UI callers must
    // hop to main themselves.
    var onStageChange: ((String) -> Void)?
    var onProgress: ((Double) -> Void)?
    var onFailure: ((String) -> Void)?
    var onReadyToRelaunch: (() -> Void)?

    private let downloadURL: URL
    private var downloadTask: URLSessionDownloadTask?
    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 600
        return URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }()

    init(downloadURL: URL) {
        self.downloadURL = downloadURL
        super.init()
    }

    // Auto-install is offered only when the running bundle lives directly
    // under /Applications/. Any other location (DerivedData, ~/Applications,
    // Downloads, mounted disk image) falls through to Open Release Page.
    static func canInstallInPlace() -> Bool {
        let bundleURL = Bundle.main.bundleURL
        let parent = bundleURL.deletingLastPathComponent().path
        return parent == "/Applications"
    }

    func start() {
        onStageChange?("Downloading\u{2026}")
        let task = session.downloadTask(with: downloadURL)
        downloadTask = task
        task.resume()
    }

    // MARK: - URLSessionDownloadDelegate

    func urlSession(_ session: URLSession,
                    downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        if totalBytesExpectedToWrite > 0 {
            let fraction = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
            onProgress?(min(max(fraction, 0), 1))
        }
    }

    func urlSession(_ session: URLSession,
                    downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        if let http = downloadTask.response as? HTTPURLResponse, http.statusCode != 200 {
            fail("server returned \(http.statusCode)")
            return
        }
        processDownloadedZip(at: location)
    }

    func urlSession(_ session: URLSession,
                    task: URLSessionTask,
                    didCompleteWithError error: Error?) {
        if let error = error {
            fail("download failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Pipeline stages

    private func processDownloadedZip(at tempLocation: URL) {
        let cachesDir = FileManager.default.urls(for: .cachesDirectory,
                                                 in: .userDomainMask).first!
            .appendingPathComponent("push-to-dictate", isDirectory: true)
            .appendingPathComponent("updates", isDirectory: true)
        let stagingDir = cachesDir.appendingPathComponent("stage-\(UUID().uuidString)",
                                                          isDirectory: true)
        let zipDest = cachesDir.appendingPathComponent("latest.zip")

        do {
            try FileManager.default.createDirectory(at: cachesDir,
                                                    withIntermediateDirectories: true)
            try? FileManager.default.removeItem(at: zipDest)
            try FileManager.default.moveItem(at: tempLocation, to: zipDest)
            try FileManager.default.createDirectory(at: stagingDir,
                                                    withIntermediateDirectories: true)
        } catch {
            fail("couldn't prepare download: \(error.localizedDescription)")
            return
        }

        onStageChange?("Extracting\u{2026}")
        onProgress?(0)
        if let extractErr = runExtract(zip: zipDest, into: stagingDir) {
            fail(extractErr)
            return
        }

        guard let appURL = findAppBundle(in: stagingDir) else {
            fail("no .app found in download")
            return
        }

        onStageChange?("Preparing install\u{2026}")
        stripQuarantine(appURL)

        onStageChange?("Installing\u{2026}")
        installAndRelaunch(stagedApp: appURL)
    }

    private func runExtract(zip: URL, into destination: URL) -> String? {
        let proc = Process()
        proc.launchPath = "/usr/bin/ditto"
        proc.arguments = ["-xk", zip.path, destination.path]
        let errPipe = Pipe()
        proc.standardError = errPipe
        proc.launch()
        proc.waitUntilExit()
        if proc.terminationStatus != 0 {
            let data = errPipe.fileHandleForReading.readDataToEndOfFile()
            let message = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return "extract failed (\(proc.terminationStatus))"
                + (message.isEmpty ? "" : ": \(message)")
        }
        return nil
    }

    private func findAppBundle(in directory: URL) -> URL? {
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil) else { return nil }
        let apps = contents.filter { $0.pathExtension == "app" }
        return apps.count == 1 ? apps[0] : nil
    }

    private func stripQuarantine(_ url: URL) {
        let proc = Process()
        proc.launchPath = "/usr/bin/xattr"
        proc.arguments = ["-dr", "com.apple.quarantine", url.path]
        proc.standardError = Pipe()
        proc.standardOutput = Pipe()
        proc.launch()
        proc.waitUntilExit()
    }

    // Writes a short shell script to /tmp that waits for the current process
    // to exit, replaces the installed bundle, and relaunches. Script is run
    // detached so it survives our termination. Caller is expected to call
    // onReadyToRelaunch, which in turn should terminate the app.
    private func installAndRelaunch(stagedApp: URL) {
        let installedBundle = Bundle.main.bundleURL
        let pid = ProcessInfo.processInfo.processIdentifier
        let scriptURL = URL(fileURLWithPath: "/tmp")
            .appendingPathComponent("push-to-dictate-updater-\(pid).sh")

        let script = """
        #!/bin/sh
        set -e
        PID=\(pid)
        STAGED=\(shellQuote(stagedApp.path))
        INSTALLED=\(shellQuote(installedBundle.path))

        # Wait for the running app to exit (poll up to 20s).
        for i in $(seq 1 40); do
            if ! kill -0 "$PID" 2>/dev/null; then break; fi
            sleep 0.5
        done

        rm -rf "$INSTALLED"
        mv "$STAGED" "$INSTALLED"
        open "$INSTALLED"
        """

        do {
            try script.write(to: scriptURL, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
        } catch {
            fail("couldn't stage installer script: \(error.localizedDescription)")
            return
        }

        let proc = Process()
        proc.launchPath = "/bin/sh"
        proc.arguments = [scriptURL.path]
        do {
            try launch(proc)
        } catch {
            fail("couldn't launch installer: \(error.localizedDescription)")
            return
        }

        Logger.info("update: installer script launched, terminating to let it swap bundle")
        onReadyToRelaunch?()
    }

    private func launch(_ proc: Process) throws {
        proc.launch()
    }

    private func shellQuote(_ s: String) -> String {
        return "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private func fail(_ message: String) {
        Logger.error("update", detail: message)
        onFailure?(message)
    }
}
