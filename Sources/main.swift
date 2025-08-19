import Foundation
import CoreGraphics
import ScreenCaptureKit
import Vision
import QuartzCore
import AppKit
import ApplicationServices

// MVP: Complete AI Writing Assistant with CMD+G → UI → Paste flow

struct CapturedFrame {
    let cgImage: CGImage
    let timestamp: TimeInterval
    let displayID: CGDirectDisplayID
    let dirtyRects: [CGRect]
}

@available(macOS 12.3, *)
protocol CaptureServiceDelegate: AnyObject {
    @available(macOS 12.3, *)
    func captureService(_ service: CaptureService, didCapture frame: CapturedFrame)
}

@available(macOS 12.3, *)
class MainPipeline: NSObject, CaptureServiceDelegate, TextOutputDelegate, HotkeyServiceDelegate, @unchecked Sendable {
    let captureService = CaptureService()
    let ocrService = OcrService()
    let storage = TextStorage()
    let hotkeyService = HotkeyService()
    let contextAnalyzer: ContextAnalyzer
    let llmService = LLMService()
    let pasteService = PasteService()
    private var thinkingHUD: ThinkingHUD?
    
    var lastFrameTime: TimeInterval = 0
    private var statsTimer: Timer?

    override init() {
        contextAnalyzer = ContextAnalyzer(storage: storage, captureService: captureService)
        super.init()
        captureService.delegate = self
        hotkeyService.delegate = self
        setupStatsTimer()
    }
    
    private func setupStatsTimer() {
        statsTimer = Timer.scheduledTimer(withTimeInterval: 60.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            Task {
                let stats = await self.storage.getStats()
                print("📊 Content Stats: \(stats.uniqueContents) unique contents, \(stats.totalViews) total views")
            }
        }
    }

    func start() async {
        print("🚀 Starting PasteRecall AI Writing Assistant...")
        
        // Check permissions
        if !PasteService.checkPastePermissions() {
            print("⚠️ Input monitoring permissions required for text pasting")
        }
        
        let granted = CGPreflightScreenCaptureAccess()
        if !granted {
            print("Requesting screen recording permission...")
            let _ = CGRequestScreenCaptureAccess()
            print("Please grant screen recording permission and re-run the app.")
            exit(1)
        }
        
        do {
            try await captureService.start()
            print("📝 Logging content to ./content.jsonl")
            print("🔥 CMD+J hotkey ready for smart completion assistance!")
            print("✨ Demo flow: CMD+J → Context Analysis → LLM → Auto-Complete Data")
        } catch {
            print("Failed to start capture: \(error)")
            exit(1)
        }
    }

    func captureService(_ service: CaptureService, didCapture frame: CapturedFrame) {
        ocrService.recognize(cgImage: frame.cgImage) { [weak self] ocrBlocks in
            guard let self = self else { return }
            let appName = NSWorkspace.shared.frontmostApplication?.localizedName
            let windowTitle: String? = {
                let system = AXUIElementCreateSystemWide()
                var focusedRef: CFTypeRef?
                AXUIElementCopyAttributeValue(system, kAXFocusedWindowAttribute as CFString, &focusedRef)
                var titleRef: CFTypeRef?
                if let f = focusedRef {
                    let focusedWindow: AXUIElement = unsafeBitCast(f, to: AXUIElement.self)
                    AXUIElementCopyAttributeValue(focusedWindow, kAXTitleAttribute as CFString, &titleRef)
                }
                return titleRef as? String
            }()
            let urlString: String? = {
                let system = AXUIElementCreateSystemWide()
                var focusedElRef: CFTypeRef?
                AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focusedElRef)
                var urlRef: CFTypeRef?
                if let elRef = focusedElRef {
                    let el: AXUIElement = unsafeBitCast(elRef, to: AXUIElement.self)
                    AXUIElementCopyAttributeValue(el, "AXURL" as CFString, &urlRef)
                }
                return (urlRef as? URL)?.absoluteString
            }()
            let textBlocks = normalize(blocks: ocrBlocks,
                                        in: CGSize(width: frame.cgImage.width, height: frame.cgImage.height),
                                        app: appName,
                                        title: windowTitle,
                                        url: urlString)
            self.didExtractTextBlocks(textBlocks)
        }
    }

    func didExtractTextBlocks(_ blocks: [TextBlock]) {
        let filtered = blocks.filter { $0.confidence > 0.6 }
        guard !filtered.isEmpty else { return }
        // Skip logging if current foreground app is a terminal to avoid self-logging
        let activeAppName = NSWorkspace.shared.frontmostApplication?.localizedName?.lowercased() ?? ""
        let isTerminal = ["terminal", "iterm", "cursor"].contains { activeAppName.contains($0) }
        if isTerminal { return }
        
        // Store to file but don't log to console
        let storageRef = self.storage
        Task.detached { await storageRef.store(blocks: filtered) }
    }
    
    // MARK: - AI Writing Assistant (Complete Demo Flow)
    
    func hotkeyTriggered() {
        print("\n🚀 CMD+J pressed! Starting smart completion assistance...")
        Task {
            await handleCompleteAIFlow()
        }
    }
    
    private func handleCompleteAIFlow() async {
        // Show tiny HUD near cursor immediately (ensure created on main actor)
        let cursor = CGEvent(source: nil)?.location ?? .zero
        let hud = await ensureHUD()
        await hud.show(at: cursor)
        // Step 1: Analyze current context
        print("🔍 Step 1: Analyzing current context...")
        let analysis = await contextAnalyzer.analyzeCurrentContext()
        
        print("🧠 Context: App=\(analysis.activeApp), Confidence=\(analysis.confidence)")
        print("📄 Screen preview: \(String(analysis.currentScreen.prefix(80)))...")
        
        // Step 2: Build LLM prompt
        print("🤖 Step 2: Building LLM prompt...")
        let prompt = contextAnalyzer.generateLLMPrompt(from: analysis)
        
        // Step 3: Get AI suggestions
        print("💭 Step 3: Getting AI suggestions...")
        let generationStartTime = Date()
        let suggestions = await llmService.getSuggestions(for: prompt)
        let generationElapsed = Date().timeIntervalSince(generationStartTime)
        print(String(format: "⏱️ Generation took %.2f s", generationElapsed))
        
        guard !suggestions.isEmpty else {
            print("❌ No suggestions received")
            if let hud = thinkingHUD { await hud.hide() }
            return
        }
        
        // Step 4: Show GPT responses in terminal
        print("\n✨ GPT-4o-mini Responses:")
        for (index, suggestion) in suggestions.enumerated() {
            print("  \(index + 1). [\(suggestion.type.uppercased())] \(suggestion.text)")
            print("      Confidence: \(suggestion.confidence)")
        }
        
        // Step 5: Smart suggestion selection based on context
        let smartSuggestion = selectBestSuggestion(suggestions: suggestions, analysis: analysis)
        
        guard let selectedSuggestion = smartSuggestion else {
            print("❌ No suggestions available to paste")
            if let hud = thinkingHUD { await hud.hide() }
            return
        }
        
        print("\n Auto-pasting smart suggestion: [\(selectedSuggestion.type.uppercased())] \(String(selectedSuggestion.text.prefix(50)))...")

        await handleAutoTextPasting(suggestion: selectedSuggestion)
        if let hud = thinkingHUD { await hud.hide() }
    }
    
    private func handleAutoTextPasting(suggestion: LLMSuggestion) async {
        print("📝 Step 5: Auto-pasting text...")
        
        let success = await pasteService.pasteText(suggestion.text)
        
        if success {
            print("✅ Text pasted successfully!")
            print("📖 Learning from auto-paste for future improvements...")
            
            // Store the successful selection for learning
            await storeSuccessfulSelection(suggestion)
        } else {
            print("❌ Failed to paste text - trying alternative method...")
            
            // Fallback: Copy to clipboard for manual paste
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(suggestion.text, forType: .string)
            print("📋 Text copied to clipboard - press CMD+V to paste manually")
        }
        
        print("🎉 AI assistance complete!\n")
    }
    
    private func storeSuccessfulSelection(_ suggestion: LLMSuggestion) async {
        // Create a learning entry
        let learningBlock = TextBlock(
            text: "LEARNED_SELECTION: \(suggestion.type) - \(suggestion.text)",
            rect: CGRect.zero,
            sourceApp: "AI_ASSISTANT",
            windowTitle: "Learning",
            sourceURL: nil,
            ts: Date().timeIntervalSince1970,
            confidence: suggestion.confidence
        )
        
        await storage.store(blocks: [learningBlock])
    }
    
    private func selectBestSuggestion(suggestions: [LLMSuggestion], analysis: ContextAnalysis) -> LLMSuggestion? {
        guard !suggestions.isEmpty else { return nil }
        
        let userText = analysis.currentScreen.lowercased()
        let recentContext = analysis.recentContent.joined(separator: " ").lowercased()
        
        print("🧠 Enhanced suggestion selection:")
        print("   App: \(analysis.activeApp)")
        print("   Screen: '\(userText.prefix(50))...'")
        print("   Available suggestions: \(suggestions.count)")
        
        // Calculate CONTEXT RELEVANCE score for each suggestion
        let scoredSuggestions = suggestions.map { suggestion -> (suggestion: LLMSuggestion, score: Float) in
            var score: Float = 0.0  // Start from zero, build up based on relevance
            
            let suggestionText = suggestion.text.lowercased()
            
            // 🎯 CONTEXT RELEVANCE SCORING (most important)
            let contextScore = calculateContextRelevance(
                suggestionText: suggestionText,
                userText: userText,
                recentContext: recentContext
            )
            score += contextScore * 5.0  // Heavy weight on context relevance
            
            print("   📊 '\(suggestion.text.prefix(40))...' - Context: \(contextScore)")
            
            // 🔍 KEYWORD MATCHING (specific to what user is typing)
            let keywordScore = calculateKeywordMatch(suggestionText: suggestionText, userText: userText)
            score += keywordScore * 3.0
            
            // ⚡ RECENCY BOOST (prefer suggestions that match recent activity)
            let recencyScore = calculateRecencyRelevance(suggestionText: suggestionText, recentContext: recentContext)
            score += recencyScore * 2.0
            
            // 💪 CONFIDENCE (lowest priority)
            score += suggestion.confidence * 0.5  // Much lower weight
            
            // 📏 LENGTH APPROPRIATENESS 
            if suggestion.text.count < 3 || suggestion.text.count > 100 {
                score -= 2.0
            }
            
            return (suggestion, score)
        }
        
        // Sort by TOTAL RELEVANCE SCORE (not just confidence)
        let sortedSuggestions = scoredSuggestions.sorted { $0.score > $1.score }
        
        print("   🏆 Suggestion rankings by CONTEXT RELEVANCE:")
        for (i, scoredSuggestion) in sortedSuggestions.enumerated() {
            print("     \(i+1). Score: \(scoredSuggestion.score) - '\(scoredSuggestion.suggestion.text)'")
        }
        
        let bestSuggestion = sortedSuggestions.first?.suggestion
        
        if let selected = bestSuggestion {
            print("   ✅ SELECTED BY CONTEXT: '\(selected.text)' (total score: \(sortedSuggestions.first?.score ?? 0))")
        }
        
        return bestSuggestion
    }
    
    // NEW: Calculate how well suggestion matches the current context
    private func calculateContextRelevance(suggestionText: String, userText: String, recentContext: String) -> Float {
        var relevance: Float = 0.0
        
        // Extract key themes from user input
        let userKeywords = extractRelevantKeywords(from: userText)
        let suggestionKeywords = extractRelevantKeywords(from: suggestionText)
        let contextKeywords = extractRelevantKeywords(from: recentContext)
        
        // Score based on keyword overlap with recent context
        for keyword in suggestionKeywords {
            if contextKeywords.contains(keyword) {
                relevance += 1.0  // Suggestion matches recent activity
            }
        }
        
        // Score based on keyword overlap with user input
        for keyword in suggestionKeywords {
            if userKeywords.contains(keyword) {
                relevance += 1.5  // Suggestion matches what user is typing
            }
        }
        
        // Boost if suggestion semantically fits the user's sentence
        if suggestionText.contains("house") && userText.contains("house") {
            relevance += 2.0
        }
        if suggestionText.contains("company") && userText.contains("company") {
            relevance += 2.0
        }
        if suggestionText.contains("hacker") && userText.contains("hacker") {
            relevance += 2.0
        }
        
        return relevance
    }
    
    // NEW: Calculate keyword matching score
    private func calculateKeywordMatch(suggestionText: String, userText: String) -> Float {
        let userWords = Set(userText.components(separatedBy: .whitespacesAndNewlines))
        let suggestionWords = Set(suggestionText.components(separatedBy: .whitespacesAndNewlines))
        
        let intersection = userWords.intersection(suggestionWords)
        let union = userWords.union(suggestionWords)
        
        return union.isEmpty ? 0 : Float(intersection.count) / Float(union.count)
    }
    
    // NEW: Calculate how well suggestion matches recent activity
    private func calculateRecencyRelevance(suggestionText: String, recentContext: String) -> Float {
        let suggestionWords = suggestionText.components(separatedBy: .whitespacesAndNewlines)
            .filter { $0.count > 3 }
        
        var matches = 0
        for word in suggestionWords {
            if recentContext.contains(word.lowercased()) {
                matches += 1
            }
        }
        
        return Float(matches) / Float(max(suggestionWords.count, 1))
    }
    
    // NEW: Extract meaningful keywords (not common words)
    private func extractRelevantKeywords(from text: String) -> Set<String> {
        let commonWords = Set(["the", "and", "for", "are", "but", "not", "you", "all", "can", "had", "her", "was", "one", "our", "out", "day", "has", "his", "how", "its", "may", "new", "now", "old", "see", "two", "way", "who"])
        
        return Set(text.lowercased()
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { $0.count > 2 && !commonWords.contains($0) })
    }
    
    func shutdown() async {
        statsTimer?.invalidate()
        await self.storage.finalFlush()
        print("💾 Final flush completed")
    }

    // Ensure HUD is constructed on the main actor before first use
    private func ensureHUD() async -> ThinkingHUD {
        if let hud = thinkingHUD { return hud }
        return await MainActor.run { [weak self] in
            let hud = ThinkingHUD()
            self?.thinkingHUD = hud
            return hud
        }
    }
}

@available(macOS 12.3, *)
func mainAsync() async {
    let pipeline = MainPipeline()
    await pipeline.start()
    
    // Keep the process alive
    while true {
        try? await Task.sleep(nanoseconds: 60_000_000_000) // 60 seconds
    }
}

if #available(macOS 12.3, *) {
    Task {
        await mainAsync()
    }
    RunLoop.main.run()
} else {
    print("This app requires macOS 12.3 or newer.")
} 