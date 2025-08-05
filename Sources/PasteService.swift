import Foundation
import AppKit
import CoreGraphics

@available(macOS 12.3, *)
final class PasteService {
    
    // Main function to paste text into the currently active application
    func pasteText(_ text: String) async -> Bool {
        guard !text.isEmpty else { return false }
        
        print("📝 Pasting text: \(String(text.prefix(50)))...")
        
        // Method 1: Try clipboard + CMD+V (most reliable)
        if await pasteViaClipboard(text) {
            return true
        }
        
        // Method 2: Try direct typing simulation
        if await pasteViaTyping(text) {
            return true
        }
        
        print("❌ Failed to paste text")
        return false
    }
    
    // Method 1: Copy to clipboard then simulate CMD+V
    private func pasteViaClipboard(_ text: String) async -> Bool {
        // Save current clipboard content
        let pasteboard = NSPasteboard.general
        let previousContent = pasteboard.string(forType: .string)
        
        // Set our text to clipboard
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        
        // Small delay to ensure clipboard is set
        try? await Task.sleep(nanoseconds: 50_000_000) // 50ms
        
        // Simulate CMD+V
        let success = simulateKeyPress(keyCode: 9, modifiers: .maskCommand) // V key with CMD
        
        // Restore previous clipboard content after a delay
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            if let previous = previousContent {
                pasteboard.clearContents()
                pasteboard.setString(previous, forType: .string)
            }
        }
        
        return success
    }
    
    // Method 2: Direct character typing simulation
    private func pasteViaTyping(_ text: String) async -> Bool {
        print("🔤 Attempting direct typing...")
        
        // Type characters one by one
        for char in text {
            if !simulateCharacterTyping(char) {
                return false
            }
            // Small delay between characters
            try? await Task.sleep(nanoseconds: 10_000_000) // 10ms
        }
        
        return true
    }
    
    // Simulate a key press with modifiers
    private func simulateKeyPress(keyCode: CGKeyCode, modifiers: CGEventFlags) -> Bool {
        guard let keyDownEvent = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: true),
              let keyUpEvent = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: false) else {
            return false
        }
        
        // Set modifiers
        keyDownEvent.flags = modifiers
        keyUpEvent.flags = modifiers
        
        // Post events
        keyDownEvent.post(tap: .cghidEventTap)
        keyUpEvent.post(tap: .cghidEventTap)
        
        return true
    }
    
    // Simulate typing a single character
    private func simulateCharacterTyping(_ character: Character) -> Bool {
        let string = String(character)
        
        // Create keyboard event for the character
        guard let event = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true) else {
            return false
        }
        
        // Set the character
        let length = string.utf16.count
        let utf16Chars = Array(string.utf16)
        event.keyboardSetUnicodeString(stringLength: length, unicodeString: utf16Chars)
        
        // Post key down and key up events
        event.post(tap: .cghidEventTap)
        
        // Create key up event
        if let keyUpEvent = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false) {
            keyUpEvent.keyboardSetUnicodeString(stringLength: length, unicodeString: utf16Chars)
            keyUpEvent.post(tap: .cghidEventTap)
        }
        
        return true
    }
    
    // Get information about the currently focused text field (if any)
    func getFocusedTextContext() -> (app: String, context: String)? {
        guard let frontmostApp = NSWorkspace.shared.frontmostApplication else {
            return nil
        }
        
        let appName = frontmostApp.localizedName ?? "Unknown"
        
        // Try to get more context using Accessibility API
        let systemWideElement = AXUIElementCreateSystemWide()
        var focusedElement: CFTypeRef?
        
        let result = AXUIElementCopyAttributeValue(systemWideElement, kAXFocusedUIElementAttribute as CFString, &focusedElement)
        
        if result == .success, let element = focusedElement {
            var value: CFTypeRef?
            let valueResult = AXUIElementCopyAttributeValue(element as! AXUIElement, kAXValueAttribute as CFString, &value)
            
            if valueResult == .success, let stringValue = value as? String {
                return (app: appName, context: String(stringValue.prefix(100)))
            }
        }
        
        return (app: appName, context: "")
    }
    
    // Check if we have the necessary permissions for pasting
    static func checkPastePermissions() -> Bool {
        // Check if we can create events (requires accessibility permissions)
        return CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true) != nil
    }
} 