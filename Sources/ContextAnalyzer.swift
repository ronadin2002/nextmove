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
    
    // Main function to analyze current context when CMD+G is pressed
    func analyzeCurrentContext() async -> ContextAnalysis {
        print("🔍 Analyzing current context...")
        
        // Get current active application
        let activeApp = getCurrentActiveApp()
        
        // Enhanced multi-step analysis
        let currentScreen = await captureCurrentContext()
        let layoutAnalysis = await analyzeLayoutAndStructure(activeApp: activeApp)
        let inputContext = await analyzeInputContext(screen: currentScreen, layout: layoutAnalysis)
        let semanticContext = await analyzeSemanticContext(input: inputContext, recent: await getRecentContent())
        
        // Get cursor position
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
        
        print("📊 Enhanced analysis complete:")
        print("   App: \(activeApp) (\(layoutAnalysis.windowStructure.appType))")
        print("   Input: \(inputContext.fieldType) - \(inputContext.completionContext)")
        print("   Intent: \(semanticContext.intentPrediction)")
        print("   Relevant history: \(semanticContext.relevantHistorySnippets.count) items")
        
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
            
            // Take MAXIMUM recent entries (last 1000 raw JSONL lines for maximum context)
            let maxRecentLines = 1000
            let mostRecentLines = Array(lines.suffix(maxRecentLines))
            print("📚 Reading the absolute last \(mostRecentLines.count) RAW JSONL entries (requested: \(maxRecentLines))")
            
            // Show file statistics
            let fileSize = (try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.size] as? Int64) ?? 0
            print("📊 File stats: \(fileSize) bytes, \(lines.count) total entries, sending \(mostRecentLines.count) to LLM")
            
            print("🔍 DEBUG: Last 15 RAW JSONL lines from file (NEWEST FIRST for LLM attention):")
            for (i, line) in mostRecentLines.suffix(15).enumerated() {
                print("   \(i+1). \(line)")
            }
            
            // Calculate approximate prompt size
            let totalChars = mostRecentLines.joined(separator: "\n").count
            print("📏 Total context characters being sent: \(totalChars)")
            
            // CRITICAL: Return logs in REVERSE order so NEWEST logs appear at BOTTOM of LLM prompt
            // This ensures the most recent activity gets the most attention from the LLM
            let reversedLines = Array(mostRecentLines.reversed())
            print("✅ Logs will be presented to LLM with NEWEST at the bottom (most prominent position)")
            
            // Show order confirmation - first few (oldest) and last few (newest) entries
            if reversedLines.count > 10 {
                print("📋 LLM Context Order Preview:")
                print("   OLDEST (top of context): \(reversedLines.prefix(3).map { String($0.prefix(50)) }.joined(separator: " | "))")
                print("   NEWEST (bottom of context): \(reversedLines.suffix(3).map { String($0.prefix(50)) }.joined(separator: " | "))")
            }
            
            return reversedLines
            
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
        
        // Just return everything - no filtering at all
        return Array(recent.prefix(100))  // Only limit by count to avoid huge prompts
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
        // Strategy: Aggressively find actual user content, ignore ALL UI AND recently pasted content
        
        print("🔍 Raw captured text for cursor detection:")
        print("   \(text)")
        
        let lines = text.components(separatedBy: "\n")
        var candidateLines: [(index: Int, line: String, score: Int)] = []
        
        // Score each line very aggressively for user content
        for (lineIndex, line) in lines.enumerated() {
            let trimmedLine = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmedLine.count > 3 else { continue }
            
            var score = 0
            
            // NEW: MASSIVE penalty for recently pasted content to avoid feedback loops
            for pastedContent in recentlyPastedContent {
                if trimmedLine.contains(pastedContent) || pastedContent.contains(trimmedLine) {
                    score -= 5000  // Huge penalty to avoid feedback
                    print("   🚫 FEEDBACK DETECTED: Line contains recently pasted content")
                }
            }
            
            // NEW: MASSIVE penalty for obvious repetitive patterns
            if containsRepetitivePattern(trimmedLine) {
                score -= 3000
                print("   🚫 REPETITIVE PATTERN: '\(trimmedLine)'")
            }
            
            // MASSIVE bonus for lines that look like user typing
            if trimmedLine.contains("here are") || trimmedLine.contains("some vcs") || 
               trimmedLine.contains("urls:") || trimmedLine.contains("meeting") ||
               trimmedLine.contains("from what i know") {
                score += 1000 // Huge bonus for obvious user content
                print("   🎯 Found user content candidate: '\(trimmedLine)' (score: \(score))")
            }
            
            // High score for substantial content with proper sentence structure
            if trimmedLine.contains(" ") && trimmedLine.count > 10 {
                score += trimmedLine.count * 2
            }
            
            // MASSIVE penalties for obvious UI/system text
            let uiKeywords = [
                "Subject", "Recipients", "Order ID", "Receipt", "Document", "Account", 
                "Apple", "Update", "Demo Day", "Contact Information", "reviews", "Message",
                "New Message", "Promotions", "Updates", "Social", "Palmer", "Console",
                "Founded", "$ Founded", "Templates", "Blog", "Courses", "Work", "Contact",
                "Chrome", "download", "available"  // NEW: Add Chrome-related terms
            ]
            
            for keyword in uiKeywords {
                if trimmedLine.contains(keyword) {
                    score -= 2000 // Huge penalty for UI
                }
            }
            
            // Penalty for lines that are clearly UI (short, lots of symbols, etc.)
            if trimmedLine.count < 15 && (trimmedLine.contains("•") || trimmedLine.contains("@") || trimmedLine.contains("$")) {
                score -= 500
            }
            
            // Bonus for lines ending without punctuation (incomplete user typing)
            if !trimmedLine.hasSuffix(".") && !trimmedLine.hasSuffix("!") && !trimmedLine.hasSuffix("?") && 
               !trimmedLine.contains("Order ID") && !trimmedLine.contains("Account:") {
                score += 200
            }
            
            candidateLines.append((index: lineIndex, line: trimmedLine, score: score))
        }
        
        // Sort by score and show top candidates
        let sortedCandidates = candidateLines.sorted { $0.score > $1.score }
        print("🏆 Top cursor candidates:")
        for (i, candidate) in sortedCandidates.prefix(3).enumerated() {
            print("   \(i+1). '\(candidate.line)' (score: \(candidate.score))")
        }
        
        // Find the best candidate line (highest score)
        if let best = sortedCandidates.first, best.score > -1000 {  // Raised threshold
            print("🎯 SELECTED cursor line: '\(best.line)' (score: \(best.score))")
            
            // Add cursor marker at the end of the best candidate line
            let lineWithCursor = "\(best.line)____"
            
            return "TYPING: \(lineWithCursor)"
        }
        
        print("⚠️ No good cursor candidates found (avoiding feedback loop), using clean fallback")
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
        // Prepare comprehensive recent activity context
        let recentContext = analysis.recentContent.isEmpty ? 
            "No recent activity logged" : 
            analysis.recentContent.joined(separator: "\n")
        
        // Create completion-focused prompt
        let prompt = """
        You are a smart completion assistant. Complete the user's text using ACTUAL phrases and content from their recent activity.

        CURRENT APPLICATION: \(analysis.activeApp)
        
        WHAT USER IS CURRENTLY LOOKING AT (with cursor position marked as ____):
        \(analysis.currentScreen.isEmpty ? "No visible text detected" : analysis.currentScreen)
        
        RAW USER ACTIVITY LOGS (JSONL format - each line is {"t":"text content","c":"category","i":"importance","v":"views","m":"minutes"}):
        \(recentContext)

        CRITICAL: The ____ marker shows EXACTLY where the user's cursor is positioned. Complete the text at that exact position.

        COMPLETION RULES:
        1. Look for the ____ marker - this shows where the user needs completion
        2. Use the "t" field from the JSONL logs above - that's what the user was actually reading/typing
        3. If you see "john.sm____" → complete with actual email from recent activity logs
        4. If you see "meeting at ____" → complete with actual times from recent activity logs  
        5. If you see "The oldest man is ____" → complete with actual names from recent activity logs
        6. Use COMPLETE phrases and sentences from the "t" fields in the logs above
        7. The completion should flow naturally from the text before the ____ marker

        EXAMPLES:
        - User typed "The oldest man is ____" + logs show "João Marinho Neto, who is 112 years old" → suggest "João Marinho Neto"
        - User typed "meeting at ____" + logs show "3:30 PM Conference Room B" → suggest "3:30 PM"
        - User typed "hacker houses: ____" + logs show "AGI House, Crypto Castle" → suggest "AGI House, Crypto Castle"

        RESPOND WITH JSON using ACTUAL content from the logs above:
        {
          "suggestions": [
            {"text": "actual completion from recent activity logs", "confidence": 0.9, "type": "completion"},
            {"text": "alternative actual content from recent logs", "confidence": 0.8, "type": "alternative"},
            {"text": "extended actual content from recent logs", "confidence": 0.7, "type": "extended"}
          ]
        }
        """
        
        // Log the complete prompt being sent to OpenAI
        print("\n" + String(repeating: "=", count: 80))
        print("🤖 RAW JSONL PROMPT TO OPENAI:")
        print(String(repeating: "=", count: 80))
        print(prompt)
        print(String(repeating: "=", count: 80))
        print("📏 Prompt length: \(prompt.count) characters")
        print("📊 Recent JSONL entries: \(analysis.recentContent.count)")
        print(String(repeating: "=", count: 80) + "\n")
        
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