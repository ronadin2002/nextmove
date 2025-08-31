import Foundation
import AppKit
import ApplicationServices

@available(macOS 12.3, *)
final class AccessibilityTextExtractor {
    struct FocusContext {
        let appName: String
        let beforeCursor: String
        let afterCursor: String
    }

    func focusedTextWithCursor() -> FocusContext? {
        guard let frontmostApp = NSWorkspace.shared.frontmostApplication else { return nil }
        let appName = frontmostApp.localizedName ?? frontmostApp.bundleIdentifier ?? "Unknown"
   
        let system = AXUIElementCreateSystemWide()
        guard let root = deepestFocusedElement(system: system) else { return nil }
        // Prefer an editable descendant if the focused element is a container
        let element = findEditableDescendant(from: root) ?? root

        // Try selection APIs first
        if let ctx = extractUsingSelectionAPIs(element: element, appName: appName) {
            return ctx
        }

        // Fallback to value + range if available
        var valueRef: CFTypeRef?
        _ = AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &valueRef)
        let fullText = (valueRef as? String) ?? ""

        var rangeRef: CFTypeRef?
        let rangeStatus = AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &rangeRef)
        if rangeStatus == .success,
           let rr = rangeRef,
           CFGetTypeID(rr) == AXValueGetTypeID() {
            let axVal: AXValue = unsafeBitCast(rr, to: AXValue.self)
            if AXValueGetType(axVal) == .cfRange {
                var cfRange = CFRange(location: 0, length: 0)
                if AXValueGetValue(axVal, .cfRange, &cfRange) {
                    let nsText = fullText as NSString
                    let start = min(max(0, cfRange.location), nsText.length)
                    let end = min(nsText.length, start + cfRange.length)

                    let before = nsText.substring(with: NSRange(location: 0, length: start))
                    let after = nsText.substring(from: end)

                    let beforeTail = String(before.suffix(200))
                    let afterHead = String(after.prefix(200))
                    if !beforeTail.isEmpty || !afterHead.isEmpty {
                        return FocusContext(appName: appName, beforeCursor: beforeTail, afterCursor: afterHead)
                    }
                }
            }
        }

        // Last fallback: if we only have some value
        if !fullText.isEmpty {
            let snippet = String(fullText.suffix(200))
            return FocusContext(appName: appName, beforeCursor: snippet, afterCursor: "")
        }

        return nil
    }

    // Recursively find the deepest focused subelement (handles AXGroup/containers)
    private func deepestFocusedElement(system: AXUIElement) -> AXUIElement? {
        var focusedRef: CFTypeRef?
        let s1 = AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focusedRef)
        guard s1 == .success, let first = focusedRef else { return nil }
        var current: AXUIElement = unsafeBitCast(first, to: AXUIElement.self)

        // Dive up to a few levels if the element has its own focused subelement
        for _ in 0..<3 {
            var childRef: CFTypeRef?
            let s = AXUIElementCopyAttributeValue(current, kAXFocusedUIElementAttribute as CFString, &childRef)
            if s == .success, let c = childRef {
                current = unsafeBitCast(c, to: AXUIElement.self)
            } else {
                break
            }
        }
        return current
    }

    // Depth-first search for an editable element that supports selection APIs
    private func findEditableDescendant(from element: AXUIElement, maxDepth: Int = 4) -> AXUIElement? {
        guard maxDepth >= 0 else { return nil }
        // Check if element looks editable
        if supportsSelectionAPIs(element) || hasEditableRole(element) {
            return element
        }
        // Recurse into children
        var childrenRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenRef) == .success,
           let arr = childrenRef as? [AXUIElement] {
            for child in arr {
                if let found = findEditableDescendant(from: child, maxDepth: maxDepth - 1) {
                    return found
                }
            }
        }
        return nil
    }

    private func supportsSelectionAPIs(_ element: AXUIElement) -> Bool {
        var tmp: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &tmp) == .success { return true }
        tmp = nil
        if AXUIElementCopyAttributeValue(element, kAXSelectedTextAttribute as CFString, &tmp) == .success { return true }
        var paramNames: CFArray?
        if AXUIElementCopyParameterizedAttributeNames(element, &paramNames) == .success,
           let arr = paramNames as? [String] {
            return arr.contains(kAXStringForRangeParameterizedAttribute as String)
        }
        return false
    }

    private func hasEditableRole(_ element: AXUIElement) -> Bool {
        var roleRef: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleRef)
        let role = roleRef as? String ?? ""
        if role == kAXTextAreaRole || role == kAXTextFieldRole || role == "AXWebArea" { return true }
        var settable = DarwinBoolean(false)
        if AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &settable) == .success, settable.boolValue {
            return true
        }
        return false
    }

    // Use AXSelectedText/AXStringForRange to build before/after around caret
    private func extractUsingSelectionAPIs(element: AXUIElement, appName: String) -> FocusContext? {
        // Get selected range
        var selRangeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &selRangeRef) == .success,
              let rr = selRangeRef else { return nil }
        let axRange: AXValue = unsafeBitCast(rr, to: AXValue.self)
        guard AXValueGetType(axRange) == .cfRange else { return nil }
        var sel = CFRange(location: 0, length: 0)
        guard AXValueGetValue(axRange, .cfRange, &sel) else { return nil }

        // We need total length. Try kAXValue, else request stringForRange in chunks
        var valRef: CFTypeRef?
        _ = AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &valRef)
        let fullText = (valRef as? String) ?? ""
        let totalLen = (fullText as NSString).length

        // Helper to request string for an arbitrary CFRange
        func stringFor(_ range: CFRange) -> String {
            var out: CFTypeRef?
            var r = range
            guard let param: AXValue = AXValueCreate(.cfRange, &r) else { return "" }
            let ok = AXUIElementCopyParameterizedAttributeValue(element, kAXStringForRangeParameterizedAttribute as CFString, param, &out)
            if ok == .success, let s = out as? String { return s }
            return ""
        }

        let before: String
        let after: String
        if totalLen > 0 { // We know the length; compute before/after directly
            let ns = fullText as NSString
            let start = min(max(0, sel.location), totalLen)
            let end = min(totalLen, start + sel.length)
            before = ns.substring(with: NSRange(location: 0, length: start))
            after = ns.substring(from: end)
        } else {
            // Unknown total; request via parameterized attribute
            let beforeRange = CFRange(location: 0, length: sel.location)
            let afterRange = CFRange(location: sel.location + sel.length, length: 200)
            before = stringFor(beforeRange)
            after = stringFor(afterRange)
        }

        let beforeTail = String(before.suffix(200))
        let afterHead = String(after.prefix(200))
        if beforeTail.isEmpty && afterHead.isEmpty { return nil }
        return FocusContext(appName: appName, beforeCursor: beforeTail, afterCursor: afterHead)
    }
}

// MARK: - Focused field metadata used by ContextAnalyzer
extension AccessibilityTextExtractor {
    struct FocusedFieldMeta {
        let frame: CGRect?
        let placeholder: String?
        let label: String?
        let role: String?
    }

    func focusedFieldMetadata() -> FocusedFieldMeta? {
        let system = AXUIElementCreateSystemWide()
        guard let root = deepestFocusedElement(system: system) else { return nil }
        let element = findEditableDescendant(from: root) ?? root

        // Role
        var roleRef: CFTypeRef?
        _ = AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleRef)
        let role = roleRef as? String

        // Placeholder (if supported)
        var placeRef: CFTypeRef?
        var placeholder: String? = nil
        if AXUIElementCopyAttributeValue(element, kAXPlaceholderValueAttribute as CFString, &placeRef) == .success {
            placeholder = placeRef as? String
        }

        // Frame
        var frameRef: CFTypeRef?
        var frame: CGRect? = nil
        if AXUIElementCopyAttributeValue(element, "AXFrame" as CFString, &frameRef) == .success,
           let fv = frameRef, CFGetTypeID(fv) == AXValueGetTypeID() {
            let ax: AXValue = unsafeBitCast(fv, to: AXValue.self)
            var r = CGRect.zero
            if AXValueGetValue(ax, .cgRect, &r) { frame = r }
        }

        // Label via TitleUIElement or Title attribute fallbacks
        var label: String? = nil
        var titleElRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXTitleUIElementAttribute as CFString, &titleElRef) == .success,
           let tel = titleElRef, CFGetTypeID(tel) == AXUIElementGetTypeID() {
            let titleEl: AXUIElement = unsafeBitCast(tel, to: AXUIElement.self)
            var titleValRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(titleEl, kAXTitleAttribute as CFString, &titleValRef) == .success {
                label = titleValRef as? String
            }
            if label == nil {
                var valRef: CFTypeRef?
                if AXUIElementCopyAttributeValue(titleEl, kAXValueAttribute as CFString, &valRef) == .success {
                    label = valRef as? String
                }
            }
        }
        if label == nil {
            var titleRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(element, kAXTitleAttribute as CFString, &titleRef) == .success {
                label = titleRef as? String
            }
        }

        return FocusedFieldMeta(frame: frame, placeholder: placeholder, label: label, role: role)
    }
} 