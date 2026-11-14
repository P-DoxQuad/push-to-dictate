import Foundation

struct CatalogModel {
    let displayName: String
    let filename: String
    let sizeBytes: Int64
    let url: URL?
    let isBundled: Bool
}

enum ModelCatalog {
    static let entries: [CatalogModel] = [
        CatalogModel(
            displayName: "tiny.en (Q8_0)",
            filename: "ggml-tiny.en-q8_0.bin",
            sizeBytes: 43_550_795,
            url: URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-tiny.en-q8_0.bin")!,
            isBundled: true
        ),
        CatalogModel(
            displayName: "base.en (Q8_0)",
            filename: "ggml-base.en-q8_0.bin",
            sizeBytes: 81_768_586,
            url: URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base.en-q8_0.bin")!,
            isBundled: true
        ),
        CatalogModel(
            displayName: "small.en (Q8_0)",
            filename: "ggml-small.en-q8_0.bin",
            sizeBytes: 264_477_561,
            url: URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-small.en-q8_0.bin")!,
            isBundled: false
        ),
        CatalogModel(
            displayName: "medium.en (Q8_0)",
            filename: "ggml-medium.en-q8_0.bin",
            sizeBytes: 823_382_461,
            url: URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-medium.en-q8_0.bin")!,
            isBundled: false
        )
    ]

    static func formatBytes(_ bytes: Int64) -> String {
        let fmt = ByteCountFormatter()
        fmt.allowedUnits = [.useMB, .useGB]
        fmt.countStyle = .file
        return fmt.string(fromByteCount: bytes)
    }
}

enum ModelStatus {
    case bundled
    case downloaded(URL)
    case available
}

enum ModelLocator {
    static func status(for filename: String) -> ModelStatus {
        let stem = (filename as NSString).deletingPathExtension
        let ext = (filename as NSString).pathExtension
        if Bundle.main.url(forResource: stem,
                           withExtension: ext.isEmpty ? nil : ext) != nil {
            return .bundled
        }
        let url = Preferences.writableModelsDirectory.appendingPathComponent(filename)
        if FileManager.default.fileExists(atPath: url.path) {
            return .downloaded(url)
        }
        return .available
    }

    /// Lists user-supplied `ggml-*.bin` files in the writable folder that are
    /// not present in the fixed catalog.
    static func extraDownloadedFilenames() -> [String] {
        let dir = Preferences.writableModelsDirectory
        let catalogSet = Set(ModelCatalog.entries.map { $0.filename })
        guard let items = try? FileManager.default.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: nil) else { return [] }
        return items
            .filter { $0.pathExtension == "bin"
                   && $0.lastPathComponent.hasPrefix("ggml-")
                   && !catalogSet.contains($0.lastPathComponent) }
            .map { $0.lastPathComponent }
            .sorted()
    }
}
