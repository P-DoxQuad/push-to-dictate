import Foundation

enum Logger {
    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    // Serialize all file writes so appends from different threads don't interleave.
    private static let queue = DispatchQueue(label: "push-to-dictate.logger")

    static var logFileURL: URL {
        return Preferences.defaultSupportDirectory
            .appendingPathComponent("logs", isDirectory: true)
            .appendingPathComponent("push-to-dictate.log")
    }

    static func clear() {
        queue.sync {
            try? Data().write(to: logFileURL, options: [.atomic])
        }
    }

    static func error(_ title: String, detail: String) {
        NSLog("push-to-dictate: ERROR: %@: %@", title, detail)
        append(level: "ERROR", message: "\(title) — \(detail)")
    }

    static func info(_ message: String) {
        NSLog("push-to-dictate: %@", message)
        if Preferences.shared.logEverything {
            append(level: "INFO", message: message)
        }
    }

    private static func append(level: String, message: String) {
        let ts = formatter.string(from: Date())
        let line = "\(ts)  \(level)  \(message)\n"
        queue.async {
            let url = logFileURL
            let dir = url.deletingLastPathComponent()
            try? FileManager.default.createDirectory(at: dir,
                                                     withIntermediateDirectories: true,
                                                     attributes: nil)
            guard let data = line.data(using: .utf8) else { return }
            if !FileManager.default.fileExists(atPath: url.path) {
                try? data.write(to: url, options: [.atomic])
                return
            }
            if let handle = try? FileHandle(forWritingTo: url) {
                handle.seekToEndOfFile()
                handle.write(data)
                handle.closeFile()
            }
        }
    }
}
