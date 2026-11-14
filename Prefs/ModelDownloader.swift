import Foundation

final class ModelDownloader: NSObject, URLSessionDownloadDelegate {
    enum DownloadError: Error {
        case httpStatus(Int)
        case invalidFile
        case ioError(Error)
    }

    enum DownloadResult {
        case success(URL)
        case failure(DownloadError)
    }

    var onProgress: ((Double) -> Void)?
    var onComplete: ((DownloadResult) -> Void)?

    private var session: URLSession!
    private var task: URLSessionDownloadTask?
    private let destinationURL: URL

    init(destination: URL) {
        self.destinationURL = destination
        super.init()
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 3600
        self.session = URLSession(configuration: config, delegate: self, delegateQueue: .main)
    }

    func start(from url: URL) {
        let t = session.downloadTask(with: url)
        self.task = t
        t.resume()
    }

    func cancel() {
        task?.cancel()
    }

    // MARK: - URLSessionDownloadDelegate

    func urlSession(_ session: URLSession,
                    downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        let fraction = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        onProgress?(fraction)
    }

    func urlSession(_ session: URLSession,
                    downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        if let http = downloadTask.response as? HTTPURLResponse, http.statusCode != 200 {
            onComplete?(.failure(.httpStatus(http.statusCode)))
            try? FileManager.default.removeItem(at: location)
            return
        }

        guard isValidGGML(fileURL: location) else {
            onComplete?(.failure(.invalidFile))
            try? FileManager.default.removeItem(at: location)
            return
        }

        let fm = FileManager.default
        let dir = destinationURL.deletingLastPathComponent()
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: nil)
            if fm.fileExists(atPath: destinationURL.path) {
                try fm.removeItem(at: destinationURL)
            }
            try fm.moveItem(at: location, to: destinationURL)
            onComplete?(.success(destinationURL))
        } catch {
            onComplete?(.failure(.ioError(error)))
        }
    }

    func urlSession(_ session: URLSession,
                    task: URLSessionTask,
                    didCompleteWithError error: Error?) {
        if let error = error {
            onComplete?(.failure(.ioError(error)))
        }
    }

    private func isValidGGML(fileURL: URL) -> Bool {
        // whisper.cpp ggml files begin with the magic bytes "ggml" or "lmgg" (endian variants).
        guard let handle = try? FileHandle(forReadingFrom: fileURL) else { return false }
        defer { handle.closeFile() }
        let head = handle.readData(ofLength: 4)
        guard head.count == 4 else { return false }
        let ascii = String(data: head, encoding: .ascii)
        return ascii == "ggml" || ascii == "lmgg"
    }
}
