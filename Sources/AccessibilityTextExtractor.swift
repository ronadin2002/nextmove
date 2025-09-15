import Foundation
import AppKit
import ApplicationServices
import CoreGraphics
import QuartzCore
import UniformTypeIdentifiers

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

// MARK: - Typing snippet (few words before/after caret)
extension AccessibilityTextExtractor {
    /// Returns small before/after snippets (by words) around the caret using AX selection APIs
    /// Falls back to using kAXValue when stringForRange is unavailable
    func typingSnippet(maxWordsBefore: Int = 6, maxWordsAfter: Int = 6) -> (before: String, after: String)? {
        let system = AXUIElementCreateSystemWide()
        guard let root = deepestFocusedElement(system: system) else { return nil }
        let element = findEditableDescendant(from: root) ?? root

        // Get caret/selection range
        var selRangeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &selRangeRef) == .success,
              let rr = selRangeRef, CFGetTypeID(rr) == AXValueGetTypeID() else { return nil }
        let axRange: AXValue = unsafeBitCast(rr, to: AXValue.self)
        guard AXValueGetType(axRange) == .cfRange else { return nil }
        var sel = CFRange(location: 0, length: 0)
        guard AXValueGetValue(axRange, .cfRange, &sel) else { return nil }
        let caretIndex = sel.location

        // Prefer parameterized stringForRange
        func stringFor(_ range: CFRange) -> String {
            var out: CFTypeRef?
            var r = range
            guard let param: AXValue = AXValueCreate(.cfRange, &r) else { return "" }
            let ok = AXUIElementCopyParameterizedAttributeValue(element, kAXStringForRangeParameterizedAttribute as CFString, param, &out)
            if ok == .success, let s = out as? String { return s }
            return ""
        }

        // Try to fetch small windows around caret using stringForRange
        let windowLen = 200
        let beforeRange = CFRange(location: max(0, caretIndex - windowLen), length: min(windowLen, caretIndex))
        let afterRange = CFRange(location: caretIndex, length: windowLen)
        var before = stringFor(beforeRange)
        var after = stringFor(afterRange)

        if before.isEmpty && after.isEmpty {
            // Fallback to kAXValue
            var valRef: CFTypeRef?
            _ = AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &valRef)
            let fullText = (valRef as? String) ?? ""
            let ns = fullText as NSString
            let start = min(max(0, caretIndex), ns.length)
            let pre = ns.substring(with: NSRange(location: max(0, start - windowLen), length: min(windowLen, start)))
            let post = ns.substring(from: start)
            before = pre
            after = String(post.prefix(windowLen))
        }

        func lastWords(_ s: String, _ n: Int) -> String {
            let parts = s.split(whereSeparator: { $0.isWhitespace || $0.isNewline })
            guard !parts.isEmpty else { return "" }
            return parts.suffix(n).joined(separator: " ")
        }
        func firstWords(_ s: String, _ n: Int) -> String {
            let parts = s.split(whereSeparator: { $0.isWhitespace || $0.isNewline })
            guard !parts.isEmpty else { return "" }
            return parts.prefix(n).joined(separator: " ")
        }

        let beforeWords = lastWords(before, maxWordsBefore)
        let afterWords = firstWords(after, maxWordsAfter)
        if beforeWords.isEmpty && afterWords.isEmpty { return nil }
        return (beforeWords, afterWords)
    }
    
    /// Takes a screenshot of the whole screen and annotates it with an arrow pointing to the caret
    func captureScreenWithCaretAnnotation() -> Bool {
        let system = AXUIElementCreateSystemWide()
        guard let root = deepestFocusedElement(system: system) else { return false }
        let element = findEditableDescendant(from: root) ?? root
        
        // Get the caret position on screen
        guard let caretRect = getCaretScreenPosition(element: element) else { return false }
        
        // Take screenshot of the entire screen
        guard let screenshot = captureFullScreen() else { return false }
        
        // Annotate with arrow pointing to caret
        let annotatedImage = addCaretArrow(to: screenshot, caretPosition: caretRect)
        
        // Save the image
        return saveAnnotatedImage(annotatedImage)
    }
    
    private func getCaretScreenPosition(element: AXUIElement) -> CGRect? {
        print("🎯 Attempting to detect caret position using BoundsForRange...")
        
        // Only use the most accurate method: bounds for range
        if let rect = getCaretUsingBoundsForRange(element: element) {
            print("✅ Caret found using BoundsForRange: \(rect)")
            return rect
        }
        
        print("❌ Failed to determine caret position - BoundsForRange not supported")
        return nil
    }
    
    private func getCaretUsingBoundsForRange(element: AXUIElement) -> CGRect? {
        var selRangeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &selRangeRef) == .success,
              let rr = selRangeRef, CFGetTypeID(rr) == AXValueGetTypeID() else { 
            print("❌ BoundsForRange: Failed to get selection range")
            return nil 
        }
        let axRange: AXValue = unsafeBitCast(rr, to: AXValue.self)
        guard AXValueGetType(axRange) == .cfRange else { 
            print("❌ BoundsForRange: Invalid range type")
            return nil 
        }
        var sel = CFRange(location: 0, length: 0)
        guard AXValueGetValue(axRange, .cfRange, &sel) else { 
            print("❌ BoundsForRange: Failed to extract range value")
            return nil 
        }
        
        print("📍 Selection range: location=\(sel.location), length=\(sel.length)")
        
        var boundsRef: CFTypeRef?
        var range = sel
        guard let param: AXValue = AXValueCreate(.cfRange, &range) else { return nil }
        
        if AXUIElementCopyParameterizedAttributeValue(element, kAXBoundsForRangeParameterizedAttribute as CFString, param, &boundsRef) == .success,
           let bounds = boundsRef, CFGetTypeID(bounds) == AXValueGetTypeID() {
            let axBounds: AXValue = unsafeBitCast(bounds, to: AXValue.self)
            var rect = CGRect.zero
            if AXValueGetValue(axBounds, .cgRect, &rect) {
                print("📍 BoundsForRange result: \(rect)")
                return rect
            }
        }
        print("❌ BoundsForRange: Failed to get bounds")
        return nil
    }
    
    
    private func captureFullScreen() -> CGImage? {
        let displayID = CGMainDisplayID()
        return CGDisplayCreateImage(displayID)
    }
    
    private func addCaretArrow(to image: CGImage, caretPosition: CGRect) -> CGImage? {
        let width = image.width
        let height = image.height
        
        guard let context = CGContext(data: nil,
                                    width: width,
                                    height: height,
                                    bitsPerComponent: 8,
                                    bytesPerRow: 0,
                                    space: CGColorSpaceCreateDeviceRGB(),
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return nil
        }
        
        // Draw the original image
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        
        // Convert caret position to image coordinates (flip Y axis)
        let caretX = caretPosition.midX
        let caretY = CGFloat(height) - caretPosition.midY
        
        // Draw arrow pointing to caret
        drawArrow(in: context, pointingTo: CGPoint(x: caretX, y: caretY))
        
        return context.makeImage()
    }
    
    private func drawArrow(in context: CGContext, pointingTo point: CGPoint) {
        context.saveGState()
        
        // Set arrow properties
        context.setStrokeColor(red: 1.0, green: 0.0, blue: 0.0, alpha: 1.0) // Red color
        context.setFillColor(red: 1.0, green: 0.0, blue: 0.0, alpha: 1.0)
        context.setLineWidth(3.0)
        
        // Arrow dimensions
        let arrowHeadSize: CGFloat = 15
        
        // Position arrow above and to the left of the caret
        let arrowStart = CGPoint(x: point.x - 40, y: point.y - 40)
        let arrowEnd = point
        
        // Draw arrow line
        context.move(to: arrowStart)
        context.addLine(to: arrowEnd)
        context.strokePath()
        
        // Calculate arrow head
        let angle = atan2(arrowEnd.y - arrowStart.y, arrowEnd.x - arrowStart.x)
        let arrowHead1 = CGPoint(
            x: arrowEnd.x - arrowHeadSize * cos(angle - .pi/6),
            y: arrowEnd.y - arrowHeadSize * sin(angle - .pi/6)
        )
        let arrowHead2 = CGPoint(
            x: arrowEnd.x - arrowHeadSize * cos(angle + .pi/6),
            y: arrowEnd.y - arrowHeadSize * sin(angle + .pi/6)
        )
        
        // Draw arrow head
        context.move(to: arrowEnd)
        context.addLine(to: arrowHead1)
        context.move(to: arrowEnd)
        context.addLine(to: arrowHead2)
        context.strokePath()
        
        // Add a small circle at the caret position for better visibility
        context.setFillColor(red: 1.0, green: 0.0, blue: 0.0, alpha: 0.8)
        context.fillEllipse(in: CGRect(x: point.x - 5, y: point.y - 5, width: 10, height: 10))
        
        context.restoreGState()
    }
    
    private func saveAnnotatedImage(_ image: CGImage?) -> Bool {
        guard let image = image else { return false }
        
        // Create screenshots directory if it doesn't exist
        let screenshotsDir = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("screenshots")
        
        do {
            try FileManager.default.createDirectory(at: screenshotsDir, withIntermediateDirectories: true)
        } catch {
            print("Failed to create screenshots directory: \(error)")
            return false
        }
        
        // Generate filename with timestamp
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let timestamp = formatter.string(from: Date())
        let filename = "caret_screenshot_\(timestamp).png"
        let fileURL = screenshotsDir.appendingPathComponent(filename)
        
        // Save the image
        guard let destination = CGImageDestinationCreateWithURL(fileURL as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            print("Failed to create image destination")
            return false
        }
        
        CGImageDestinationAddImage(destination, image, nil)
        let success = CGImageDestinationFinalize(destination)
        
        if success {
            print("📸 Screenshot saved to: \(fileURL.path)")
        } else {
            print("❌ Failed to save screenshot")
        }
        
        return success
    }
} 