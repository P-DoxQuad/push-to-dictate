import Foundation
import AppKit

enum HardwareTier: Int, Comparable {
    case veryLow = 0
    case low = 1
    case mid = 2
    case high = 3

    static func < (lhs: HardwareTier, rhs: HardwareTier) -> Bool {
        return lhs.rawValue < rhs.rawValue
    }
}

enum HostCapabilities {
    static let tier: HardwareTier = computeTier()

    private static func computeTier() -> HardwareTier {
        let avx2 = sysctlFlag("hw.optional.avx2_0")
        let fma = sysctlFlag("hw.optional.fma")
        let cores = ProcessInfo.processInfo.activeProcessorCount
        if avx2 && fma {
            return cores >= 8 ? .high : .mid
        }
        return cores >= 8 ? .low : .veryLow
    }

    private static func sysctlFlag(_ name: String) -> Bool {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        return sysctlbyname(name, &value, &size, nil, 0) == 0 && value == 1
    }
}

enum ModelRecommendation {
    case recommended
    case slow
    case notRecommended

    var label: String {
        switch self {
        case .recommended: return "Recommended"
        case .slow: return "Slow"
        case .notRecommended: return "Not recommended"
        }
    }

    var color: NSColor {
        switch self {
        case .recommended: return .systemGreen
        case .slow: return .systemOrange
        case .notRecommended: return .systemRed
        }
    }

    static func rate(minTier: HardwareTier, host: HardwareTier = HostCapabilities.tier)
        -> ModelRecommendation {
        if host > minTier { return .recommended }
        if host == minTier { return .slow }
        return .notRecommended
    }
}

struct CatalogModel {
    let displayName: String
    let filename: String
    let sizeBytes: Int64
    let url: URL?
    let isBundled: Bool
    let minTier: HardwareTier
    let isCustom: Bool
}

// Catalog of local inference models downloadable from the project's own
// GitHub Release asset tag. The "openai-models-v1" tag name refers to the
// origin of the Whisper weights (OpenAI's open-source speech model), not the
// OpenAI cloud backend. These files are consumed by whisper-cli on CPU and
// never leave the user's machine.
enum ModelCatalog {
    static let entries: [CatalogModel] = [
        CatalogModel(
            displayName: "tiny.en (Q8_0)",
            filename: "ggml-tiny.en-q8_0.bin",
            sizeBytes: 43_550_795,
            url: URL(string: "https://github.com/P-DoxQuad/push-to-dictate/releases/download/openai-models-v1/ggml-tiny.en-q8_0.bin")!,
            isBundled: true,
            minTier: .veryLow,
            isCustom: false
        ),
        CatalogModel(
            displayName: "base.en (Q8_0)",
            filename: "ggml-base.en-q8_0.bin",
            sizeBytes: 81_768_586,
            url: URL(string: "https://github.com/P-DoxQuad/push-to-dictate/releases/download/openai-models-v1/ggml-base.en-q8_0.bin")!,
            isBundled: true,
            minTier: .veryLow,
            isCustom: false
        ),
        CatalogModel(
            displayName: "small.en (Q8_0)",
            filename: "ggml-small.en-q8_0.bin",
            sizeBytes: 264_477_561,
            url: URL(string: "https://github.com/P-DoxQuad/push-to-dictate/releases/download/openai-models-v1/ggml-small.en-q8_0.bin")!,
            isBundled: false,
            minTier: .low,
            isCustom: false
        ),
        CatalogModel(
            displayName: "medium.en (Q8_0)",
            filename: "ggml-medium.en-q8_0.bin",
            sizeBytes: 823_382_461,
            url: URL(string: "https://github.com/P-DoxQuad/push-to-dictate/releases/download/openai-models-v1/ggml-medium.en-q8_0.bin")!,
            isBundled: false,
            minTier: .mid,
            isCustom: false
        ),
        CatalogModel(
            displayName: "large-v3-turbo (Q8_0)",
            filename: "ggml-large-v3-turbo-q8_0.bin",
            sizeBytes: 874_188_075,
            url: URL(string: "https://github.com/P-DoxQuad/push-to-dictate/releases/download/openai-models-v1/ggml-large-v3-turbo-q8_0.bin")!,
            isBundled: false,
            minTier: .high,
            isCustom: false
        )
    ]

    /// First-launch pick: the highest-tier catalog entry whose rating is `.recommended`
    /// and which is already present on disk (bundled or downloaded). Falls back to the
    /// first bundled entry if nothing qualifies.
    static func bestRecommendedPresent() -> CatalogModel {
        let present = entries.filter { entry -> Bool in
            if entry.isBundled { return true }
            if case .downloaded = ModelLocator.status(for: entry.filename) { return true }
            return false
        }
        let recommended = present.filter {
            ModelRecommendation.rate(minTier: $0.minTier) == .recommended
        }
        // Prefer the highest minTier that's still Recommended: the best quality
        // the host can comfortably run.
        if let best = recommended.max(by: { $0.minTier < $1.minTier }) {
            return best
        }
        return entries.first(where: { $0.isBundled }) ?? entries[0]
    }

    /// Color for the model popup label. Matches the Manage Models dot color.
    /// Returns `nil` for filenames not in the catalog (custom models have no rating).
    static func color(forFilename filename: String) -> NSColor? {
        guard let entry = entries.first(where: { $0.filename == filename }) else {
            return nil
        }
        return ModelRecommendation.rate(minTier: entry.minTier).color
    }

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
