import Foundation
import ApplicationServices

enum CursorContext {
    // Returns true when the focused UI element's cursor sits at the start
    // of a line: text position 0, or immediately after a newline-class
    // character. Returns nil when the query failed for any reason: the
    // app doesn't expose text through AX, the focused element isn't a
    // text container, no selection range is available, the value isn't
    // a string, etc. Callers should treat nil as "unknown" and fall back
    // to their default behavior. Requires Accessibility permission, which
    // is already granted for the hotkey event tap.
    static func isCursorAtLineStart() -> Bool? {
        let systemWide = AXUIElementCreateSystemWide()

        var focusedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            systemWide, kAXFocusedUIElementAttribute as CFString, &focusedRef
        ) == .success else { return nil }
        guard let focusedCF = focusedRef,
              CFGetTypeID(focusedCF) == AXUIElementGetTypeID() else {
            return nil
        }
        let focused = focusedCF as! AXUIElement

        var rangeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            focused, kAXSelectedTextRangeAttribute as CFString, &rangeRef
        ) == .success else { return nil }
        guard let rangeCF = rangeRef,
              CFGetTypeID(rangeCF) == AXValueGetTypeID() else {
            return nil
        }
        let rangeAX = rangeCF as! AXValue

        var range = CFRange(location: 0, length: 0)
        guard AXValueGetValue(rangeAX, .cfRange, &range) else { return nil }

        if range.location == 0 { return true }

        var valueRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            focused, kAXValueAttribute as CFString, &valueRef
        ) == .success else { return nil }
        guard let text = valueRef as? String else { return nil }

        let utf16 = text.utf16
        let location = range.location
        guard location > 0, location <= utf16.count else { return nil }

        let prevIndex = utf16.index(utf16.startIndex, offsetBy: location - 1)
        let unit = utf16[prevIndex]
        // \n, \r, Unicode LINE SEPARATOR (U+2028), PARAGRAPH SEPARATOR (U+2029).
        if unit == 0x0A || unit == 0x0D || unit == 0x2028 || unit == 0x2029 {
            return true
        }
        return false
    }
}
