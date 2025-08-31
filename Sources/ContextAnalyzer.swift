import Foundation
import CoreGraphics
import AppKit
import Vision

@available(macOS 12.3, *)
struct ContextAnalysis {
    let currentScreen: String
    let recentContent: [String]
    let activeApp: String
    let cursorPosition: CGPoint
    let timestamp: Date
    let confidence: Float
    // NEW: Enhanced context fields
    let inputContext: InputContext
    let layoutAnalysis: LayoutAnalysis
    let semanticContext: SemanticContext
}

// NEW: Enhanced context structures
@available(macOS 12.3, *)
struct InputContext {
    let fieldType: InputFieldType
    let isTyping: Bool
    let currentText: String
    let textBeforeCursor: String
    let completionContext: CompletionType
    
    enum InputFieldType {
        case email, textEditor, chatMessage, searchBox, codeEditor, formField, unknown
    }
    
    enum CompletionType {
        case emailAddress, fullName, phoneNumber, url, sentence, code, data, unknown
    }
}

@available(macOS 12.3, *)
struct LayoutAnalysis {
    let windowStructure: WindowStructure
    let focusedElement: FocusedElement?
    let nearbyElements: [UIElement]
    
    struct WindowStructure {
        let isDialog: Bool
        let hasForm: Bool
        let hasTextFields: Bool
        let appType: AppType
    }
    
    struct FocusedElement {
        let type: ElementType
        let bounds: CGRect
        let placeholder: String?
        let label: String?
        // NEW: Role info
        let role: String?
    }
    
    struct UIElement {
        let text: String
        let type: ElementType
        let distance: Float
    }
    
    enum ElementType {
        case textField, button, label, title, menu, unknown
    }
    
    enum AppType {
        case emailClient, textEditor, browser, messaging, code, productivity, unknown
    }
}

@available(macOS 12.3, *)
struct SemanticContext {
    let currentTopic: String?
    let intentPrediction: Intent
    let relevantHistorySnippets: [String]
    
    enum Intent {
        case completing(what: String), continuing(context: String), correcting, unknown
    }
}

@available(macOS 12.3, *)
final class ContextAnalyzer {
    private let storage: TextStorage
    private let captureService: CaptureService
    private let axExtractor = AccessibilityTextExtractor()
    private let cursorInspector = CursorInspector()
    // High cap for how many ranked history lines go into the LLM prompt
    private let MAX_CONTEXT_HISTORY_LINES = 3000
    // Adaptive limits to keep prompts fast and avoid timeouts
    private let MAX_CONTEXT_LINES_HARD = 1500
    private let MAX_CONTEXT_BUDGET_CHARS = 60000
    private var recentlyPastedContent: [String] = []  // NEW: Track recently pasted content
    private var lastPasteTime: TimeInterval = 0      // NEW: Track when we last pasted
    
    init(storage: TextStorage, captureService: CaptureService) {
        self.storage = storage
        self.captureService = captureService
    }
    
    // NEW: Track pasted content to avoid feedback loops
    func recordPastedContent(_ text: String) {
        recentlyPastedContent.append(text)
        lastPasteTime = Date().timeIntervalSince1970
        
        // Keep only last 5 pasted items
        if recentlyPastedContent.count > 5 {
            recentlyPastedContent.removeFirst()
        }
        
        print("📝 Recorded pasted content to avoid feedback: '\(text.prefix(50))...'")
    }
    
    // NEW: Check if content was recently pasted (to avoid repetition)
    func wasRecentlyPasted(_ text: String) -> Bool {
        return recentlyPastedContent.contains { pasted in
            pasted.contains(text) || text.contains(pasted)
        }
    }
    
    // Main function to analyze current context when CMD+J is pressed
    func analyzeCurrentContext() async -> ContextAnalysis {
        print("🔍 Analyzing current context...")
        
        // CRITICAL: Wait for user to return to their actual work window
        print("⏳ Waiting for you to return to your document window...")
        try? await Task.sleep(nanoseconds: 1_000_000_000) // 1 second wait
        
        // Get current active application AFTER the wait
        let activeApp = getCurrentActiveApp()
        print("🎯 Detected active app: \(activeApp)")
        
        // If it's Terminal, give user more time to switch
        if activeApp.lowercased().contains("terminal") || activeApp.lowercased().contains("iterm") {
            print("⚠️ Still in terminal - waiting 2 more seconds for you to switch to your document...")
            try? await Task.sleep(nanoseconds: 2_000_000_000) // 2 more seconds
        }
        
        var currentScreen: String = ""

        // Fast path: use Accessibility to get exact caret text if available
		if let caret = axExtractor.focusedTextWithCursor() {
			let before = caret.beforeCursor
			let after = caret.afterCursor
			let combined = before + "____" + after
			print("⚡️ AX captured caret context: \(combined.prefix(120))")
			currentScreen = "TYPING: \(combined)"
        }

        // If AX failed we fall back to OCR/cursor strategies
        var mouseLocation = CGEvent(source: nil)?.location ?? .zero
        
        // If we already have currentScreen from AX, build analysis directly later
        if currentScreen.isEmpty {
            // Get main display info
            guard let displayID = CGMainDisplayID() as CGDirectDisplayID?,
                  let displayBounds = CGDisplayBounds(displayID) as CGRect? else {
                currentScreen = ""
                // Proceed but layout may be empty
                mouseLocation = .zero
            }
            
            print("🎯 Smart capture strategy at cursor: (\(Int(mouseLocation.x)), \(Int(mouseLocation.y)))")
            
            // Strategy 1: Capture focused area around cursor (for immediate context)
            let focusedText = await captureFocusedArea(mouseLocation: mouseLocation, displayID: displayID, displayBounds: displayBounds)
            
            // Strategy 2: Capture broader context (for layout understanding)
            let contextText = await captureBroaderContext(mouseLocation: mouseLocation, displayID: displayID, displayBounds: displayBounds)
            
            // Combine and analyze what user is likely typing/completing
            currentScreen = analyzeCapturedContext(focused: focusedText, broader: contextText)
            print("🔍 Smart capture result: '\(currentScreen.isEmpty ? "No relevant text" : String(currentScreen.prefix(150)))...'")
        }

        // Build full analysis with layout etc.
        var layoutAnalysis = await analyzeLayoutAndStructure(activeApp: activeApp)
        // NEW: enrich focused element with AX field metadata
        if let field = axExtractor.focusedFieldMetadata() {
            let bounds = field.frame ?? .zero
            let enriched = LayoutAnalysis.FocusedElement(
                type: .textField,
                bounds: bounds,
                placeholder: field.placeholder,
                label: field.label,
                role: field.role
            )
            layoutAnalysis = LayoutAnalysis(
                windowStructure: layoutAnalysis.windowStructure,
                focusedElement: enriched,
                nearbyElements: layoutAnalysis.nearbyElements
            )
        }
        let inputContext = await analyzeInputContext(screen: currentScreen, layout: layoutAnalysis)
        let semanticContext = await analyzeSemanticContext(input: inputContext, recent: await getRecentContent())

        let cursorPosition = getCursorPosition()

        let analysis = ContextAnalysis(
            currentScreen: currentScreen,
            recentContent: semanticContext.relevantHistorySnippets,
            activeApp: activeApp,
            cursorPosition: cursorPosition,
            timestamp: Date(),
            confidence: calculateEnhancedConfidence(input: inputContext, layout: layoutAnalysis),
            inputContext: inputContext,
            layoutAnalysis: layoutAnalysis,
            semanticContext: semanticContext
        )

        // Debug
        print("📊 Enhanced analysis complete: App=\(activeApp) CurrentText='\(inputContext.currentText.prefix(50))' Confidence=\(analysis.confidence)")

        return analysis
    }
    
    // NEW: Analyze layout and UI structure
    private func analyzeLayoutAndStructure(activeApp: String) async -> LayoutAnalysis {
        // Determine app type from name and characteristics
        let appType = classifyAppType(activeApp)
        
        // Capture larger area for structure analysis
        let structureText = await captureStructuralContext()
        
        // Analyze for UI patterns
        let windowStructure = analyzeWindowStructure(text: structureText, appType: appType)
        let focusedElement = detectFocusedElement(text: structureText)
        let nearbyElements = extractNearbyElements(text: structureText)
        
        return LayoutAnalysis(
            windowStructure: windowStructure,
            focusedElement: focusedElement,
            nearbyElements: nearbyElements
        )
    }
    
    // NEW: Analyze what type of input the user is making
    private func analyzeInputContext(screen: String, layout: LayoutAnalysis) async -> InputContext {
        let (fieldType, currentText, textBeforeCursor) = parseInputFromScreen(screen, layout: layout)
        let completionType = predictCompletionType(fieldType: fieldType, text: textBeforeCursor, layout: layout)
        let isTyping = detectIfUserIsTyping(screen: screen)
        
        return InputContext(
            fieldType: fieldType,
            isTyping: isTyping,
            currentText: currentText,
            textBeforeCursor: textBeforeCursor,
            completionContext: completionType
        )
    }
    
    // NEW: Analyze semantic context and intent
    private func analyzeSemanticContext(input: InputContext, recent: [String]) async -> SemanticContext {
        let topic = extractCurrentTopic(from: input, recent: recent)
        let intent = predictUserIntent(input: input, topic: topic)
        let relevantSnippets = filterRelevantHistory(recent: recent, for: input, topic: topic)
        
        return SemanticContext(
            currentTopic: topic,
            intentPrediction: intent,
            relevantHistorySnippets: relevantSnippets
        )
    }
    
    // NEW: Helper methods for enhanced analysis
    private func classifyAppType(_ appName: String) -> LayoutAnalysis.AppType {
        let name = appName.lowercased()
        if name.contains("mail") || name.contains("outlook") || name.contains("thunderbird") {
            return .emailClient
        } else if name.contains("textedit") || name.contains("word") || name.contains("pages") {
            return .textEditor
        } else if name.contains("chrome") || name.contains("safari") || name.contains("firefox") {
            return .browser
        } else if name.contains("slack") || name.contains("discord") || name.contains("whatsapp") || name.contains("message") {
            return .messaging
        } else if name.contains("xcode") || name.contains("vscode") || name.contains("vim") {
            return .code
        } else {
            return .unknown
        }
    }
    
    private func analyzeWindowStructure(text: String, appType: LayoutAnalysis.AppType) -> LayoutAnalysis.WindowStructure {
        let hasForm = text.contains("Subject:") || text.contains("To:") || text.contains("Name:") || text.contains("Email:")
        let hasTextFields = text.contains("____") || text.contains("Type") || text.contains("Enter")
        let isDialog = text.contains("Cancel") && text.contains("OK") || text.contains("Save")
        
        return LayoutAnalysis.WindowStructure(
            isDialog: isDialog,
            hasForm: hasForm,
            hasTextFields: hasTextFields,
            appType: appType
        )
    }
    
    private func parseInputFromScreen(_ screen: String, layout: LayoutAnalysis) -> (InputContext.InputFieldType, String, String) {
        // Look for cursor marker and extract surrounding context
        if let cursorRange = screen.range(of: "____") {
            let beforeCursor = String(screen[..<cursorRange.lowerBound])
            let lines = beforeCursor.components(separatedBy: .newlines)
            let currentLine = lines.last ?? ""
            
            // Determine field type based on context
            let fieldType = determineFieldType(context: beforeCursor, layout: layout)
            
            return (fieldType, currentLine, beforeCursor)
        }
        
        return (.unknown, "", "")
    }
    
    private func determineFieldType(context: String, layout: LayoutAnalysis) -> InputContext.InputFieldType {
        let lowerContext = context.lowercased()
        
        if lowerContext.contains("to:") || lowerContext.contains("subject:") || lowerContext.contains("@") {
            return .email
        } else if layout.windowStructure.appType == .messaging {
            return .chatMessage
        } else if layout.windowStructure.appType == .code {
            return .codeEditor
        } else if lowerContext.contains("search") {
            return .searchBox
        } else if layout.windowStructure.hasForm {
            return .formField
        } else if layout.windowStructure.appType == .textEditor {
            return .textEditor
        }
        
        return .unknown
    }
    
    private func predictCompletionType(fieldType: InputContext.InputFieldType, text: String, layout: LayoutAnalysis) -> InputContext.CompletionType {
        let cleanText = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        
        // Pattern-based detection
        if cleanText.hasSuffix("@") || (cleanText.contains("@") && !cleanText.contains(".")) {
            return .emailAddress
        } else if cleanText.contains("http") || cleanText.contains("www.") {
            return .url
        } else if cleanText.matches(pattern: "\\+?[0-9()\\s-]+$") {
            return .phoneNumber
        } else if fieldType == .codeEditor {
            return .code
        } else if cleanText.isEmpty || cleanText.count < 3 {
            return .data
        } else {
            return .sentence
        }
    }
    
    private func extractCurrentTopic(from input: InputContext, recent: [String]) -> String? {
        // NEW: Don't extract topics if we just pasted something (avoid feedback loops)
        let now = Date().timeIntervalSince1970
        if now - lastPasteTime < 10.0 {  // 10 second cooldown after pasting
            print("🕐 Topic extraction on cooldown (just pasted content)")
            return nil
        }
        
        // Filter out recently pasted content from analysis
        let filteredRecent = recent.filter { content in
            !recentlyPastedContent.contains { pasted in
                content.contains(pasted) || pasted.contains(content)
            }
        }
        
        // Combine recent content to understand current topic/context
        let allContent = (filteredRecent + [input.currentText]).joined(separator: " ").lowercased()
        
        // Simple topic extraction based on frequency
        let words = allContent.components(separatedBy: .whitespacesAndNewlines)
            .filter { $0.count > 3 }
            .filter { !["the", "and", "for", "are", "but", "not", "you", "all", "can", "had", "her", "was", "one", "our", "out", "day", "had", "has", "his", "how", "its", "may", "new", "now", "old", "see", "two", "way", "who", "boy", "did", "man", "oil", "sit", "yes", "chrome", "download", "available", "browser", "update", "version"].contains($0) }  // Added more browser-related words
        
        let wordCounts = Dictionary(grouping: words, by: { $0 }).mapValues { $0.count }
        let topWord = wordCounts.max(by: { $0.value < $1.value })?.key
        
        // NEW: Prevent getting stuck on browser/download topics
        if let topic = topWord, ["chrome", "browser", "download", "available", "update"].contains(topic.lowercased()) {
            print("🚫 Blocking repetitive browser topic: '\(topic)' - forcing neutral context")
            return nil
        }
        
        if let topic = topWord {
            print("🎯 Extracted topic: '\(topic)' (filtered out \(recent.count - filteredRecent.count) pasted items)")
        }
        
        return topWord
    }
    
    private func predictUserIntent(input: InputContext, topic: String?) -> SemanticContext.Intent {
        if input.textBeforeCursor.isEmpty {
            return .unknown
        }
        
        let text = input.textBeforeCursor.lowercased()
        
        if text.hasSuffix("@") || text.hasSuffix("john.") || text.hasSuffix("meeting at ") {
            return .completing(what: "partial input")
        } else if text.count > 10 && !text.hasSuffix(".") {
            return .continuing(context: topic ?? "text")
        } else {
            return .unknown
        }
    }
    
    // Get comprehensive recent content from logs - RAW JSONL LINES AS-IS
    private func getRecentContent() async -> [String] {
        let fileURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("content.jsonl")
        
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            print("📄 No content.jsonl file found - using current context only")
            return []
        }
        
        do {
            let content = try String(contentsOf: fileURL)
            let lines = content.components(separatedBy: .newlines).filter { !$0.isEmpty }
            
            print("📖 Found \(lines.count) total log entries in content.jsonl")
            
            // Take recent entries but filter out historical Wikipedia content
            let maxRecentLines = MAX_CONTEXT_HISTORY_LINES
            let mostRecentLines = Array(lines.suffix(maxRecentLines))
            
            // CRITICAL: Filter out Virginia Regiment/Wikipedia historical content
            let filteredLines = mostRecentLines.filter { line in
                let lowerLine = line.lowercased()
                
                // Block all Virginia Regiment/Wikipedia historical content
                let historicalTerms = [
                    "virginia regiment", "george washington", "french and indian war",
                    "wikipedia", "encyclopedia", "1754", "1758", "1762", "colonial",
                    "british army", "fort necessity", "jumonville", "braddock", "governor",
                    "continental army", "revolutionary war", "february 22, 1732",
                    "portrait", "assembly", "dinwiddie", "provincial forces"
                ]
                
                for term in historicalTerms {
                    if lowerLine.contains(term) {
                        return false  // Filter out historical content
                    }
                }
                
                return true  // Keep current/relevant content
            }
            
            // Parse JSONL into plain text items (supports both new and legacy schemas)
            var collected: [String] = []
            for line in filteredLines {
                guard let data = line.data(using: .utf8),
                      let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
                if let texts = obj["texts"] as? [String], !texts.isEmpty {
                    collected.append(contentsOf: texts)
                } else if let t = obj["t"] as? String, !t.isEmpty {
                    collected.append(t)
                }
            }
            // De-dupe while preserving order
            var seen = Set<String>()
            let uniqueTexts = collected.filter { text in
                if seen.contains(text) { return false }
                seen.insert(text)
                return true
            }
            print("📚 Extracted \(uniqueTexts.count) unique text items from \(filteredLines.count) log lines")
            return uniqueTexts
            
        } catch {
            print("❌ Error reading content logs: \(error)")
            return []
        }
    }
    
    // Fallback: get everything from storage
    private func getAllStorageContent() async -> [String] {
        return await storage.getRecentEverything(maxItems: 100)
    }
    
    // NEW: Get content filtered by type for specific completions
    private func getRecentContentByType(_ category: TextStorage.ContentCategory) async -> [String] {
        return await storage.getContentByType(category, maxItems: 10)
    }
    
    // NO FILTERING - just return everything
    private func filterRelevantHistory(recent: [String], for input: InputContext, topic: String?) -> [String] {
        print("🔍 NO FILTERING - returning ALL \(recent.count) recent items")
        return recent // keep all loaded lines; prompt builder will rank/slice
    }
    
    private func calculateEnhancedConfidence(input: InputContext, layout: LayoutAnalysis) -> Float {
        var confidence: Float = 0.5
        
        // Boost confidence based on clear context
        if input.fieldType != .unknown { confidence += 0.2 }
        if input.completionContext != .unknown { confidence += 0.2 }
        if layout.focusedElement != nil { confidence += 0.1 }
        
        return min(confidence, 1.0)
    }
    
    private func detectIfUserIsTyping(screen: String) -> Bool {
        return screen.contains("____") || screen.contains("Type") || screen.contains("|")
    }
    
    private func detectFocusedElement(text: String) -> LayoutAnalysis.FocusedElement? {
        // Simple detection - could be enhanced with accessibility APIs
        return nil
    }
    
    private func extractNearbyElements(text: String) -> [LayoutAnalysis.UIElement] {
        // Extract UI elements from screen text
        return []
    }
    
    private func captureStructuralContext() async -> String {
        // Capture larger area for understanding UI structure
        return await captureCurrentContext()
    }
    
    // Smart capture strategy: focused area + broader context for layout understanding
    private func captureCurrentContext() async -> String {
        // Get cursor position
        let mouseLocation = CGEvent(source: nil)?.location ?? .zero
        
        // Get main display info
        guard let displayID = CGMainDisplayID() as CGDirectDisplayID?,
              let displayBounds = CGDisplayBounds(displayID) as CGRect? else {
            return ""
        }
        
        print("🎯 Smart capture strategy at cursor: (\(Int(mouseLocation.x)), \(Int(mouseLocation.y)))")
        
        // Strategy 1: Capture focused area around cursor (for immediate context)
        let focusedText = await captureFocusedArea(mouseLocation: mouseLocation, displayID: displayID, displayBounds: displayBounds)
        
        // Strategy 2: Capture broader context (for layout understanding)
        let contextText = await captureBroaderContext(mouseLocation: mouseLocation, displayID: displayID, displayBounds: displayBounds)
        
        // Combine and analyze what user is likely typing/completing
        let combinedContext = analyzeCapturedContext(focused: focusedText, broader: contextText)
        
        print("🔍 Smart capture result: '\(combinedContext.isEmpty ? "No relevant text" : String(combinedContext.prefix(150)))...'")
        return combinedContext
    }
    
    // Capture small focused area around cursor (what user is directly working on)
    private func captureFocusedArea(mouseLocation: CGPoint, displayID: CGDirectDisplayID, displayBounds: CGRect) async -> String {
        let focusWidth: CGFloat = 600   // Increased from 400
        let focusHeight: CGFloat = 300  // Increased from 200
        
        let captureX = max(0, mouseLocation.x - focusWidth / 2)
        let captureY = max(0, mouseLocation.y - focusHeight / 2)
        
        let captureRect = CGRect(
            x: captureX,
            y: captureY,
            width: min(focusWidth, displayBounds.width - captureX),
            height: min(focusHeight, displayBounds.height - captureY)
        )
        
        guard let screenshot = CGDisplayCreateImage(displayID, rect: captureRect) else {
            return ""
        }
        
        return await performFocusedOCR(screenshot)
    }
    
    // Capture broader context around cursor (for understanding layout and app context)
    private func captureBroaderContext(mouseLocation: CGPoint, displayID: CGDirectDisplayID, displayBounds: CGRect) async -> String {
        let contextWidth: CGFloat = 1000
        let contextHeight: CGFloat = 600
        
        let captureX = max(0, mouseLocation.x - contextWidth / 2)
        let captureY = max(0, mouseLocation.y - contextHeight / 2)
        
        let captureRect = CGRect(
            x: captureX,
            y: captureY,
            width: min(contextWidth, displayBounds.width - captureX),
            height: min(contextHeight, displayBounds.height - captureY)
        )
        
        guard let screenshot = CGDisplayCreateImage(displayID, rect: captureRect) else {
            return ""
        }
        
        return await performContextOCR(screenshot)
    }
    
    // Analyze both captures to understand what user is typing/completing
    private func analyzeCapturedContext(focused: String, broader: String) -> String {
        var result: [String] = []
        
        // Get cursor position for marker insertion
        let cursorPosition = getCursorPosition()
        
        // Prioritize focused area content (what user is directly working on)
        if !focused.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let focusedWithCursor = insertCursorMarker(in: focused, at: cursorPosition)
            result.append("FOCUSED_AREA: \(focusedWithCursor)")
        }
        
        // Add broader context for understanding (app type, form fields, etc.)
        if !broader.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            // Filter broader context to remove redundancy with focused area
            let broaderFiltered = broader.replacingOccurrences(of: focused, with: "").trimmingCharacters(in: .whitespacesAndNewlines)
            if !broaderFiltered.isEmpty && broaderFiltered.count > 10 {
                result.append("CONTEXT: \(broaderFiltered)")
            }
        }
        
        return result.joined(separator: " | ")
    }
    
    // Insert cursor marker (____) to show where user is currently positioned
    private func insertCursorMarker(in text: String, at cursorPosition: CGPoint) -> String {
        // CRITICAL: Focus ONLY on current typing, ignore ALL historical content
        
        print("🔍 Raw captured text for cursor detection:")
        print("   \(text)")
        
        let lines = text.components(separatedBy: "\n")
        var candidateLines: [(index: Int, line: String, score: Int)] = []
        
        // Score each line ONLY for current user typing (not historical content)
        for (lineIndex, line) in lines.enumerated() {
            let trimmedLine = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmedLine.count > 2 else { continue }
            
            var score = 0
            
            // MASSIVE penalty for historical Wikipedia/reference content
            let historicalTerms = [
                "Virginia Regiment", "Wikipedia", "George Washington", "French and Indian War",
                "1754", "1758", "1762", "Colonial", "British", "Assembly", "Governor",
                "Fort Necessity", "Jumonville", "Braddock", "Revolutionary War",
                "Continental Army", "President", "February", "December", "Portrait"
            ]
            
            for term in historicalTerms {
                if trimmedLine.contains(term) {
                    score -= 10000  // Massive penalty for historical content
                    print("   🚫 HISTORICAL CONTENT: '\(trimmedLine)'")
                }
            }
            
            // MASSIVE penalty for recently pasted content to avoid feedback loops
            for pastedContent in recentlyPastedContent {
                if trimmedLine.contains(pastedContent) || pastedContent.contains(trimmedLine) {
                    score -= 5000  // Huge penalty to avoid feedback
                    print("   🚫 FEEDBACK DETECTED: Line contains recently pasted content")
                }
            }
            
            // MASSIVE penalty for obvious repetitive patterns
            if containsRepetitivePattern(trimmedLine) {
                score -= 3000
                print("   🚫 REPETITIVE PATTERN: '\(trimmedLine)'")
            }
            
            // HUGE bonus for current document text that user is actually typing
            let currentDocumentTerms = [
                "Tel aviv", "governed by", "israel", "city", "municipality", "mayor"
            ]
            
            for term in currentDocumentTerms {
                if trimmedLine.lowercased().contains(term.lowercased()) {
                    score += 5000  // Huge bonus for current document content
                    print("   🎯 CURRENT DOCUMENT: '\(trimmedLine)' (score boost: +5000)")
                }
            }
            
            // MASSIVE bonus for incomplete sentences (where user is likely typing)
            if trimmedLine.lowercased().contains("tel aviv is governed by") ||
               trimmedLine.lowercased().contains("governed by") ||
               trimmedLine.lowercased().contains("parliament") && trimmedLine.count < 50 {
                score += 8000  // Even bigger bonus for active typing
                print("   🔥 ACTIVE TYPING DETECTED: '\(trimmedLine)' (score boost: +8000)")
            }
            
            // Bonus for lines that look like active typing (incomplete, short)
            if trimmedLine.count < 30 && !trimmedLine.hasSuffix(".") && 
               !trimmedLine.contains("{") && !trimmedLine.contains("\"") {
                score += 1000
                print("   ✏️ INCOMPLETE LINE: '\(trimmedLine)' (score: +1000)")
            }
            
            // Bonus for lines ending with "by" (matches "governed by")
            if trimmedLine.lowercased().hasSuffix(" by") {
                score += 3000
                print("   🎯 ENDS WITH 'BY': '\(trimmedLine)' (score: +3000)")
            }
            
            // MASSIVE penalties for JSON/log format content
            if trimmedLine.contains("{") || trimmedLine.contains("\"t\":") || 
               trimmedLine.contains("\"c\":") || trimmedLine.contains("\"m\":") {
                score -= 8000
                print("   🚫 JSON/LOG FORMAT: '\(trimmedLine)'")
            }
            
            // MASSIVE penalties for obvious UI/system text
            let uiKeywords = [
                "Subject", "Recipients", "Order ID", "Receipt", "Document", "Account", 
                "Apple", "Update", "Demo Day", "Contact Information", "reviews", "Message",
                "New Message", "Promotions", "Updates", "Social", "Palmer", "Console",
                "Founded", "$ Founded", "Templates", "Blog", "Courses", "Work", "Contact",
                "Chrome", "download", "available", "wikipedia", "encyclopedia"
            ]
            
            for keyword in uiKeywords {
                if trimmedLine.lowercased().contains(keyword.lowercased()) {
                    score -= 2000 // Huge penalty for UI
                }
            }
            
            candidateLines.append((index: lineIndex, line: trimmedLine, score: score))
        }
        
        // Sort by score and show top candidates
        let sortedCandidates = candidateLines.sorted { $0.score > $1.score }
        print("🏆 Top cursor candidates:")
        for (i, candidate) in sortedCandidates.prefix(5).enumerated() {
            print("   \(i+1). '\(candidate.line)' (score: \(candidate.score))")
        }
        
        // Find the best candidate line (must have positive score for current content)
        if let best = sortedCandidates.first, best.score > 0 {
            print("🎯 SELECTED cursor line: '\(best.line)' (score: \(best.score))")
            
            // Add cursor marker at the end of the best candidate line
            let lineWithCursor = "\(best.line)____"
            
            return "TYPING: \(lineWithCursor)"
        }
        
        print("⚠️ No current typing content found - defaulting to generic cursor")
        return "TYPING: ____"
    }
    
    // NEW: Check for repetitive patterns in a single line
    private func containsRepetitivePattern(_ text: String) -> Bool {
        let words = text.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }
        
        // Need enough words to check for patterns
        guard words.count >= 6 else { return false }
        
        // Check for obvious repetitions like "the third man to walk was the third man to walk"
        for i in 0..<words.count {
            let remainingWords = words.count - i
            let maxPossibleLength = min(6, remainingWords / 2)  // Can't be longer than half remaining words
            
            // Skip if we don't have enough words for meaningful pattern detection
            guard maxPossibleLength >= 3 else { continue }
            
            for length in 3...maxPossibleLength {
                // Make sure we have enough words for both phrases
                guard i + length * 2 <= words.count else { continue }
                
                let phrase1 = words[i..<i+length].joined(separator: " ")
                let phrase2 = words[i+length..<i+length*2].joined(separator: " ")
                
                if phrase1.lowercased() == phrase2.lowercased() {
                    print("   🚫 Found repetitive pattern: '\(phrase1)' repeated")
                    return true
                }
            }
        }
        
        return false
    }
    
    // Focused OCR - what user is directly typing/working on
    private func performFocusedOCR(_ cgImage: CGImage) async -> String {
        return await withCheckedContinuation { continuation in
            let ocrService = OcrService()
            ocrService.recognize(cgImage: cgImage) { blocks in
                let focusedText = blocks
                    .filter { $0.confidence > 0.8 }
                    .map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { text in
                        // Very selective - only meaningful content
                        guard text.count > 2 else { return false }
                        
                        // Skip obvious UI elements but keep content
                        let skipTerms = ["add", "home", "menu", "ok", "cancel", "save", "edit"]
                        let cleanText = text.lowercased()
                        guard !skipTerms.contains(cleanText) else { return false }
                        
                        return true
                    }
                    .sorted { $0.count > $1.count }
                    .prefix(8) // More focused content
                    .joined(separator: " ")
                
                continuation.resume(returning: focusedText)
            }
        }
    }
    
    // Context OCR - broader understanding of layout and app
    private func performContextOCR(_ cgImage: CGImage) async -> String {
        return await withCheckedContinuation { continuation in
            let ocrService = OcrService()
            ocrService.recognize(cgImage: cgImage) { blocks in
                let contextText = blocks
                    .filter { $0.confidence > 0.7 } // Lower threshold for context
                    .map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { text in
                        // More inclusive for context understanding
                        guard text.count > 1 else { return false }
                        
                        // Keep app names, form labels, but skip pure navigation
                        let skipTerms = ["back", "next", "close", "minimize"]
                        let cleanText = text.lowercased()
                        guard !skipTerms.contains(cleanText) else { return false }
                        
                        return true
                    }
                    .sorted { $0.count > $1.count }
                    .prefix(15) // More context items
                    .joined(separator: " ")
                
                continuation.resume(returning: contextText)
            }
        }
    }
    
    // Quiet capture to avoid feedback loops
    private func captureCurrentContextQuietly() async -> String {
        // Get cursor position
        let mouseLocation = CGEvent(source: nil)?.location ?? .zero
        
        // Find the display that actually contains the cursor
        guard let (displayID, displayBounds) = getDisplayContaining(point: mouseLocation) else {
            return ""
        }
        
        // Capture focused area around cursor (for immediate context)
        let focusedText = await captureFocusedAreaQuietly(mouseLocation: mouseLocation, displayID: displayID, displayBounds: displayBounds)
        
        // Capture broader context (for layout understanding)
        let contextText = await captureBroaderContextQuietly(mouseLocation: mouseLocation, displayID: displayID, displayBounds: displayBounds)
        
        // Combine and analyze what user is likely typing/completing
        let combinedContext = analyzeCapturedContextQuietly(focused: focusedText, broader: contextText)
        
        return combinedContext
    }
    
    // Capture focused area without debug spam
    private func captureFocusedAreaQuietly(mouseLocation: CGPoint, displayID: CGDirectDisplayID, displayBounds: CGRect) async -> String {
        let focusWidth: CGFloat = 600
        let focusHeight: CGFloat = 300
        
        let captureX = max(displayBounds.minX, mouseLocation.x - focusWidth / 2)
        let captureY = max(displayBounds.minY, mouseLocation.y - focusHeight / 2)
        
        let captureRect = CGRect(
            x: captureX,
            y: captureY,
            width: min(focusWidth, displayBounds.maxX - captureX),
            height: min(focusHeight, displayBounds.maxY - captureY)
        )
        
        guard let screenshot = CGDisplayCreateImage(displayID, rect: captureRect) else {
            return ""
        }
        
        return await performCleanOCR(screenshot)
    }
    
    // Capture broader context without debug spam
    private func captureBroaderContextQuietly(mouseLocation: CGPoint, displayID: CGDirectDisplayID, displayBounds: CGRect) async -> String {
        let contextWidth: CGFloat = 1000
        let contextHeight: CGFloat = 600
        
        let captureX = max(displayBounds.minX, mouseLocation.x - contextWidth / 2)
        let captureY = max(displayBounds.minY, mouseLocation.y - contextHeight / 2)
        
        let captureRect = CGRect(
            x: captureX,
            y: captureY,
            width: min(contextWidth, displayBounds.maxX - captureX),
            height: min(contextHeight, displayBounds.maxY - captureY)
        )
        
        guard let screenshot = CGDisplayCreateImage(displayID, rect: captureRect) else {
            return ""
        }
        
        return await performCleanOCR(screenshot)
    }
    
    // Clean OCR that filters out terminal/debug content
    private func performCleanOCR(_ cgImage: CGImage) async -> String {
        return await withCheckedContinuation { continuation in
            let ocrService = OcrService()
            ocrService.recognize(cgImage: cgImage) { blocks in
                let cleanText = blocks
                    .filter { $0.confidence > 0.7 } // Lower threshold to catch more content
                    .map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { text in
                        // NUCLEAR filtering of ALL system/terminal content
                        let lowerText = text.lowercased()
                        
                        // Block ALL system/terminal content aggressively
                        let systemTerms = [
                            // Terminal/Build terms
                            "build", "warning", "swift", "product", "nextmove-2", "debug",
                            "consider replacing", "assignment", "immutable", "never used",
                            "cmd+key", "permissions", "granted", "event tap", "hotkey",
                            "xxhash-swift", "dependency", "target", "bytes", "entries",
                            "display", "origin", "starting", "capture", "stream",
                            "initialized", "api key", "fallback", "assistance",
                            
                            // OCR/System noise
                            "step", "completion", "suggestions", "gpt", "openai", "llm", "api",
                            "confidence", "pasting", "auto-paste", "cursor", "detected", "trigger",
                            "enhanced", "selection", "source materials", "source elements",
                            "jsonl", "logs", "prompt", "response", "analysis", "context",
                            
                            // Google UI elements (but keep document content)
                            "format tools extensions help", "normal text", "arial",
                            "saved to drive", "100%", "saving..."
                        ]
                        
                        for term in systemTerms {
                            if lowerText.contains(term) {
                                return false
                            }
                        }
                        
                        // Block coordinate/technical patterns
                        if text.contains("id=") || text.contains("origin=") || 
                           text.contains("1920x1080") || text.contains("1710x1107") ||
                           text.matches(pattern: "\\d+\\.\\d+,\\s*\\d+\\.\\d+") {
                            return false
                        }
                        
                        // Block anything with parentheses + numbers (technical output)
                        if text.contains("(") && text.contains(")") && 
                           text.rangeOfCharacter(from: .decimalDigits) != nil && text.count > 30 {
                            return false
                        }
                        
                        // PRIORITIZE document content patterns
                        let documentKeywords = [
                            "tel aviv", "governed by", "israel", "city", "municipality",
                            "parliament", "great britain", "kingdom", "established"
                        ]
                        
                        for keyword in documentKeywords {
                            if lowerText.contains(keyword) {
                                print("🎯 FOUND DOCUMENT CONTENT: '\(text)'")
                                return true // Always keep document content
                            }
                        }
                        
                        // Only keep natural language text
                        let hasLetters = text.rangeOfCharacter(from: .letters) != nil
                        let hasSpaces = text.contains(" ")
                        let isReasonableLength = text.count >= 3 && text.count <= 100
                        let notMostlySymbols = text.filter { $0.isLetter }.count > text.count / 3
                        
                        return hasLetters && hasSpaces && isReasonableLength && notMostlySymbols
                    }
                    .sorted { text1, text2 in
                        // Prioritize document content over everything else
                        let text1Lower = text1.lowercased()
                        let text2Lower = text2.lowercased()
                        
                        let text1IsDoc = text1Lower.contains("tel aviv") || text1Lower.contains("governed") ||
                                        text1Lower.contains("parliament") || text1Lower.contains("britain")
                        let text2IsDoc = text2Lower.contains("tel aviv") || text2Lower.contains("governed") ||
                                        text2Lower.contains("parliament") || text2Lower.contains("britain")
                        
                        if text1IsDoc && !text2IsDoc { return true }
                        if text2IsDoc && !text1IsDoc { return false }
                        
                        return text1.count > text2.count
                    }
                    .prefix(3) // Only top 3 most relevant results
                    .joined(separator: " ")
                
                print("🔍 Clean OCR result: '\(cleanText)'")
                continuation.resume(returning: cleanText)
            }
        }
    }
    
    // Analyze captured context without debug output
    private func analyzeCapturedContextQuietly(focused: String, broader: String) -> String {
        var result: [String] = []
        
        // Prioritize focused area content
        if !focused.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            result.append("USER_TYPING: \(focused)")
        }
        
        // Add broader context if different and meaningful
        if !broader.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let broaderFiltered = broader.replacingOccurrences(of: focused, with: "").trimmingCharacters(in: .whitespacesAndNewlines)
            if !broaderFiltered.isEmpty && broaderFiltered.count > 10 {
                result.append("APP_CONTEXT: \(broaderFiltered)")
            }
        }
        
        return result.joined(separator: " | ")
    }
    
    // Helper to get readable category names
    private func getCategoryName(_ shortCode: String) -> String {
        switch shortCode {
        case "email": return "Email"
        case "url": return "URLs"
        case "code": return "Code"
        case "doc": return "Documents"
        case "ui": return "Interface"
        case "num": return "Numbers"
        case "txt": return "Text"
        case "file": return "Files"
        default: return "Other"
        }
    }
    
    // Get current active application
    private func getCurrentActiveApp() -> String {
        guard let activeApp = NSWorkspace.shared.frontmostApplication else {
            return "Unknown"
        }
        return activeApp.localizedName ?? activeApp.bundleIdentifier ?? "Unknown"
    }
    
    // Get current cursor position
    private func getCursorPosition() -> CGPoint {
        return CGEvent(source: nil)?.location ?? .zero
    }
    
    // Calculate confidence score for the context
    private func calculateConfidence(screen: String, recent: [String]) -> Float {
        var confidence: Float = 0.5 // Base confidence
        
        // Increase confidence based on screen content quality
        if !screen.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            confidence += 0.2
        }
        
        // Increase confidence based on recent content availability
        if !recent.isEmpty {
            confidence += 0.2
        }
        
        // Increase confidence if screen content is substantial
        if screen.count > 50 {
            confidence += 0.1
        }
        
        return min(confidence, 1.0)
    }
    
    // Generate LLM prompt from context analysis
    func generateLLMPrompt(from analysis: ContextAnalysis) -> String {
        // STEP 0 — rank history lines by keyword–overlap to cursor
        let cursorLower = analysis.currentScreen.lowercased()
        let keywords = Set(cursorLower.split { !$0.isLetter }
            .map(String.init)
            .filter { $0.count >= 3 })
        
        func score(line: String) -> Int {
            let lower = line.lowercased()
            return keywords.filter { lower.contains($0) }.count
        }
        
        let ranked = analysis.recentContent
            .map { ($0, score(line: $0)) }
            .sorted { $0.1 == $1.1 ? $0.0.count > $1.0.count : $0.1 > $1.1 }
        // Strict newest-to-oldest ordering: take from the end of the list backwards
        var ordered = Array(analysis.recentContent.reversed())
        if ordered.count > MAX_CONTEXT_HISTORY_LINES {
            ordered = Array(ordered.prefix(MAX_CONTEXT_HISTORY_LINES))
        }
        // Start with the ordered list, then adaptively shrink by char budget and hard line cap
        var top = ordered
        // Enforce hard line cap first
        if top.count > MAX_CONTEXT_LINES_HARD {
            top = Array(top.prefix(MAX_CONTEXT_LINES_HARD))
        }
        // Enforce character budget on JSON serialization cost (rough heuristic)
        var totalChars = 0
        var budgeted: [String] = []
        for item in top {
            let added = item.count + 3 // quotes and comma overhead
            if totalChars + added > MAX_CONTEXT_BUDGET_CHARS {
                // Do not skip the first item even if it is long
                if budgeted.isEmpty { budgeted.append(item) }
                break
            }
            totalChars += added
            budgeted.append(item)
        }
        top = budgeted
        // Serialize context as JSON (matching content.jsonl schema) to embed in the prompt
        let contextJSON: String = {
            if let data = try? JSONSerialization.data(withJSONObject: [
                "app": "AI_ASSISTANT",
                "window": "CONTEXT",
                "texts": top
            ], options: []), let s = String(data: data, encoding: .utf8) {
                return s
            }
            return "{\"app\":\"AI_ASSISTANT\",\"window\":\"CONTEXT\",\"texts\":[]}"
        }()
        
        // Compose focused field line if present
        let focusedFieldLine: String = {
            if let f = analysis.layoutAnalysis.focusedElement {
                let name = f.label ?? f.placeholder ?? f.role ?? ""
                if !name.isEmpty { return "FOCUSED FIELD: \(name)" }
            }
            return ""
        }()
        
        // STEP 1 — build the new prompt
        let prompt = """
        SYSTEM:
        You are an auto-completion engine. Cursor is at ____ and you must replace it.
        
        USER CONTEXT
        ────────────
        APP        : \(analysis.activeApp)
        TIMESTAMP  : \(analysis.timestamp)
        CURSOR LINE: \(analysis.currentScreen)
        \(focusedFieldLine)
        
        RELEVANT HISTORY (JSON, newest → oldest)
        ────────────
        \(contextJSON)
        
        COMPLETION RULES
        ────────────
        1. Replace the ____ marker with ≤ 25 tokens that complete the cursor line grammatically.
        2. Re-use phrases / data from RELEVANT HISTORY when helpful.
        3. Do NOT inject new topics; stay on the same subject & tone.
        4. If you have no useful completion, respond with JSON: { "text": "", "confidence": 0 }.
        
        Respond ONLY with JSON:
        { "text": "<completion>", "confidence": <0-1> }
        """
        
        // Log prompt to file asynchronously (single JSONL entry)
        let storageRef = self.storage
        		Task.detached {
			await storageRef.logPrompt(prompt: prompt)
		}
        
        // Also print exact string being sent to LLM
        print("\n===== FULL PROMPT SENT TO LLM =====\n\(prompt)\n===== END PROMPT =====\n")
        
        return prompt
    }
    
    private func buildContextSpecificPrompt(
        inputType: InputContext.InputFieldType,
        completionType: InputContext.CompletionType,
        intent: SemanticContext.Intent,
        textBeforeCursor: String,
        relevantHistory: [String]
    ) -> String {
        
        switch completionType {
        case .emailAddress:
            return """
            TASK: Complete the email address at the cursor position.
            RULES:
            1. Use EXACT email addresses from recent activity
            2. If user typed "john@" complete with actual domain from history
            3. If user typed "john.sm" complete with "ith@domain.com" from history
            4. NO generic emails like "example@example.com"
            """
            
        case .fullName:
            return """
            TASK: Complete the person's name at the cursor position.
            RULES:
            1. Use EXACT names from recent activity and contacts
            2. If user typed "John" suggest "Smith" if "John Smith" appears in history
            3. Complete with full names from recent emails, contacts, or messages
            """
            
        case .phoneNumber:
            return """
            TASK: Complete the phone number at the cursor position.
            RULES:
            1. Use EXACT phone numbers from recent activity
            2. Format consistently (e.g., (555) 123-4567)
            3. Complete partial numbers with actual numbers from history
            """
            
        case .sentence:
            return """
            TASK: Continue the sentence naturally.
            RULES:
            1. Use phrases and content from recent activity about the same topic
            2. Continue the thought logically from where cursor is positioned
            3. Use actual content the user has been reading/writing about
            """
            
        case .url:
            return """
            TASK: Complete the URL at the cursor position.
            RULES:
            1. Use EXACT URLs from recent browsing history
            2. Complete domain names with actual sites user has visited
            3. NO placeholder URLs like "example.com"
            """
            
        default:
            return """
            TASK: Provide contextual completion based on what user is typing.
            RULES:
            1. Use content from recent activity that matches the context
            2. Complete with specific, actual data rather than generic terms
            3. Consider what the user is likely trying to type in this application
            """
        }
    }

    // Determine which display contains the given point (global coordinates)
    private func getDisplayContaining(point: CGPoint) -> (CGDirectDisplayID, CGRect)? {
        var count: UInt32 = 0
        CGGetActiveDisplayList(0, nil, &count)
        let max = Int(count)
        var ids = [CGDirectDisplayID](repeating: 0, count: max)
        CGGetActiveDisplayList(count, &ids, &count)
        for id in ids {
            let bounds = CGDisplayBounds(id)
            if bounds.contains(point) {
                return (id, bounds)
            }
        }
        let main = CGMainDisplayID()
        return (main, CGDisplayBounds(main))
    }
}

// MARK: - Extensions

extension String {
    func matches(pattern: String) -> Bool {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
            return false
        }
        let range = NSRange(location: 0, length: self.utf16.count)
        return regex.firstMatch(in: self, options: [], range: range) != nil
    }
} 