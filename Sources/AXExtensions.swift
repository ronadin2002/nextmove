import Cocoa
import ApplicationServices

/// System-wide helpers for reading the focused UI element (text under the caret)
enum AXFocused {
    /// Returns the string currently in the focused text control, or nil if not applicable
    static func string() -> String? {
        let systemWide = AXUIElementCreateSystemWide()
        var focusedObj: AnyObject?
        guard AXUIElementCopyAttributeValue(systemWide,
                                            kAXFocusedUIElementAttribute as CFString,
                                            &focusedObj) == .success,
              let focusedAny = focusedObj,
              CFGetTypeID(focusedAny) == AXUIElementGetTypeID() else { return nil }

        let focused = unsafeBitCast(focusedAny, to: AXUIElement.self)

        // Try standard value attribute first
        var valueObj: AnyObject?
        if AXUIElementCopyAttributeValue(focused,
                                         kAXValueAttribute as CFString,
                                         &valueObj) == .success,
           let str = valueObj as? String, !str.isEmpty {
            return str
        }

        // Rich editors (web areas etc.) – use selected text
        if AXUIElementCopyAttributeValue(focused,
                                         kAXSelectedTextAttribute as CFString,
                                         &valueObj) == .success,
           let sel = valueObj as? String, !sel.isEmpty {
            return sel
        }
        return nil
    }
} 