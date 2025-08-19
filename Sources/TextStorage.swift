import Foundation
import QuartzCore

// Enhanced content logging with intelligent compression and semantic analysis
actor TextStorage {
    private var contentMap: [String: ContentEntry] = [:]
    private var semanticClusters: [String: SemanticCluster] = [:]
    private var pendingWrites: [ContentEntry] = []
    private var lastFlushTime: TimeInterval = 0
    private let flushInterval: TimeInterval = 5.0
    private var fileHandle: FileHandle?
    private let fileURL: URL
    private let startTime: Date = Date()
    private var groupBuffer: [String: Set<String>] = [:] // key: app|window|url -> unique texts
    private var alreadyLoggedPerGroup: [String: Set<String>] = [:] // normalized text keys seen per group across flushes

    // NEW: Semantic clustering for better compression
    struct SemanticCluster {
        let theme: String
        let representative: String  // Best example of this cluster
        let variants: [String]      // Similar content
        let frequency: Int
        let lastSeen: TimeInterval
        
        var compressionRatio: Float {
            return Float(representative.count) / Float(variants.joined().count)
        }
    }

    struct ContentEntry {
        let id: String
        let text: String
        let firstSeen: TimeInterval
        var lastSeen: TimeInterval
        var viewCount: Int
        let category: ContentCategory
        let importance: ImportanceLevel  // NEW: Importance scoring
        let semanticSignature: String    // NEW: For semantic deduplication
        let app: String?
        let window: String?
        let url: String?
        
        // NEW: Importance levels for intelligent filtering
        enum ImportanceLevel: String {
            case critical = "c"    // User-generated content, emails, names
            case high = "h"        // Unique URLs, important data
            case medium = "m"      // Common UI elements with context
            case low = "l"         // Repetitive UI, numbers
            case noise = "n"       // Debug info, coordinates
            
            var priority: Int {
                switch self {
                case .critical: return 3
                case .high: return 2
                case .medium: return 1
                case .low: return 0
                case .noise: return -1
                }
            }
            
            var multiplier: Float {
                switch self {
                case .critical: return 1.5
                case .high: return 1.2
                case .medium: return 1.0
                case .low: return 0.8
                case .noise: return 0.5
                }
            }
        }
        
        func toGroupKey() -> String {
            return "\(app ?? "Unknown")|\(window ?? "Unknown")|\(url ?? "")"
        }
    }
    
    enum ContentCategory: String {
        case email = "email"
        case url = "url" 
        case code = "code"
        case document = "doc"
        case ui = "ui"
        case number = "num"
        case text = "txt"
        case filename = "file"
        case name = "name"      // NEW: Person names
        case date = "date"      // NEW: Dates and times
        case other = "other"
        
        var shortCode: String {
            switch self {
            case .email: return "e"
            case .url: return "u"
            case .code: return "c"
            case .document: return "d"
            case .ui: return "i"
            case .number: return "n"
            case .text: return "t"
            case .filename: return "f"
            case .name: return "nm"
            case .date: return "dt"
            case .other: return "o"
            }
        }
        
        static func categorize(_ text: String) -> ContentCategory {
            let clean = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
            
            // Enhanced categorization
            if isPersonName(clean) { return .name }
            if isDateTime(clean) { return .date }
            if isEmail(clean) { return .email }
            if isURL(clean) { return .url }
            if isCode(clean) { return .code }
            if isFilename(clean) { return .filename }
            if isNumber(clean) { return .number }
            if isUIElement(clean) { return .ui }
            
            return clean.count > 15 ? .text : .other
        }
        
        // NEW: Enhanced detection methods
        private static func isPersonName(_ text: String) -> Bool {
            let words = text.components(separatedBy: .whitespaces)
            return words.count == 2 && 
                   words.allSatisfy { $0.count > 1 && $0.first?.isUppercase == true } &&
                   text.count < 50
        }
        
        private static func isDateTime(_ text: String) -> Bool {
            return text.contains(":") && (text.contains("AM") || text.contains("PM")) ||
                   text.contains("/") && text.count < 20 ||
                   text.contains("day") || text.contains("time")
        }
        
        private static func isEmail(_ text: String) -> Bool {
            return text.contains("@") && text.contains(".") && text.count < 100 && text.count > 5
        }
        
        private static func isURL(_ text: String) -> Bool {
            return text.hasPrefix("http") || text.hasPrefix("www.") || text.contains("://")
        }
        
        private static func isCode(_ text: String) -> Bool {
            let codeKeywords = ["func ", "import ", "class ", "def ", "async ", "await ", 
                               "{", "=>", "&&", "let ", "var ", "const "]
            return codeKeywords.contains { text.contains($0) }
        }
        
        private static func isFilename(_ text: String) -> Bool {
            let extensions = [".swift", ".js", ".py", ".json", ".txt", ".md", ".html", ".css"]
            return extensions.contains { text.contains($0) }
        }
        
        private static func isNumber(_ text: String) -> Bool {
            return text.allSatisfy { $0.isNumber || $0 == "." || $0 == "," || $0 == "-" } && 
                   text.count > 2
        }
        
        private static func isUIElement(_ text: String) -> Bool {
            let uiKeywords = ["button", "click", "menu", "save", "cancel", "ok", "submit"]
            return uiKeywords.contains { text.contains($0) } || text.count < 10
        }
    }
    
    // NEW: Calculate importance for intelligent filtering
    private func calculateImportance(_ text: String, category: ContentCategory) -> ContentEntry.ImportanceLevel {
        let length = text.count
        
        switch category {
        case .email, .name:
            return .critical  // Always keep emails and names
        case .url where length > 20:
            return .high      // Keep substantial URLs
        case .code, .document:
            return length > 50 ? .high : .medium
        case .text:
            return length > 30 ? .medium : .low
        case .ui:
            return .low       // UI elements are less important
        case .number:
            return length > 10 ? .medium : .noise
        default:
            return length > 20 ? .medium : .low
        }
    }
    
    // NEW: Generate semantic signature for better deduplication
    private func generateSemanticSignature(_ text: String) -> String {
        // Simple semantic signature based on key words and structure
        let words = text.lowercased()
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { $0.count > 3 }
            .sorted()
            .prefix(3)
        
        return words.joined(separator: "_")
    }

    init(filename: String = "content.jsonl") {
        let dir = FileManager.default.currentDirectoryPath
        fileURL = URL(fileURLWithPath: dir).appendingPathComponent(filename)
    }
    
    func ensureLogFileSetup() async {
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            FileManager.default.createFile(atPath: fileURL.path, contents: nil)
        }
    }

    func store(blocks: [TextBlock]) async {
        await ensureLogFileSetup()
        let now = Date().timeIntervalSince1970
        var hasNewContent = false
        
        for block in blocks {
            let text = cleanText(block.text)
            guard isContentMeaningful(text) else { continue }
            
            let normalizedKey = normalizeForDeduplication(text)
            let category = ContentCategory.categorize(text)
            let importance = calculateImportance(text, category: category)
            let semanticSignature = generateSemanticSignature(text)
            
            if var existing = contentMap[normalizedKey] {
                // Update existing entry
                existing.lastSeen = now
                existing.viewCount += 1
                contentMap[normalizedKey] = existing
                hasNewContent = true
            } else {
                // Create new entry
                let entry = ContentEntry(
                    id: generateContentID(text),
                    text: text,
                    firstSeen: now,
                    lastSeen: now,
                    viewCount: 1,
                    category: category,
                    importance: importance,
                    semanticSignature: semanticSignature,
                    app: block.sourceApp,
                    window: block.windowTitle,
                    url: block.sourceURL
                )
                contentMap[normalizedKey] = entry
                pendingWrites.append(entry)
                hasNewContent = true
            }
        }
        // Update group buffer for new entries
        for entry in pendingWrites {
            let key = entry.toGroupKey()
            let normalized = normalizeForDeduplication(entry.text)
            var seen = alreadyLoggedPerGroup[key] ?? Set<String>()
            // Skip if we've already logged this normalized text for the group
            if seen.contains(normalized) { continue }
            seen.insert(normalized)
            alreadyLoggedPerGroup[key] = seen
            // Coalesce near-duplicates within this flush
            var set = groupBuffer[key] ?? Set<String>()
            insertCoalesced(entry.text, into: &set)
            groupBuffer[key] = set
        }
        
        // Flush if needed
        if hasNewContent && (now - lastFlushTime > flushInterval || pendingWrites.count > 20) {
            await flushToDisk()
            lastFlushTime = now
        }
    }
    
    private func cleanText(_ text: String) -> String {
        return text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "\\n+", with: " ", options: .regularExpression)
    }
    
    private func isContentMeaningful(_ text: String) -> Bool {
        // Filter out noise
        guard text.count >= 3 else { return false }
        
        // Skip pure coordinate/debug text
        if text.allSatisfy({ $0.isNumber || $0 == "." || $0 == "," || $0 == "-" || $0 == " " || $0 == "(" || $0 == ")" }) {
            return false
        }
        
        // Skip very repetitive patterns
        if text.count > 10 && Set(text).count < 3 {
            return false
        }
        
        // Skip obvious debug/system text patterns
        let skipPatterns = [
            "94275", "94276", "94277", "94278", "94279", "94280", // Debug timestamps
            "@(", "e-", "999999", "000000", // Coordinate patterns
            "[94", "CGRect", "CGSize", "CGPoint", // Debug output
            "CGFloat", "TimeInterval", "CACurrentMediaTime", // System types
            ".0)", ".00)", // Coordinate endings
        ]
        
        for pattern in skipPatterns {
            if text.contains(pattern) {
                return false
            }
        }
        
        // Skip single characters or very short meaningless strings
        if text.count < 3 || (text.count < 6 && text.allSatisfy({ $0.isNumber || $0.isPunctuation })) {
            return false
        }
        
        return true
    }
    
    private func normalizeForDeduplication(_ text: String) -> String {
        return text
            .lowercased()
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
    
    private func generateContentID(_ text: String) -> String {
        let hash = text.hash
        return String(format: "%08x", abs(hash))
    }
    
    private func flushToDisk() async {
        guard !pendingWrites.isEmpty else { return }
        // Build grouped JSONL lines per app/window/url with unique texts
        var lines: [String] = []
        for (key, textsSet) in groupBuffer {
            let parts = key.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
            let app = parts.count > 0 ? parts[0] : "Unknown"
            let window = parts.count > 1 ? parts[1] : "Unknown"
            let url = parts.count > 2 && !parts[2].isEmpty ? parts[2] : nil
            let texts = Array(textsSet)
            var obj: [String: Any] = [
                "app": app,
                "window": window,
                "texts": texts
            ]
            if let url = url { obj["url"] = url }
            if let data = try? JSONSerialization.data(withJSONObject: obj, options: []),
               let str = String(data: data, encoding: .utf8) {
                lines.append(str + "\n")
            }
        }
        let linesToWrite = lines.joined()
        groupBuffer.removeAll()
        pendingWrites.removeAll()
        // Write efficiently
        if #available(macOS 10.15.4, *) {
            do {
                if fileHandle == nil {
                    fileHandle = try FileHandle(forWritingTo: fileURL)
                }
                try fileHandle?.seekToEnd()
                if let data = linesToWrite.data(using: .utf8) {
                    try fileHandle?.write(contentsOf: data)
                }
            } catch {
                await fallbackWrite(linesToWrite)
            }
        } else {
            await fallbackWrite(linesToWrite)
        }
    }
    
    private func fallbackWrite(_ content: String) async {
        let existing = (try? String(contentsOf: fileURL)) ?? ""
        try? (existing + content).write(to: fileURL, atomically: false, encoding: .utf8)
    }
    
    func finalFlush() async {
        await flushToDisk()
        if #available(macOS 10.15, *) {
            try? fileHandle?.close()
        }
        fileHandle = nil
    }
    
    func getStats() -> (uniqueContents: Int, pendingWrites: Int, totalViews: Int) {
        let totalViews = contentMap.values.reduce(0) { $0 + $1.viewCount }
        return (contentMap.count, pendingWrites.count, totalViews)
    }
    
    // NEW: Intelligent content retrieval with filtering and compression
    func getRelevantContent(
        forContext context: String, 
        maxItems: Int = 15,
        minImportance: ContentEntry.ImportanceLevel = .medium
    ) async -> [String] {
        
        let entries = Array(contentMap.values)
        let contextWords = extractKeywords(from: context)
        
        print("🔍 DEBUG: Storage contains \(entries.count) total entries")
        print("🔍 DEBUG: Looking for context: '\(context)' with keywords: \(contextWords)")
        
        // Score entries by relevance and importance
        let scoredEntries = entries.compactMap { entry -> (entry: ContentEntry, score: Float)? in
            guard entry.importance.priority >= minImportance.priority else { return nil }
            
            let relevanceScore = calculateRelevanceScore(entry: entry, contextWords: contextWords)
            let importanceMultiplier = entry.importance.multiplier
            let recencyBonus = calculateRecencyBonus(entry: entry)
            
            let totalScore = relevanceScore * importanceMultiplier + recencyBonus
            return (entry, totalScore)
        }
        
        // Sort by score and take top results
        let topEntries = scoredEntries
            .sorted { $0.score > $1.score }
            .prefix(maxItems)
            .map { $0.entry.text }
        
        print("📊 Filtered content: \(entries.count) → \(topEntries.count) items (min: \(minImportance))")
        print("🔍 DEBUG: Top 3 entries by score:")
        for (i, scoredEntry) in scoredEntries.sorted(by: { $0.score > $1.score }).prefix(3).enumerated() {
            print("   \(i+1). Score: \(scoredEntry.score), Text: '\(scoredEntry.entry.text.prefix(50))...'")
        }
        
        return topEntries
    }
    
    // NEW: Get content by specific type (for targeted completions)
    func getContentByType(
        _ category: ContentCategory,
        maxItems: Int = 10
    ) async -> [String] {
        
        let entries = contentMap.values.filter { $0.category == category }
        return entries
            .sorted { $0.lastSeen > $1.lastSeen }  // Most recent first
            .prefix(maxItems)
            .map { $0.text }
    }
    
    // NEW: Get compressed semantic summary
    func getSemanticSummary(maxChars: Int = 1000) async -> String {
        let clusters = buildSemanticClusters()
        
        var summary: [String] = []
        var charCount = 0
        
        for cluster in clusters.sorted(by: { $0.frequency > $1.frequency }) {
            let item = "\(cluster.theme): \(cluster.representative)"
            if charCount + item.count <= maxChars {
                summary.append(item)
                charCount += item.count
            } else {
                break
            }
        }
        
        return summary.joined(separator: " | ")
    }
    
    // NEW: Build semantic clusters for compression
    private func buildSemanticClusters() -> [SemanticCluster] {
        var clusters: [String: [ContentEntry]] = [:]
        
        // Group by semantic signature
        for entry in contentMap.values {
            let signature = entry.semanticSignature
            clusters[signature, default: []].append(entry)
        }
        
        // Convert to semantic clusters
        return clusters.compactMap { (signature, entries) in
            guard entries.count > 1 else { return nil }  // Only cluster duplicates
            
            let representative = entries.max { a, b in
                a.importance.priority < b.importance.priority || 
                (a.importance.priority == b.importance.priority && a.viewCount < b.viewCount)
            }?.text ?? entries.first?.text ?? ""
            
            return SemanticCluster(
                theme: signature,
                representative: representative,
                variants: entries.map { $0.text },
                frequency: entries.count,
                lastSeen: entries.map { $0.lastSeen }.max() ?? 0
            )
        }
    }
    
    // Helper methods for relevance scoring
    private func extractKeywords(from text: String) -> Set<String> {
        return Set(text.lowercased()
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { $0.count > 3 }
            .prefix(10))
    }
    
    private func calculateRelevanceScore(entry: ContentEntry, contextWords: Set<String>) -> Float {
        let entryWords = Set(entry.text.lowercased()
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { $0.count > 3 })
        
        let intersection = contextWords.intersection(entryWords)
        let union = contextWords.union(entryWords)
        
        return union.isEmpty ? 0 : Float(intersection.count) / Float(union.count)
    }
    
    private func calculateRecencyBonus(entry: ContentEntry) -> Float {
        let now = Date().timeIntervalSince1970
        let ageInHours = (now - entry.lastSeen) / 3600
        
        // Exponential decay: more recent = higher bonus
        return max(0, 1.0 - Float(ageInHours) / 24.0)  // Full bonus within 24 hours
    }

    // NEW: Get ALL recent content without filtering (for when we need maximum context)
    func getRecentEverything(maxItems: Int = 100) async -> [String] {
        let entries = Array(contentMap.values)
        
        print("🔍 DEBUG: Getting EVERYTHING from storage (\(entries.count) total entries)")
        
        // Sort by most recent and take everything meaningful
        let recentEntries = entries
            .filter { $0.text.count > 2 }  // Very minimal filtering
            .sorted { $0.lastSeen > $1.lastSeen }  // Most recent first
            .prefix(maxItems)
            .map { $0.text }
        
        print("🔍 DEBUG: Returning \(recentEntries.count) items from storage")
        
        return Array(recentEntries)
    }

    // NEW: Log the full prompt as a single JSONL line in the same schema
    func logPrompt(app: String = "AI_ASSISTANT", window: String = "PROMPT", url: String? = nil, prompt: String) async {
        await ensureLogFileSetup()
        var obj: [String: Any] = [
            "app": app,
            "window": window,
            "texts": [prompt]
        ]
        if let url = url { obj["url"] = url }
        guard let data = try? JSONSerialization.data(withJSONObject: obj, options: []),
              let line = String(data: data, encoding: .utf8) else { return }
        let toWrite = line + "\n"
        if #available(macOS 10.15.4, *) {
            do {
                if fileHandle == nil {
                    fileHandle = try FileHandle(forWritingTo: fileURL)
                }
                try fileHandle?.seekToEnd()
                if let bytes = toWrite.data(using: .utf8) {
                    try fileHandle?.write(contentsOf: bytes)
                }
            } catch {
                await fallbackWrite(toWrite)
            }
        } else {
            await fallbackWrite(toWrite)
        }
    }

    // Insert text into a set, coalescing incremental substring variants
    private func insertCoalesced(_ text: String, into set: inout Set<String>) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        // If an existing string already contains this (likely incremental typing), skip
        for existing in set {
            if existing.count >= trimmed.count,
               existing.lowercased().contains(trimmed.lowercased()),
               existing.count - trimmed.count <= 30 {
                return
            }
        }
        // If new is a longer version of an existing, replace the shorter one
        let toRemove = set.filter { candidate in
            trimmed.count >= candidate.count &&
            trimmed.lowercased().contains(candidate.lowercased()) &&
            trimmed.count - candidate.count <= 30
        }
        for r in toRemove { set.remove(r) }
        set.insert(trimmed)
    }
} 