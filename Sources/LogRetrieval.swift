import Foundation

/// Lightweight helper to retrieve relevant pieces from `content.jsonl` without dragging in heavy search libs.
/// NOTE: *Not* thread-safe; we call it only from `ContextAnalyzer`’s serial workflow.
struct LogRetrieval {
    private var logLines: [String] = []   // newest last
    private(set) var logPath: String
    
    init(logPath: String) {
        self.logPath = logPath
        reload(logPath: logPath)
    }
    
    /// Reload the in-memory buffer if file changed on disk.
    mutating func reload(logPath: String? = nil) {
        if let newPath = logPath { self.logPath = newPath }
        guard let data = try? String(contentsOfFile: self.logPath) else {
            print("⚠️ LogRetrieval: failed to read \(self.logPath)")
            self.logLines = []
            return
        }
        // Keep newest last; drop empty lines
        self.logLines = data.split(separator: "\n").map(String.init)
    }
    
    /// Return the `k` newest raw JSONL lines (already newest last).
    func latestLines(_ k: Int) -> [String] {
        guard !logLines.isEmpty else { return [] }
        return Array(logLines.suffix(k))
    }
    
    /// VERY naive relevance: counts how many words in `query` (case-insensitive, ≥3 chars) appear in a log line.
    /// Returns up to `maxResults` lines (newest last) sorted by that score.
    func topRelevant(to query: String, maxResults: Int) -> [String] {
        let keywords = Set(query.lowercased().split{ !$0.isLetter }.map(String.init).filter{ $0.count >= 3 })
        guard !keywords.isEmpty else { return latestLines(maxResults) }
        
        let scored: [(String, Int, Int)] = logLines.enumerated().map { (idx, line) in
            let lower = line.lowercased()
            let hits = keywords.filter { lower.contains($0) }.count
            return (line, hits, idx) // keep original index so we can sort stable / by recency
        }
        .filter { $0.1 > 0 } // need at least one hit
        
        let sorted = scored.sorted { a, b in
            if a.1 != b.1 { return a.1 > b.1 } // more keyword hits first
            return a.2 > b.2                // otherwise newer line first
        }
        return Array(sorted.prefix(maxResults).map { $0.0 })
    }
} 