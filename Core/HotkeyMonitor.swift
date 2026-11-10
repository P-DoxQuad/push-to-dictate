import Cocoa
import CoreGraphics

final class HotkeyMonitor {
    enum Mode { case toggle, pushToTalk }

    var mode: Mode = .toggle
    var onActivate: (() -> Void)?
    var onDeactivate: (() -> Void)?

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var isActive = false

    func start() {}
    func stop() {}

    static func hasAccessibilityPermission() -> Bool {
        return AXIsProcessTrusted()
    }
}
