import Foundation
import CoreGraphics
import Security

final class Preferences {
    enum Backend: String { case whisperCpp, openAI }
    enum HotkeyMode: String { case toggle, pushToTalk }
    enum InjectionMethod: String { case paste, typed }

    static let shared = Preferences()

    private let defaults = UserDefaults.standard

    private enum Key {
        static let backend = "backend"
        static let hotkeyMode = "hotkeyMode"
        static let injectionMethod = "injectionMethod"
        static let localModelFilename = "localModelFilename"
        static let hotkeyKeyCode = "hotkeyKeyCode"
        static let hotkeyModifierFlags = "hotkeyModifierFlags"
        static let whisperCliPath = "whisperCliPath"
        static let openAIAPIKeyLegacy = "openAIAPIKey"
        static let openAILanguage = "openAILanguage"
        static let inputDeviceUID = "inputDeviceUID"
        static let startSound = "startSound"
        static let stopSound = "stopSound"
        static let modelsDirectory = "modelsDirectory"
        static let logEverything = "logEverything"
        static let useColoredMenuBarIcon = "useColoredMenuBarIcon"
        static let suppressedMoveToApplicationsPrompt = "suppressedMoveToApplicationsPrompt"
        static let transcriptionThreads = "transcriptionThreads"
        static let beamSize = "beamSize"
        static let saveDebugRecordings = "saveDebugRecordings"
        static let didAutoSelectModel = "didAutoSelectModel"
        static let didShowWelcomeTooltip = "didShowWelcomeTooltip"
        static let silenceAutoStopEnabled = "silenceAutoStopEnabled"
        static let silenceAutoStopThreshold = "silenceAutoStopThreshold"
        static let silenceAutoStopSeconds = "silenceAutoStopSeconds"
        static let typedKeystrokeDelayMs = "typedKeystrokeDelayMs"
        static let skippedUpdateVersion = "skippedUpdateVersion"
        static let continuousDictationEnabled = "continuousDictationEnabled"
        static let continuousDictationPauseSeconds = "continuousDictationPauseSeconds"
        static let continuousDictationMaxChunkSeconds = "continuousDictationMaxChunkSeconds"
        static let continuousDictationChunkOverlapSeconds = "continuousDictationChunkOverlapSeconds"
        static let continuousDictationPromptChainEnabled = "continuousDictationPromptChainEnabled"
        static let continuousDictationPromptChainMaxChars = "continuousDictationPromptChainMaxChars"
        static let continuousDictationStripWhisperPunctuation = "continuousDictationStripWhisperPunctuation"
        static let continuousDictationAutoEndPeriod = "continuousDictationAutoEndPeriod"
        static let continuousDictationSentencePauseSeconds = "continuousDictationSentencePauseSeconds"
        static let continuousDictationSentencePauseMaxSeconds = "continuousDictationSentencePauseMaxSeconds"
        static let continuousDictationTrailingPeriodSeconds = "continuousDictationTrailingPeriodSeconds"
        static let transcriptProcessingEnabled = "transcriptProcessingEnabled"
        static let removeNonSpeechAnnotations = "removeNonSpeechAnnotations"
        static let normalizeCapitalization = "normalizeCapitalization"
        static let applyProperNounFixups = "applyProperNounFixups"
        static let applyTextSubstitutions = "applyTextSubstitutions"
        static let capitalizeFirstLetterAtLineStart = "capitalizeFirstLetterAtLineStart"
        static let filterConsecutiveDuplicates = "filterConsecutiveDuplicates"
    }

    static let noSoundName = "None"

    private static let keychainService = "push-to-dictate"
    private static let keychainAPIKeyAccount = "openai-api-key"

    private static let defaultHotkeyKeyCode: Int = 49
    private static let defaultHotkeyModifierFlags: UInt64 =
        CGEventFlags([.maskControl, .maskAlternate]).rawValue

    var backend: Backend {
        get { return Backend(rawValue: defaults.string(forKey: Key.backend) ?? "") ?? .whisperCpp }
        set { defaults.set(newValue.rawValue, forKey: Key.backend) }
    }

    var hotkeyMode: HotkeyMode {
        get { return HotkeyMode(rawValue: defaults.string(forKey: Key.hotkeyMode) ?? "") ?? .toggle }
        set { defaults.set(newValue.rawValue, forKey: Key.hotkeyMode) }
    }

    var injectionMethod: InjectionMethod {
        get { return InjectionMethod(rawValue: defaults.string(forKey: Key.injectionMethod) ?? "") ?? .typed }
        set { defaults.set(newValue.rawValue, forKey: Key.injectionMethod) }
    }

    var localModelFilename: String {
        get { return defaults.string(forKey: Key.localModelFilename) ?? "ggml-base.en-q8_0.bin" }
        set { defaults.set(newValue, forKey: Key.localModelFilename) }
    }

    var hotkeyKeyCode: Int {
        get {
            let stored = defaults.integer(forKey: Key.hotkeyKeyCode)
            return stored == 0 ? Preferences.defaultHotkeyKeyCode : stored
        }
        set { defaults.set(newValue, forKey: Key.hotkeyKeyCode) }
    }

    var hotkeyModifierFlags: CGEventFlags {
        get {
            let raw = (defaults.object(forKey: Key.hotkeyModifierFlags) as? NSNumber)?.uint64Value
                ?? Preferences.defaultHotkeyModifierFlags
            return CGEventFlags(rawValue: raw)
        }
        set { defaults.set(NSNumber(value: newValue.rawValue), forKey: Key.hotkeyModifierFlags) }
    }

    var whisperCliPath: String {
        get {
            if let stored = defaults.string(forKey: Key.whisperCliPath), !stored.isEmpty {
                return stored
            }
            if let bundled = Bundle.main.url(forResource: "whisper-cli", withExtension: nil) {
                return bundled.path
            }
            return (Bundle.main.resourcePath ?? "") + "/whisper-cli"
        }
        set { defaults.set(newValue, forKey: Key.whisperCliPath) }
    }

    // Empty string means "use the app bundle". Otherwise a user-chosen directory.
    var modelsDirectory: String {
        get { return defaults.string(forKey: Key.modelsDirectory) ?? "" }
        set { defaults.set(newValue, forKey: Key.modelsDirectory) }
    }

    var logEverything: Bool {
        get { return defaults.bool(forKey: Key.logEverything) }
        set { defaults.set(newValue, forKey: Key.logEverything) }
    }

    var useColoredMenuBarIcon: Bool {
        get {
            if defaults.object(forKey: Key.useColoredMenuBarIcon) == nil { return true }
            return defaults.bool(forKey: Key.useColoredMenuBarIcon)
        }
        set { defaults.set(newValue, forKey: Key.useColoredMenuBarIcon) }
    }

    var suppressedMoveToApplicationsPrompt: Bool {
        get { return defaults.bool(forKey: Key.suppressedMoveToApplicationsPrompt) }
        set { defaults.set(newValue, forKey: Key.suppressedMoveToApplicationsPrompt) }
    }

    static var defaultTranscriptionThreads: Int {
        // Scales with the host's logical core count. ≤12 logical cores: half.
        // >12 logical cores: a third. Matches the "Recommended" range the
        // PreferencesWindowController shows in its threads-hint label and
        // avoids the NUMA / HT tax from over-subscribing on large machines
        // (dual-socket Mac Pros, high-core Apple-silicon systems under
        // Rosetta, etc). Floor of 1 so single-core systems still get a
        // sensible value.
        let logical = ProcessInfo.processInfo.activeProcessorCount
        let scaled = logical <= 12 ? logical / 2 : logical / 3
        return max(1, scaled)
    }

    var transcriptionThreads: Int {
        get {
            let stored = defaults.integer(forKey: Key.transcriptionThreads)
            return stored == 0 ? Preferences.defaultTranscriptionThreads : stored
        }
        set { defaults.set(newValue, forKey: Key.transcriptionThreads) }
    }

    var beamSize: Int {
        get {
            let stored = defaults.integer(forKey: Key.beamSize)
            return stored == 0 ? 3 : stored
        }
        set { defaults.set(newValue, forKey: Key.beamSize) }
    }

    var saveDebugRecordings: Bool {
        get { return defaults.bool(forKey: Key.saveDebugRecordings) }
        set { defaults.set(newValue, forKey: Key.saveDebugRecordings) }
    }

    var didAutoSelectModel: Bool {
        get { return defaults.bool(forKey: Key.didAutoSelectModel) }
        set { defaults.set(newValue, forKey: Key.didAutoSelectModel) }
    }

    var didShowWelcomeTooltip: Bool {
        get { return defaults.bool(forKey: Key.didShowWelcomeTooltip) }
        set { defaults.set(newValue, forKey: Key.didShowWelcomeTooltip) }
    }

    var silenceAutoStopEnabled: Bool {
        get { return defaults.bool(forKey: Key.silenceAutoStopEnabled) }
        set {
            defaults.set(newValue, forKey: Key.silenceAutoStopEnabled)
            if newValue && continuousDictationEnabled {
                defaults.set(false, forKey: Key.continuousDictationEnabled)
            }
        }
    }

    var continuousDictationEnabled: Bool {
        get { return defaults.bool(forKey: Key.continuousDictationEnabled) }
        set {
            defaults.set(newValue, forKey: Key.continuousDictationEnabled)
            if newValue && silenceAutoStopEnabled {
                defaults.set(false, forKey: Key.silenceAutoStopEnabled)
            }
        }
    }

    var continuousDictationPauseSeconds: Double {
        get {
            let stored = defaults.double(forKey: Key.continuousDictationPauseSeconds)
            return stored == 0 ? 0.5 : stored
        }
        set { defaults.set(newValue, forKey: Key.continuousDictationPauseSeconds) }
    }

    var continuousDictationMaxChunkSeconds: Double {
        get {
            let stored = defaults.double(forKey: Key.continuousDictationMaxChunkSeconds)
            return stored == 0 ? 30.0 : stored
        }
        set { defaults.set(newValue, forKey: Key.continuousDictationMaxChunkSeconds) }
    }

    var continuousDictationChunkOverlapSeconds: Double {
        get { return defaults.double(forKey: Key.continuousDictationChunkOverlapSeconds) }
        set { defaults.set(newValue, forKey: Key.continuousDictationChunkOverlapSeconds) }
    }

    var continuousDictationPromptChainEnabled: Bool {
        get {
            if defaults.object(forKey: Key.continuousDictationPromptChainEnabled) == nil {
                return true
            }
            return defaults.bool(forKey: Key.continuousDictationPromptChainEnabled)
        }
        set { defaults.set(newValue, forKey: Key.continuousDictationPromptChainEnabled) }
    }

    var continuousDictationPromptChainMaxChars: Int {
        get {
            let stored = defaults.integer(forKey: Key.continuousDictationPromptChainMaxChars)
            return stored == 0 ? 200 : stored
        }
        set { defaults.set(newValue, forKey: Key.continuousDictationPromptChainMaxChars) }
    }

    var continuousDictationStripWhisperPunctuation: Bool {
        get { return defaults.bool(forKey: Key.continuousDictationStripWhisperPunctuation) }
        set { defaults.set(newValue, forKey: Key.continuousDictationStripWhisperPunctuation) }
    }

    // Strip-punctuation mode only. Governs the trailing-period timer
    // that fires after prolonged silence (at 4 * sentencePauseSeconds)
    // and appends a closing `.`. OFF leaves the final sentence unclosed.
    // Mid-dictation sentence breaks (the `". "` + capital prefix inside
    // the gap window) are driven by the gap-based rule in both modes.
    var continuousDictationAutoEndPeriod: Bool {
        get {
            if defaults.object(forKey: Key.continuousDictationAutoEndPeriod) == nil {
                return true
            }
            return defaults.bool(forKey: Key.continuousDictationAutoEndPeriod)
        }
        set { defaults.set(newValue, forKey: Key.continuousDictationAutoEndPeriod) }
    }

    // Strip-punctuation mode. The master timing knob (`P`). New-sentence
    // window opens when a chunk's preceding gap is >= this value.
    // Editing this in the UI cascades the max / trailing fields
    // proportionally so the user-set ratio between them is preserved.
    var continuousDictationSentencePauseSeconds: Double {
        get {
            let stored = defaults.double(forKey: Key.continuousDictationSentencePauseSeconds)
            return stored == 0 ? 1.0 : stored
        }
        set { defaults.set(newValue, forKey: Key.continuousDictationSentencePauseSeconds) }
    }

    // Strip-punctuation mode. The new-sentence window closes at this
    // value; gaps longer than this fall into the "dead zone" where a
    // resuming chunk gets `" "` continuation instead of `". "` + capital.
    // Default 2.0 (2x the sentence-pause default). Independently editable.
    var continuousDictationSentencePauseMaxSeconds: Double {
        get {
            let stored = defaults.double(forKey: Key.continuousDictationSentencePauseMaxSeconds)
            return stored == 0 ? 2.0 : stored
        }
        set { defaults.set(newValue, forKey: Key.continuousDictationSentencePauseMaxSeconds) }
    }

    // Strip-punctuation mode. When auto-end-period is on, this many
    // seconds of silence from speech-end triggers injection of a closing
    // `.`. Default 4.0 (4x the sentence-pause default). Independently
    // editable.
    var continuousDictationTrailingPeriodSeconds: Double {
        get {
            let stored = defaults.double(forKey: Key.continuousDictationTrailingPeriodSeconds)
            return stored == 0 ? 4.0 : stored
        }
        set { defaults.set(newValue, forKey: Key.continuousDictationTrailingPeriodSeconds) }
    }

    // Root toggle for the post-processing pipeline. When off, whisper's
    // raw transcript is injected as-is. When on, each of the five nested
    // preferences below individually governs whether its pass runs.
    var transcriptProcessingEnabled: Bool {
        get {
            if defaults.object(forKey: Key.transcriptProcessingEnabled) == nil { return true }
            return defaults.bool(forKey: Key.transcriptProcessingEnabled)
        }
        set { defaults.set(newValue, forKey: Key.transcriptProcessingEnabled) }
    }

    var removeNonSpeechAnnotations: Bool {
        get {
            if defaults.object(forKey: Key.removeNonSpeechAnnotations) == nil { return true }
            return defaults.bool(forKey: Key.removeNonSpeechAnnotations)
        }
        set { defaults.set(newValue, forKey: Key.removeNonSpeechAnnotations) }
    }

    var normalizeCapitalization: Bool {
        get {
            if defaults.object(forKey: Key.normalizeCapitalization) == nil { return true }
            return defaults.bool(forKey: Key.normalizeCapitalization)
        }
        set { defaults.set(newValue, forKey: Key.normalizeCapitalization) }
    }

    var applyProperNounFixups: Bool {
        get {
            if defaults.object(forKey: Key.applyProperNounFixups) == nil { return true }
            return defaults.bool(forKey: Key.applyProperNounFixups)
        }
        set { defaults.set(newValue, forKey: Key.applyProperNounFixups) }
    }

    var applyTextSubstitutions: Bool {
        get {
            if defaults.object(forKey: Key.applyTextSubstitutions) == nil { return true }
            return defaults.bool(forKey: Key.applyTextSubstitutions)
        }
        set { defaults.set(newValue, forKey: Key.applyTextSubstitutions) }
    }

    var capitalizeFirstLetterAtLineStart: Bool {
        get {
            if defaults.object(forKey: Key.capitalizeFirstLetterAtLineStart) == nil { return true }
            return defaults.bool(forKey: Key.capitalizeFirstLetterAtLineStart)
        }
        set { defaults.set(newValue, forKey: Key.capitalizeFirstLetterAtLineStart) }
    }

    var filterConsecutiveDuplicates: Bool {
        get {
            if defaults.object(forKey: Key.filterConsecutiveDuplicates) == nil { return true }
            return defaults.bool(forKey: Key.filterConsecutiveDuplicates)
        }
        set { defaults.set(newValue, forKey: Key.filterConsecutiveDuplicates) }
    }

    // Words / tokens that the post-processing casing normalizer would
    // fold to lowercase but that should retain a canonical capitalized
    // form (months, weekdays, tech acronyms, brand names). Applied as
    // a case-insensitive word-boundary substitution after lowercasing.
    // Currently returns a hardcoded English-oriented list. To make this
    // user-editable: back with a UserDefaults key, split a newline-
    // joined string into entries, fall back to the default list when
    // the stored value is empty. Call sites do not need to change.
    var capitalizationFixups: [String] {
        return Preferences.defaultCapitalizationFixups
    }

    static let defaultCapitalizationFixups: [String] = [
        "January", "February", "March", "April", "May", "June",
        "July", "August", "September", "October", "November", "December",
        "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday",
        "API", "JSON", "XML", "YAML", "HTML", "CSS", "SQL", "HTTP", "HTTPS",
        "URL", "URI", "SSH", "FTP", "TCP", "UDP", "DNS", "CPU", "GPU", "RAM",
        "USB", "PDF", "PNG", "JPEG", "GIF", "SVG", "SSD", "HDD",
        "GitHub", "GitLab", "macOS", "iOS", "iPadOS", "watchOS", "tvOS",
        "iCloud", "iPhone", "iPad", "iMac", "MacBook", "Macbook Pro", "Mac Pro",
        "Monterey", "Ventura", "Sonoma", "Sequoia", "Catalina", "Mojave",
        "Big Sur", "High Sierra", "El Capitan",
        "YouTube", "Google", "Apple", "Microsoft", "Linux",
        "Chrome", "Firefox", "Safari",
        "Python", "JavaScript", "TypeScript", "Swift", "Node.js", "npm",
        "USA", "UK", "EU", "UAE",
        "NASA", "FBI", "CIA", "NATO", "OPEC", "UNESCO", "UNICEF", "NGO", "GDP",
        "PSW", "DF", "CPA", "SCIO", "ODSP", "OSAP",
        "Wi-Fi", "Bluetooth", "Ethernet",
        "NLP", "LLM", "GPT", "TPU", "CUDA",
        "OpenGL", "OpenCL", "Vulkan",
        "Ubuntu", "Debian", "ChromeOS",
        "AirPods", "HomePod", "AirTag",
        "Kotlin", "Haskell", "Lua",
        "Django", "Kubernetes", "TensorFlow", "PyTorch",
        "MySQL", "PostgreSQL", "MongoDB", "Redis", "SQLite",
        "McDonald's", "Burger King", "Tim Hortons", "Wendy's", "Harvey's",
        "Starbucks", "Chipotle", "Taco Bell", "KFC", "Domino's",
        "Pizza Hut", "Papa John's", "Little Caesars", "Dairy Queen",
        "Arby's", "Popeyes", "Red Lobster", "Boston Pizza", "Swiss Chalet",
        "Pizza Pizza", "Jimmy John's", "Panda Express", "Hardee's",
        "Whataburger", "Culver's", "Panera", "Shake Shack",
        "Canada", "Ottawa",
        "Alberta", "British Columbia", "Manitoba", "New Brunswick",
        "Newfoundland and Labrador", "Nova Scotia", "Ontario",
        "Prince Edward Island", "Quebec", "Saskatchewan",
        "Edmonton", "Victoria", "Winnipeg", "Fredericton",
        "St. John's", "Halifax", "Charlottetown", "Quebec City", "Regina",
        "Toronto", "Vancouver", "Calgary",
        "America", "United States", "D.C.", "D.C", "DC",
        "Alabama", "Alaska", "Arizona", "Arkansas", "California", "Los Angeles",
        "San Diego", "Colorado", "Connecticut", "Delaware", "Florida", "Georgia",
        "Hawaii", "Idaho", "Illinois", "Indiana", "Iowa",
        "Kansas", "Kentucky", "Louisiana", "Maine", "Maryland",
        "Massachusetts", "Michigan", "Minnesota", "Mississippi", "Missouri",
        "Montana", "Nebraska", "Nevada", "New Hampshire", "New Jersey",
        "New Mexico", "New York", "North Carolina", "North Dakota", "Ohio",
        "Oklahoma", "Oregon", "Portland", "Pennsylvania", "Rhode Island", "South Carolina",
        "South Dakota", "Tennessee", "Texas", "Utah", "Vermont",
        "Virginia", "Washington", "West Virginia", "Wisconsin", "Wyoming",
        "Montgomery", "Juneau", "Phoenix", "Little Rock", "Sacramento",
        "Denver", "Hartford", "Dover", "Tallahassee", "Atlanta",
        "Honolulu", "Boise", "Springfield", "Indianapolis", "Des Moines",
        "Topeka", "Frankfort", "Baton Rouge", "Augusta", "Annapolis",
        "Boston", "Lansing", "Saint Paul", "St. Paul", "Jackson",
        "Jefferson City", "Helena", "Lincoln", "Carson City", "Concord",
        "Trenton", "Santa Fe", "Albany", "Raleigh", "Bismarck",
        "Columbus", "Oklahoma City", "Salem", "Harrisburg", "Providence",
        "Columbia", "Pierre", "Nashville", "Austin", "Salt Lake City",
        "Montpelier", "Richmond", "Olympia", "Charleston", "Madison",
        "Cheyenne",
        "Michael", "Andy", "Vasko", "Anujan", "Dylan", "Dave", "David",
        "Raymond", "Johnson", "Jonathan", "Nick", "Brandon",
        "Derek", "Emily", "Sarah", "Bill", "Curtis", "Curtiss",
        "Billy", "Holly", "Laura", "Andrew", "Tyson", "Jenny",
        "Jennifer", "Maria", "Jane", "Marie", "Sean", "Shawn",
        "Ron", "Ronald", "Esther", "Leo", "Leonardo", "Leon",
        "Nadia", "Larry", "Michelle", "Matt", "Matthew"
    ]

    // Post-process substitutions where the matched form differs from the
    // produced form. Covers unit abbreviations (spoken "megabytes" ->
    // "MB") and multi-word tokenizations that the single-word
    // capitalization fixup can't catch (whisper's "mac os" -> "macOS").
    // Patterns are matched case-insensitively with word boundaries.
    // Order matters: earlier entries run first, so more specific
    // patterns should precede substrings of themselves. Currently
    // returns a hardcoded list; same migration path as the
    // capitalization fixups when it moves to a user-loaded file.
    var textSubstitutions: [(String, String)] {
        return Preferences.defaultTextSubstitutions
    }

    static let defaultTextSubstitutions: [(String, String)] = [
        ("andi", "Andy"),
        ("vasco", "Vasko"),
        ("A new June", "Anujan"),
        ("anujin", "Anujan"),
        ("a newgen", "Anujan"),
        ("a new gen", "Anujan"),
        ("a new gin", "Anujan"),
        ("a.m.", "am"),
        ("p.m.", "pm"),
        ("a.m", "am"),
        ("p.m", "pm"),
        ("A.m", "am"),
        ("P.m", "pm"),
        ("mac os", "macOS"),
        ("kilobits per second", "Kbps"),
        ("megabits per second", "Mbps"),
        ("gigabits per second", "Gbps"),
        ("kilobytes", "KB"), ("kilobyte", "KB"),
        ("megabytes", "MB"), ("megabyte", "MB"),
        ("gigabytes", "GB"), ("gigabyte", "GB"),
        ("terabytes", "TB"), ("terabyte", "TB"),
        ("petabytes", "PB"), ("petabyte", "PB"),
        ("a and w", "A&W"),
        ("chick fil a", "Chick-fil-A"),
        ("chick fill a", "Chick-fil-A"),
        ("chickfila", "Chick-fil-A"),
        ("chick filet", "Chick-fil-A"),
        ("chick fillet", "Chick-fil-A"),
        // Strip mode removes the period in "St. John's" / "St. Paul"
        // before fixups can match. Restore the canonical form via
        // substitution on the stripped text.
        ("st john's", "St. John's"),
        ("st paul", "St. Paul")
    ]

    var silenceAutoStopThreshold: Double {
        get {
            let stored = defaults.double(forKey: Key.silenceAutoStopThreshold)
            return stored == 0 ? 0.01 : stored
        }
        set { defaults.set(newValue, forKey: Key.silenceAutoStopThreshold) }
    }

    var silenceAutoStopSeconds: Double {
        get {
            let stored = defaults.double(forKey: Key.silenceAutoStopSeconds)
            return stored == 0 ? 2.0 : stored
        }
        set { defaults.set(newValue, forKey: Key.silenceAutoStopSeconds) }
    }

    var typedKeystrokeDelayMs: Int {
        get {
            let stored = defaults.integer(forKey: Key.typedKeystrokeDelayMs)
            return stored == 0 ? 8 : stored
        }
        set { defaults.set(newValue, forKey: Key.typedKeystrokeDelayMs) }
    }

    var skippedUpdateVersion: String {
        get { return defaults.string(forKey: Key.skippedUpdateVersion) ?? "" }
        set { defaults.set(newValue, forKey: Key.skippedUpdateVersion) }
    }

    static var debugRecordingsDirectory: URL {
        return defaultSupportDirectory.appendingPathComponent("debug", isDirectory: true)
    }

    var whisperModelPath: String {
        let filename = localModelFilename
        let stem = (filename as NSString).deletingPathExtension
        let ext = (filename as NSString).pathExtension
        if let bundled = Bundle.main.url(forResource: stem,
                                         withExtension: ext.isEmpty ? nil : ext) {
            return bundled.path
        }
        let writable = Preferences.writableModelsDirectory
            .appendingPathComponent(filename).path
        if FileManager.default.fileExists(atPath: writable) {
            return writable
        }
        return (Bundle.main.resourcePath ?? "") + "/\(filename)"
    }

    static var userModelsDirectory: URL {
        return defaultSupportDirectory.appendingPathComponent("models", isDirectory: true)
    }

    /// Where downloaded (non-bundled) models live. The user's `modelsDirectory`
    /// override if set, otherwise the default app-support models folder.
    static var writableModelsDirectory: URL {
        let override = Preferences.shared.modelsDirectory
        if !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return userModelsDirectory
    }

    var openAIAPIKey: String {
        get {
            if let fromKeychain = Preferences.keychainRead(
                    service: Preferences.keychainService,
                    account: Preferences.keychainAPIKeyAccount) {
                return fromKeychain
            }
            // One-shot migration from the Phase 4 UserDefaults storage.
            if let legacy = defaults.string(forKey: Key.openAIAPIKeyLegacy),
               !legacy.isEmpty {
                Preferences.keychainWrite(legacy,
                                          service: Preferences.keychainService,
                                          account: Preferences.keychainAPIKeyAccount)
                defaults.removeObject(forKey: Key.openAIAPIKeyLegacy)
                return legacy
            }
            return ""
        }
        set {
            if newValue.isEmpty {
                Preferences.keychainDelete(service: Preferences.keychainService,
                                           account: Preferences.keychainAPIKeyAccount)
            } else {
                Preferences.keychainWrite(newValue,
                                          service: Preferences.keychainService,
                                          account: Preferences.keychainAPIKeyAccount)
            }
            defaults.removeObject(forKey: Key.openAIAPIKeyLegacy)
        }
    }

    var openAILanguage: String {
        get { return defaults.string(forKey: Key.openAILanguage) ?? "en" }
        set { defaults.set(newValue, forKey: Key.openAILanguage) }
    }

    var inputDeviceUID: String {
        get { return defaults.string(forKey: Key.inputDeviceUID) ?? "" }
        set { defaults.set(newValue, forKey: Key.inputDeviceUID) }
    }

    var startSound: String {
        get { return defaults.string(forKey: Key.startSound) ?? "Tink" }
        set { defaults.set(newValue, forKey: Key.startSound) }
    }

    var stopSound: String {
        get { return defaults.string(forKey: Key.stopSound) ?? "Pop" }
        set { defaults.set(newValue, forKey: Key.stopSound) }
    }

    static var defaultSupportDirectory: URL {
        let fm = FileManager.default
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("push-to-dictate", isDirectory: true)
    }

    // Keys that are internal state, not user preferences. Reset-to-defaults
    // deliberately preserves these so first-launch flows aren't re-triggered
    // and a skipped update version stays skipped. Backup export/import still
    // includes them so a user's full state round-trips correctly.
    static let internalFlagKeys: Set<String> = [
        Key.suppressedMoveToApplicationsPrompt,
        Key.didAutoSelectModel,
        Key.didShowWelcomeTooltip,
        Key.skippedUpdateVersion
    ]

    // Clears all user-facing preferences back to code defaults. Leaves
    // internalFlagKeys alone and leaves the Keychain-stored OpenAI API key
    // alone. UI must refresh after calling this.
    func resetUserPreferences() {
        for key in Preferences.allUserDefaultsKeys {
            if Preferences.internalFlagKeys.contains(key) { continue }
            defaults.removeObject(forKey: key)
        }
    }

    // All UserDefaults keys we read/write. Used by the backup export/import.
    // Deliberately omits openAIAPIKeyLegacy (only used for one-shot Keychain migration).
    static let allUserDefaultsKeys: [String] = [
        Key.backend, Key.hotkeyMode, Key.injectionMethod,
        Key.localModelFilename, Key.hotkeyKeyCode, Key.hotkeyModifierFlags,
        Key.whisperCliPath, Key.openAILanguage, Key.inputDeviceUID,
        Key.startSound, Key.stopSound, Key.modelsDirectory,
        Key.logEverything, Key.useColoredMenuBarIcon,
        Key.suppressedMoveToApplicationsPrompt,
        Key.transcriptionThreads, Key.beamSize,
        Key.saveDebugRecordings, Key.didAutoSelectModel,
        Key.didShowWelcomeTooltip,
        Key.silenceAutoStopEnabled, Key.silenceAutoStopThreshold,
        Key.silenceAutoStopSeconds, Key.typedKeystrokeDelayMs,
        Key.skippedUpdateVersion,
        Key.continuousDictationEnabled, Key.continuousDictationPauseSeconds,
        Key.continuousDictationMaxChunkSeconds,
        Key.continuousDictationChunkOverlapSeconds,
        Key.continuousDictationPromptChainEnabled,
        Key.continuousDictationPromptChainMaxChars,
        Key.continuousDictationStripWhisperPunctuation,
        Key.continuousDictationAutoEndPeriod,
        Key.continuousDictationSentencePauseSeconds,
        Key.continuousDictationSentencePauseMaxSeconds,
        Key.continuousDictationTrailingPeriodSeconds,
        Key.transcriptProcessingEnabled,
        Key.removeNonSpeechAnnotations,
        Key.normalizeCapitalization,
        Key.applyProperNounFixups,
        Key.applyTextSubstitutions,
        Key.capitalizeFirstLetterAtLineStart,
        Key.filterConsecutiveDuplicates
    ]

    // MARK: - Keychain

    private static func keychainRead(service: String, account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func keychainWrite(_ value: String, service: String, account: String) {
        let data = value.data(using: .utf8) ?? Data()
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let update: [String: Any] = [kSecValueData as String: data]
        let status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var addQuery = query
            addQuery[kSecValueData as String] = data
            SecItemAdd(addQuery as CFDictionary, nil)
        }
    }

    private static func keychainDelete(service: String, account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
    }

    private init() {}
}
