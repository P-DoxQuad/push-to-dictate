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
        get { return InjectionMethod(rawValue: defaults.string(forKey: Key.injectionMethod) ?? "") ?? .paste }
        set { defaults.set(newValue.rawValue, forKey: Key.injectionMethod) }
    }

    var localModelFilename: String {
        get { return defaults.string(forKey: Key.localModelFilename) ?? "ggml-small.en.bin" }
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
        get { return defaults.bool(forKey: Key.useColoredMenuBarIcon) }
        set { defaults.set(newValue, forKey: Key.useColoredMenuBarIcon) }
    }

    var suppressedMoveToApplicationsPrompt: Bool {
        get { return defaults.bool(forKey: Key.suppressedMoveToApplicationsPrompt) }
        set { defaults.set(newValue, forKey: Key.suppressedMoveToApplicationsPrompt) }
    }

    var whisperModelPath: String {
        let filename = localModelFilename
        if !modelsDirectory.isEmpty {
            return (modelsDirectory as NSString).appendingPathComponent(filename)
        }
        let stem = (filename as NSString).deletingPathExtension
        let ext = (filename as NSString).pathExtension
        if let bundled = Bundle.main.url(forResource: stem,
                                         withExtension: ext.isEmpty ? nil : ext) {
            return bundled.path
        }
        return (Bundle.main.resourcePath ?? "") + "/\(filename)"
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

    // All UserDefaults keys we read/write. Used by the backup export/import.
    // Deliberately omits openAIAPIKeyLegacy (only used for one-shot Keychain migration).
    static let allUserDefaultsKeys: [String] = [
        Key.backend, Key.hotkeyMode, Key.injectionMethod,
        Key.localModelFilename, Key.hotkeyKeyCode, Key.hotkeyModifierFlags,
        Key.whisperCliPath, Key.openAILanguage, Key.inputDeviceUID,
        Key.startSound, Key.stopSound, Key.modelsDirectory,
        Key.logEverything, Key.useColoredMenuBarIcon,
        Key.suppressedMoveToApplicationsPrompt
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
