import Cocoa
import CoreGraphics

final class HotkeyMonitor {
    enum Mode { case toggle, pushToTalk }

    var mode: Mode = .toggle
    var keyCode: Int = 49
    var modifierFlags: CGEventFlags = [.maskControl, .maskAlternate]

    var onActivate: (() -> Void)?
    var onDeactivate: (() -> Void)?

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    private static let modifierMask: CGEventFlags =
        [.maskControl, .maskAlternate, .maskShift, .maskCommand]

    func start() {
        guard eventTap == nil else { return }

        let mask: CGEventMask =
            (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue)
        let selfPointer = Unmanaged.passUnretained(self).toOpaque()

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: HotkeyMonitor.tapCallback,
            userInfo: selfPointer
        ) else { return }

        let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        eventTap = tap
        runLoopSource = source
    }

    func stop() {
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
            runLoopSource = nil
        }
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            eventTap = nil
        }
    }

    static func hasAccessibilityPermission() -> Bool {
        return AXIsProcessTrusted()
    }

    private func handle(type: CGEventType, event: CGEvent) -> Bool {
        let flags = event.flags.intersection(HotkeyMonitor.modifierMask)
        let keycode = Int(event.getIntegerValueField(.keyboardEventKeycode))

        guard keycode == keyCode, flags == modifierFlags else { return false }

        if type == .keyDown {
            let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
            if isRepeat { return true }
            onActivate?()
            return true
        }

        if type == .keyUp {
            if mode == .pushToTalk {
                onDeactivate?()
            }
            return true
        }

        return false
    }

    private static let tapCallback: CGEventTapCallBack = { _, type, event, refcon in
        guard let refcon = refcon else { return Unmanaged.passUnretained(event) }
        let monitor = Unmanaged<HotkeyMonitor>.fromOpaque(refcon).takeUnretainedValue()

        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = monitor.eventTap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            return Unmanaged.passUnretained(event)
        }

        if monitor.handle(type: type, event: event) {
            return nil
        }
        return Unmanaged.passUnretained(event)
    }

    deinit { stop() }
}
