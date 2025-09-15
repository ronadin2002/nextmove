import Foundation
import AppKit
import CoreGraphics
import Carbon

@available(macOS 12.3, *)
protocol HotkeyServiceDelegate: AnyObject {
    func hotkeyTriggered()
}

@available(macOS 12.3, *)
final class HotkeyService: NSObject, @unchecked Sendable {
    weak var delegate: HotkeyServiceDelegate?
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var isEnabled = false
    
    override init() {
        super.init()
        setupGlobalHotkey()
    }
    
    deinit {
        cleanup()
    }
    
    private func setupGlobalHotkey() {
        print("🔧 Setting up CTRL+G global hotkey detection...")
        
        // Check and request permissions
        if !checkAndRequestPermissions() {
            print("❌ Insufficient permissions for global hotkey detection")
            return
        }
        
        print("✅ Permissions granted, setting up event tap...")
        
        // Create event tap with retry logic
        if !createEventTap() {
            print("❌ Failed to create event tap, falling back to alternative methods...")
            setupFallbackMethods()
            return
        }
        
        print("✅ Global CTRL+G hotkey detection active!")
        print("🎯 Press CTRL+G in any application to trigger AI assistance")
    }
    
    private func checkAndRequestPermissions() -> Bool {
        // Check accessibility permissions
        let accessibilityEnabled = AXIsProcessTrusted()
        
        if !accessibilityEnabled {
            print("🚨 Accessibility permissions required!")
            print("1. Go to System Preferences > Security & Privacy > Privacy > Accessibility")
            print("2. Click the lock and add PasteRecall.app")
            print("3. Restart the application")
            
            return false
        }
        
        return true
    }
    
    private func createEventTap() -> Bool {
        let eventMask = (1 << CGEventType.keyDown.rawValue)
        
        eventTap = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(eventMask),
            callback: { (proxy, type, event, refcon) -> Unmanaged<CGEvent>? in
                return HotkeyService.eventTapCallback(proxy: proxy, type: type, event: event, refcon: refcon)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        )
        
        guard let eventTap = eventTap else {
            return false
        }
        
        // Create run loop source
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0)
        guard let runLoopSource = runLoopSource else {
            return false
        }
        
        // Add to run loop and enable
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: eventTap, enable: true)
        isEnabled = true
        
        return true
    }
    
    private static func eventTapCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent, refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
        
        guard let refcon = refcon else {
            return Unmanaged.passRetained(event)
        }
        
        let hotkeyService = Unmanaged<HotkeyService>.fromOpaque(refcon).takeUnretainedValue()
        
        // Handle tap disabled
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let eventTap = hotkeyService.eventTap {
                CGEvent.tapEnable(tap: eventTap, enable: true)
                print("🔄 Event tap re-enabled")
            }
            return Unmanaged.passRetained(event)
        }
        
        // Process key events
        if type == .keyDown {
            let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
            let flags = event.flags
            
            // Check for CTRL+G (keyCode 5 = G)
            if keyCode == 5 && flags.contains(.maskControl) {
                print("🔥 CTRL+G detected! Triggering AI assistant...")
                
                DispatchQueue.main.async {
                    hotkeyService.delegate?.hotkeyTriggered()
                }
                
                // Optionally consume the event to prevent default behavior
                // return nil
            }
        }
        
        return Unmanaged.passRetained(event)
    }
    
    private func setupFallbackMethods() {
        print("🔄 Setting up fallback hotkey detection methods...")
        
        // Method 1: NSEvent global monitor (works in some cases)
        let _ = NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: { event in
            if event.keyCode == 5 && event.modifierFlags.contains(.control) {
                print("🔥 CTRL+G detected via NSEvent global monitor!")
                self.delegate?.hotkeyTriggered()
            }
        })
        print("✅ NSEvent global monitor enabled as fallback")
        
        // Method 2: Local monitor for when app is focused
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 5 && event.modifierFlags.contains(.control) {
                print("🔥 CTRL+G detected via NSEvent local monitor!")
                self.delegate?.hotkeyTriggered()
                return nil // Consume the event
            }
            return event
        }
        
        // Method 3: Manual trigger as last resort
        print("💡 Manual trigger available: type 'trigger' in terminal")
        DispatchQueue.global(qos: .background).async {
            while true {
                if let input = readLine(), input.lowercased().contains("trigger") {
                    print("🧪 Manual trigger activated!")
                    DispatchQueue.main.async {
                        self.delegate?.hotkeyTriggered()
                    }
                }
                Thread.sleep(forTimeInterval: 0.1)
            }
        }
    }
    
    private func cleanup() {
        if let runLoopSource = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
            self.runLoopSource = nil
        }
        
        if let eventTap = eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
            self.eventTap = nil
        }
        
        isEnabled = false
    }
    
    func isActive() -> Bool {
        return isEnabled
    }
} 