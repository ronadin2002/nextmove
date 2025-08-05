import AppKit
import Foundation

@available(macOS 12.3, *)
final class SuggestionWindow: NSWindow, @unchecked Sendable {
    private var suggestionViews: [NSTextField] = []
    private var selectedIndex: Int = 0
    private var completion: ((Int?) -> Void)?
    
    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 120),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        
        setupWindow()
        setupKeyMonitoring()
    }
    
    private func setupWindow() {
        isOpaque = false
        backgroundColor = NSColor.clear
        level = .floating
        hasShadow = true
        isMovable = false
        
        // Create content view with rounded background
        let contentView = NSView(frame: self.frame)
        contentView.wantsLayer = true
        contentView.layer?.backgroundColor = NSColor.controlBackgroundColor.withAlphaComponent(0.95).cgColor
        contentView.layer?.cornerRadius = 12
        contentView.layer?.borderWidth = 1
        contentView.layer?.borderColor = NSColor.separatorColor.cgColor
        
        // Add shadow
        contentView.layer?.shadowColor = NSColor.black.cgColor
        contentView.layer?.shadowOpacity = 0.3
        contentView.layer?.shadowOffset = CGSize(width: 0, height: -2)
        contentView.layer?.shadowRadius = 8
        
        self.contentView = contentView
    }
    
    private func setupKeyMonitoring() {
        // Monitor local key events
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            return self?.handleKeyEvent(event)
        }
    }
    
    func showSuggestions(_ suggestions: [LLMSuggestion], at point: CGPoint, completion: @escaping (Int?) -> Void) {
        self.completion = completion
        
        // Clear previous suggestions
        suggestionViews.forEach { $0.removeFromSuperview() }
        suggestionViews.removeAll()
        
        // Position window near cursor
        let screenPoint = CGPoint(x: point.x + 10, y: point.y - 60)
        setFrameOrigin(screenPoint)
        
        // Create suggestion views
        createSuggestionViews(suggestions)
        
        // Show window
        makeKeyAndOrderFront(nil)
        
        // Auto-dismiss after 10 seconds
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
            self?.dismissWindow(selectedIndex: nil)
        }
    }
    
    private func createSuggestionViews(_ suggestions: [LLMSuggestion]) {
        guard let contentView = contentView else { return }
        
        let margin: CGFloat = 12
        let itemHeight: CGFloat = 30
        let totalHeight = CGFloat(suggestions.count) * itemHeight + margin * 2
        
        // Resize window
        setFrame(NSRect(x: frame.origin.x, y: frame.origin.y, width: 400, height: totalHeight), display: true)
        contentView.frame = self.frame
        
        // Create header
        let headerLabel = NSTextField(labelWithString: "✨ AI Suggestions (1-3 to select, ESC to cancel)")
        headerLabel.font = NSFont.systemFont(ofSize: 11, weight: .medium)
        headerLabel.textColor = NSColor.secondaryLabelColor
        headerLabel.frame = NSRect(x: margin, y: totalHeight - 25, width: 380, height: 16)
        contentView.addSubview(headerLabel)
        
        // Create suggestion items
        for (index, suggestion) in suggestions.enumerated() {
            let yPos = totalHeight - 50 - CGFloat(index) * itemHeight
            
            // Background view for selection
            let backgroundView = NSView(frame: NSRect(x: margin, y: yPos, width: 376, height: itemHeight - 2))
            backgroundView.wantsLayer = true
            backgroundView.layer?.cornerRadius = 6
            backgroundView.identifier = NSUserInterfaceItemIdentifier("bg_\(index)")
            contentView.addSubview(backgroundView)
            
            // Number label
            let numberLabel = NSTextField(labelWithString: "\(index + 1).")
            numberLabel.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .bold)
            numberLabel.textColor = NSColor.systemBlue
            numberLabel.frame = NSRect(x: margin + 8, y: yPos + 8, width: 20, height: 16)
            contentView.addSubview(numberLabel)
            
            // Suggestion text
            let textField = NSTextField(labelWithString: suggestion.text)
            textField.font = NSFont.systemFont(ofSize: 12)
            textField.textColor = NSColor.labelColor
            textField.frame = NSRect(x: margin + 35, y: yPos + 8, width: 330, height: 16)
            textField.maximumNumberOfLines = 1
            textField.lineBreakMode = .byTruncatingTail
            contentView.addSubview(textField)
            
            // Type badge
            let typeLabel = NSTextField(labelWithString: suggestion.type.uppercased())
            typeLabel.font = NSFont.systemFont(ofSize: 9, weight: .medium)
            typeLabel.textColor = NSColor.tertiaryLabelColor
            typeLabel.frame = NSRect(x: margin + 35, y: yPos + 2, width: 80, height: 12)
            contentView.addSubview(typeLabel)
            
            suggestionViews.append(textField)
        }
        
        updateSelection()
    }
    
    private func handleKeyEvent(_ event: NSEvent) -> NSEvent? {
        guard isVisible else { return event }
        
        let keyCode = event.keyCode
        let characters = event.charactersIgnoringModifiers ?? ""
        
        switch characters {
        case "1", "2", "3":
            if let index = Int(characters), index <= suggestionViews.count {
                dismissWindow(selectedIndex: index - 1)
                return nil
            }
        case "\u{1B}": // ESC key
            dismissWindow(selectedIndex: nil)
            return nil
        default:
            break
        }
        
        // Arrow key navigation
        switch keyCode {
        case 126: // Up arrow
            selectedIndex = max(0, selectedIndex - 1)
            updateSelection()
            return nil
        case 125: // Down arrow
            selectedIndex = min(suggestionViews.count - 1, selectedIndex + 1)
            updateSelection()
            return nil
        case 36: // Enter key
            dismissWindow(selectedIndex: selectedIndex)
            return nil
        default:
            break
        }
        
        return event
    }
    
    private func updateSelection() {
        guard let contentView = contentView else { return }
        
        // Update background colors
        for (index, _) in suggestionViews.enumerated() {
            if let bgView = contentView.subviews.first(where: { $0.identifier?.rawValue == "bg_\(index)" }) {
                bgView.layer?.backgroundColor = (index == selectedIndex) ? 
                    NSColor.selectedContentBackgroundColor.withAlphaComponent(0.3).cgColor :
                    NSColor.clear.cgColor
            }
        }
    }
    
    private func dismissWindow(selectedIndex: Int?) {
        orderOut(nil)
        completion?(selectedIndex)
        completion = nil
    }
} 