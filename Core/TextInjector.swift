import Cocoa

final class TextInjector {
    private let workQueue = DispatchQueue(label: "push-to-dictate.injector", qos: .userInitiated)

    // Fixed heuristic for pasteboard restore. Too short and the paste completes
    // against our restored contents; too long and the user sees a visible gap.
    private static let pasteboardRestoreDelay: TimeInterval = 0.2

    // Pacing between synthesized keystrokes. Posting CGEvents at full Swift
    // loop speed overflows the HID event dispatch backlog on long strings,
    // causing silent event drops. Value is read from preferences in ms and
    // converted to microseconds for usleep.

    func insert(_ text: String) {
        guard !text.isEmpty else { return }
        let method = Preferences.shared.injectionMethod
        workQueue.async {
            switch method {
            case .paste: self.pasteInsert(text)
            case .typed: self.typedInsert(text)
            }
        }
    }

    private func pasteInsert(_ text: String) {
        let pasteboard = NSPasteboard.general
        let saved = snapshot(of: pasteboard)

        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        postCommandV()

        DispatchQueue.main.asyncAfter(deadline: .now() + TextInjector.pasteboardRestoreDelay) {
            self.restore(saved, to: pasteboard)
        }
    }

    private func typedInsert(_ text: String) {
        let source = CGEventSource(stateID: .combinedSessionState)
        let delayUs = UInt32(max(0, Preferences.shared.typedKeystrokeDelayMs)) * 1_000
        for scalar in text.unicodeScalars {
            let chars = Array(String(scalar).utf16)
            if let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true) {
                keyDown.keyboardSetUnicodeString(stringLength: chars.count, unicodeString: chars)
                keyDown.post(tap: .cghidEventTap)
            }
            if let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) {
                keyUp.keyboardSetUnicodeString(stringLength: chars.count, unicodeString: chars)
                keyUp.post(tap: .cghidEventTap)
            }
            if delayUs > 0 { usleep(delayUs) }
        }
    }

    private func postCommandV() {
        let source = CGEventSource(stateID: .combinedSessionState)
        let vKey: CGKeyCode = 9
        if let keyDown = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: true) {
            keyDown.flags = .maskCommand
            keyDown.post(tap: .cghidEventTap)
        }
        if let keyUp = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: false) {
            keyUp.flags = .maskCommand
            keyUp.post(tap: .cghidEventTap)
        }
    }

    private func snapshot(of pasteboard: NSPasteboard) -> [NSPasteboardItem] {
        guard let items = pasteboard.pasteboardItems else { return [] }
        return items.compactMap { item in
            let copy = NSPasteboardItem()
            for type in item.types {
                if let data = item.data(forType: type) {
                    copy.setData(data, forType: type)
                }
            }
            return copy
        }
    }

    private func restore(_ items: [NSPasteboardItem], to pasteboard: NSPasteboard) {
        guard !items.isEmpty else { return }
        pasteboard.clearContents()
        pasteboard.writeObjects(items)
    }
}
