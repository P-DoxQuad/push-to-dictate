import Foundation
import AppKit

// MARK: - Model descriptor

// Parsed form of a whisper.cpp model filename. Standard naming is
// `ggml-<family>[.en]-<quant>.bin`, e.g. `ggml-base.en-q8_0.bin` or
// `ggml-large-v3-turbo-q4_0.bin`. Family drives transcription accuracy;
// quant drives the inference-cost multiplier.
enum ModelFamily {
    case tiny, base, small, medium, large

    // Relative throughput cost per second of audio, measured roughly
    // against tiny.en. Values are approximate whisper.cpp runtime ratios.
    var weight: Double {
        switch self {
        case .tiny: return 1.0
        case .base: return 2.5
        case .small: return 7.0
        case .medium: return 22.0
        case .large: return 45.0
        }
    }

    // Accuracy ordering. Higher = better transcription for the same audio.
    var accuracyRank: Int {
        switch self {
        case .tiny: return 1
        case .base: return 2
        case .small: return 3
        case .medium: return 4
        case .large: return 5
        }
    }
}

enum ModelQuant {
    case q4, q5, q6, q8, f16

    // Relative cost multiplier within a family. Spread is intentionally
    // narrow: in whisper.cpp, Q4 vs Q8 is roughly a 25% speed delta, not
    // a 2x one.
    var weight: Double {
        switch self {
        case .q4:  return 0.50
        case .q5:  return 0.55
        case .q6:  return 0.60
        case .q8:  return 0.65
        case .f16: return 1.00
        }
    }
}

struct ModelDescriptor {
    let family: ModelFamily
    let quant: ModelQuant

    var cost: Double { return family.weight * quant.weight }

    // Parses a whisper.cpp ggml model filename. Returns nil when the
    // filename doesn't match a recognisable pattern (rating code falls
    // back to a file-size heuristic in that case).
    static func parse(filename: String) -> ModelDescriptor? {
        let lower = filename.lowercased()
        let family: ModelFamily
        if lower.contains("tiny")        { family = .tiny }
        else if lower.contains("base")   { family = .base }
        else if lower.contains("small")  { family = .small }
        else if lower.contains("medium") { family = .medium }
        else if lower.contains("large")  { family = .large }
        else { return nil }

        let quant: ModelQuant
        if lower.contains("q4")                                   { quant = .q4 }
        else if lower.contains("q5")                              { quant = .q5 }
        else if lower.contains("q6")                              { quant = .q6 }
        else if lower.contains("q8")                              { quant = .q8 }
        else if lower.contains("f16") || lower.contains("fp16")   { quant = .f16 }
        else                                                      { quant = .f16 }

        return ModelDescriptor(family: family, quant: quant)
    }
}

// MARK: - Host capability

enum HostCapabilities {
    // Physical core count. Hyperthreaded logical cores contribute far
    // less than real cores for whisper.cpp's tight numeric loops, so the
    // rating caps effective threads at this number rather than the
    // logical count.
    static let physicalCores: Int = {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        if sysctlbyname("hw.physicalcpu", &value, &size, nil, 0) == 0 && value > 0 {
            return Int(value)
        }
        return max(1, ProcessInfo.processInfo.activeProcessorCount)
    }()

    static let hasAVX2FMA: Bool = {
        return sysctlFlag("hw.optional.avx2_0") && sysctlFlag("hw.optional.fma")
    }()

    static let isARM64: Bool = {
        var size = 0
        if sysctlbyname("hw.machine", nil, &size, nil, 0) != 0 || size == 0 {
            return false
        }
        var bytes = [CChar](repeating: 0, count: size)
        if sysctlbyname("hw.machine", &bytes, &size, nil, 0) != 0 { return false }
        let name = String(cString: bytes)
        return name.hasPrefix("arm64")
    }()

    // Composite throughput score for the current host, given the thread
    // preference. Driven by three factors:
    //   effective_threads: user's thread pref capped at physicalCores.
    //                      Prevents hyperthreads from inflating the score.
    //   simd_factor:       1.0 on arm64 (NEON always available) or Intel
    //                      with AVX2+FMA; 0.4 on older Intels without
    //                      those extensions.
    //   arch_factor:       1.3 on arm64 (Apple Silicon is meaningfully
    //                      faster per core on whisper.cpp than Intel);
    //                      1.0 on x86_64.
    static func currentCapability(threads: Int) -> Double {
        let effective = Double(min(max(1, threads), physicalCores))
        let simd = (isARM64 || hasAVX2FMA) ? 1.0 : 0.4
        let arch = isARM64 ? 1.3 : 1.0
        return effective * simd * arch
    }

    private static func sysctlFlag(_ name: String) -> Bool {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        return sysctlbyname(name, &value, &size, nil, 0) == 0 && value == 1
    }
}

// MARK: - Rating

// Three-bucket speed classification. Describes how well a given model
// will run on this host; does not comment on which model to pick (the
// `bestPickFilename` function handles that separately).
enum ModelRecommendation {
    case recommended
    case slow
    case notRecommended

    // User-visible speed label. Decoupled from the pick-recommendation
    // chip ("Best pick"), which is a separate visual layer added by the
    // row/popup. Green = fast, orange = slow, red = not recommended.
    var label: String {
        switch self {
        case .recommended:    return "Fast"
        case .slow:           return "Slow"
        case .notRecommended: return "Not recommended"
        }
    }

    var color: NSColor {
        switch self {
        case .recommended:    return .systemGreen
        case .slow:           return .systemOrange
        case .notRecommended: return .systemRed
        }
    }

    // Classifies a model by speed on the current host. Thresholds are
    // fixed (not host-tier-dependent): "will this feel fast in a
    // dictation context" is an absolute UX question, and weak hardware
    // simply has fewer models that pass. speed_score = model cost /
    // host capability.
    //   <= 0.4  recommended    (transcription in <= 40% of audio time)
    //   <= 1.5  slow           (runs, but noticeable lag)
    //    > 1.5  notRecommended
    static func rate(filename: String,
                     sizeBytes: Int64 = 0,
                     threads: Int = Preferences.shared.transcriptionThreads)
        -> ModelRecommendation {
        let capability = HostCapabilities.currentCapability(threads: threads)
        let cost = modelCost(filename: filename, sizeBytes: sizeBytes)
        let score = cost / capability
        if score <= 0.4 { return .recommended }
        if score <= 1.5 { return .slow }
        return .notRecommended
    }

    // Returns the single filename that is the best pick for this host
    // among the given candidates. Returns nil when no candidates are
    // supplied. The rule:
    //   1. Among candidates scoring Recommended, pick the largest
    //      accuracy family. Ties within a family: lowest quant (fastest
    //      variant). No Q8-over-Q4 bias.
    //   2. If no candidate is Recommended, pick the lowest-cost
    //      candidate overall (least painful on weak hardware).
    static func bestPickFilename(among filenames: [String],
                                 threads: Int = Preferences.shared.transcriptionThreads)
        -> String? {
        if filenames.isEmpty { return nil }
        let capability = HostCapabilities.currentCapability(threads: threads)

        struct Entry { let filename: String; let cost: Double; let family: Int; let quantWeight: Double }
        let parsed: [Entry] = filenames.compactMap { fn in
            guard let d = ModelDescriptor.parse(filename: fn) else { return nil }
            return Entry(filename: fn, cost: d.cost,
                         family: d.family.accuracyRank,
                         quantWeight: d.quant.weight)
        }
        if parsed.isEmpty { return filenames.first }

        let recommended = parsed.filter { $0.cost / capability <= 0.4 }
        if !recommended.isEmpty {
            // Prefer larger family; within a family prefer lower quant
            // (lower quant = faster, and dictation accuracy difference
            // between Q4 and Q8 for clean speech is negligible). Final
            // tiebreak on filename so callers with differently-ordered
            // input lists (alphabetical vs dictionary order) return the
            // same winner.
            let sorted = recommended.sorted { a, b in
                if a.family != b.family { return a.family > b.family }
                if a.quantWeight != b.quantWeight { return a.quantWeight < b.quantWeight }
                return a.filename < b.filename
            }
            return sorted.first?.filename
        }
        // Nothing qualifies as Recommended. Pick the least-painful;
        // same filename tiebreak so the choice is deterministic.
        let sortedByCost = parsed.sorted { a, b in
            if a.cost != b.cost { return a.cost < b.cost }
            return a.filename < b.filename
        }
        return sortedByCost.first?.filename
    }

    // MARK: - Cost estimation

    // Combined model cost. Parses the filename for family + quant when
    // possible; falls back to a size-derived estimate when the filename
    // doesn't match the standard ggml pattern (custom user downloads).
    private static func modelCost(filename: String, sizeBytes: Int64) -> Double {
        if let d = ModelDescriptor.parse(filename: filename) { return d.cost }
        if sizeBytes > 0 {
            // Rough calibration: base.en (Q8_0) is ~82 MB and has cost
            // ~1.6 (base.weight 2.5 * q8.weight 0.65). So cost per byte
            // is about 1.6 / 82_000_000.
            return Double(sizeBytes) / 51_000_000.0
        }
        return 10.0  // unknown, assume heavy
    }
}

// MARK: - Catalog

struct CatalogModel {
    let displayName: String
    let filename: String
    let sizeBytes: Int64
    let url: URL?
    let isBundled: Bool
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
            isCustom: false
        ),
        CatalogModel(
            displayName: "base.en (Q8_0)",
            filename: "ggml-base.en-q8_0.bin",
            sizeBytes: 81_768_586,
            url: URL(string: "https://github.com/P-DoxQuad/push-to-dictate/releases/download/openai-models-v1/ggml-base.en-q8_0.bin")!,
            isBundled: true,
            isCustom: false
        ),
        CatalogModel(
            displayName: "small.en (Q8_0)",
            filename: "ggml-small.en-q8_0.bin",
            sizeBytes: 264_477_561,
            url: URL(string: "https://github.com/P-DoxQuad/push-to-dictate/releases/download/openai-models-v1/ggml-small.en-q8_0.bin")!,
            isBundled: false,
            isCustom: false
        )
    ]

    /// First-launch pick: the single best model (per `bestPickFilename`)
    /// among present-on-disk models (bundled or downloaded). Falls back
    /// to the first bundled entry if nothing qualifies.
    static func bestRecommendedPresent() -> CatalogModel {
        let present = entries.filter { entry -> Bool in
            if entry.isBundled { return true }
            if case .downloaded = ModelLocator.status(for: entry.filename) { return true }
            return false
        }
        let presentFilenames = present.map { $0.filename }
        if let best = ModelRecommendation.bestPickFilename(among: presentFilenames),
           let entry = present.first(where: { $0.filename == best }) {
            return entry
        }
        return entries.first(where: { $0.isBundled }) ?? entries[0]
    }

    /// Color for the model popup label. Returns `nil` for filenames not
    /// in the catalog and unparseable as a whisper.cpp model.
    static func color(forFilename filename: String) -> NSColor? {
        if entries.first(where: { $0.filename == filename }) != nil
            || ModelDescriptor.parse(filename: filename) != nil {
            return ModelRecommendation.rate(filename: filename).color
        }
        return nil
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
