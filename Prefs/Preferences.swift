import Foundation
import CoreGraphics

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
    }

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

    private init() {}
}
