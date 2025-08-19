import Foundation

struct LLMSuggestion: Codable {
    let text: String
    let confidence: Float
    let type: String
    let source: String?  // NEW: Track where suggestion came from
}

struct LLMResponse: Codable {
    let suggestions: [LLMSuggestion]?
    let text: String?
    let confidence: Float?
}

@available(macOS 12.3, *)
final class LLMService {
    private let apiKey: String
    private let baseURL = "https://api.openai.com/v1/chat/completions"
    private let session = URLSession.shared
    
    init() {
        // For production, use environment variable: OPENAI_API_KEY
        if let envKey = ProcessInfo.processInfo.environment["OPENAI_API_KEY"], !envKey.isEmpty {
            self.apiKey = envKey
            print("🤖 OpenAI LLM service initialized with environment API key")
        } else {
            // Try to load from .env in current working directory
            let cwd = FileManager.default.currentDirectoryPath
            let envPath = (cwd as NSString).appendingPathComponent(".env")
            if let data = try? String(contentsOfFile: envPath),
               let line = data.split(separator: "\n").first(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("OPENAI_API_KEY=") }) {
                let raw = line.replacingOccurrences(of: "OPENAI_API_KEY=", with: "")
                let cleaned = raw.trimmingCharacters(in: CharacterSet(charactersIn: " \"'\n\r\t")).trimmingCharacters(in: .whitespacesAndNewlines)
                self.apiKey = cleaned
                if cleaned.isEmpty {
                    print("⚠️ .env found but OPENAI_API_KEY is empty. LLM calls will be skipped; using mock suggestions.")
                } else {
                    print("🔑 OpenAI API key loaded from .env")
                }
            } else {
                self.apiKey = ""
                print("⚠️ OPENAI_API_KEY not set and no .env found. LLM calls will be skipped; using mock suggestions.")
            }
        }
    }
    
    // Main function to get text suggestions from LLM
    func getSuggestions(for prompt: String) async -> [LLMSuggestion] {
        do {
            let rawSuggestions = try await callOpenAI(prompt: prompt)
            
            // NEW: Validate and filter suggestions to prevent hallucinations
            let validatedSuggestions = validateAndFilterSuggestions(rawSuggestions, originalPrompt: prompt)
            
            print("✅ LLM returned \(rawSuggestions.count) suggestions, \(validatedSuggestions.count) passed validation")
            return validatedSuggestions
        } catch {
            print("❌ LLM API error: \(error)")
            print("🔄 Falling back to contextual mock suggestions...")
            return getContextualMockSuggestions(for: prompt)
        }
    }
    
    // NEW: Validate suggestions to prevent hallucinations
    private func validateAndFilterSuggestions(_ suggestions: [LLMSuggestion], originalPrompt: String) -> [LLMSuggestion] {
        return suggestions.compactMap { suggestion in
            guard isValidSuggestion(suggestion, prompt: originalPrompt) else {
                print("🚫 Filtered invalid suggestion: '\(suggestion.text)'")
                return nil
            }
            return suggestion
        }
    }
    
    // NEW: Comprehensive validation to prevent hallucinations
    private func isValidSuggestion(_ suggestion: LLMSuggestion, prompt: String) -> Bool {
        let text = suggestion.text.trimmingCharacters(in: .whitespacesAndNewlines)
        
        // 1. Basic sanity checks
        guard !text.isEmpty && text.count < 200 else { return false }
        
        // 2. Detect repetitive patterns (major source of hallucinations)
        if hasRepetitivePattern(text) {
            print("🚫 Repetitive pattern detected: '\(text)'")
            return false
        }
        
        // 3. Check for circular/nonsensical content
        if hasCircularLogic(text) {
            print("🚫 Circular logic detected: '\(text)'")
            return false
        }
        
        // 4. Ensure suggestion is actually relevant to the prompt
        if !isRelevantToPrompt(text, prompt: prompt) {
            print("🚫 Irrelevant to prompt: '\(text)'")
            return false
        }
        
        // 5. Check for placeholder/generic content
        if isGenericPlaceholder(text) {
            print("🚫 Generic placeholder detected: '\(text)'")
            return false
        }
        
        return true
    }
    
    // NEW: Detect repetitive patterns
    private func hasRepetitivePattern(_ text: String) -> Bool {
        let words = text.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }
        
        // Need at least 6 words to detect meaningful repetitive patterns
        guard words.count >= 6 else { return false }
        
        // Check for repeated phrases
        for i in 0..<words.count {
            let maxLength = min(8, words.count - i)
            // Only check if we have enough words for a meaningful pattern
            guard maxLength >= 3 else { continue }
            
            for length in 3...maxLength {
                let phrase = words[i..<i+length].joined(separator: " ")
                let remainingStartIndex = i + length
                
                // Make sure we have remaining text to check
                guard remainingStartIndex < words.count else { continue }
                
                let remainingText = words[remainingStartIndex...].joined(separator: " ")
                
                if remainingText.contains(phrase) {
                    return true  // Found repetitive pattern
                }
            }
        }
        
        // Check for too many repeated words
        let wordCounts = Dictionary(grouping: words, by: { $0.lowercased() })
        let maxWordCount = wordCounts.values.map { $0.count }.max() ?? 0
        return maxWordCount > words.count / 3  // More than 1/3 are the same word
    }
    
    // NEW: Detect circular logic
    private func hasCircularLogic(_ text: String) -> Bool {
        let lowerText = text.lowercased()
        
        // Common circular patterns
        let circularPatterns = [
            "when he became the",
            "who was the.*who",
            "that is the.*that",
            "which was.*which"
        ]
        
        return circularPatterns.contains { pattern in
            lowerText.range(of: pattern, options: .regularExpression) != nil
        }
    }
    
    // NEW: Check relevance to prompt context
    private func isRelevantToPrompt(_ text: String, prompt: String) -> Bool {
        // For sentence completions, be more lenient
        if text.count > 10 && text.contains(" ") {
            return true  // Accept substantial sentence completions
        }
        
        // Extract context clues from prompt
        let promptKeywords = extractKeywords(from: prompt)
        let suggestionKeywords = extractKeywords(from: text)
        
        // At least some overlap in keywords OR it's a reasonable completion
        let intersection = promptKeywords.intersection(suggestionKeywords)
        let hasOverlap = !intersection.isEmpty
        let isShortCompletion = text.count < 30
        let isReasonableText = text.contains(" ") || text.contains("@") || text.contains(".")
        
        let isRelevant = hasOverlap || isShortCompletion || isReasonableText
        
        if !isRelevant {
            print("🔍 DEBUG: Relevance check failed for '\(text)'")
            print("   Keywords in prompt: \(promptKeywords)")
            print("   Keywords in suggestion: \(suggestionKeywords)")
            print("   Intersection: \(intersection)")
        }
        
        return isRelevant
    }
    
    // NEW: Detect generic placeholders
    private func isGenericPlaceholder(_ text: String) -> Bool {
        let lowerText = text.lowercased()
        let genericTerms = [
            "example.com", "placeholder", "insert", "your", "here",
            "lorem ipsum", "sample", "template", "default"
        ]
        
        return genericTerms.contains { lowerText.contains($0) }
    }
    
    private func extractKeywords(from text: String) -> Set<String> {
        return Set(text.lowercased()
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { $0.count > 3 && !["that", "this", "with", "from", "they", "were", "been", "have"].contains($0) })
    }
    
    // Call OpenAI API with improved error handling
    private func callOpenAI(prompt: String) async throws -> [LLMSuggestion] {
        guard !apiKey.isEmpty else {
            throw LLMError.noAPIKey
        }
        let requestBody: [String: Any] = [
            "model": "gpt-4o-mini",
            "messages": [
                [
                    "role": "system",
                    "content": buildEnhancedSystemPrompt()
                ],
                [
                    "role": "user",
                    "content": prompt
                ]
            ],
            "max_tokens": 300,
            "temperature": 0.3,
            "top_p": 0.8,
            "presence_penalty": 0.6,
            "frequency_penalty": 0.8
        ]
        
        var request = URLRequest(url: URL(string: baseURL)!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: requestBody)
        request.timeoutInterval = 10.0
        
        let (data, response) = try await session.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw LLMError.invalidResponse
        }
        
        if httpResponse.statusCode != 200 {
            let errorBody = String(data: data, encoding: .utf8) ?? "Unknown error"
            print("❌ OpenAI API error \(httpResponse.statusCode): \(errorBody)")
            throw LLMError.apiError(httpResponse.statusCode, errorBody)
        }
        
        // Parse OpenAI response
        let openAIResponse = try JSONDecoder().decode(OpenAIResponse.self, from: data)
        guard let content = openAIResponse.choices.first?.message.content else {
            throw LLMError.noContent
        }
        
        // Clean and parse the content
        let cleanContent = content
            .replacingOccurrences(of: "```json", with: "")
            .replacingOccurrences(of: "```", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        
        guard let contentData = cleanContent.data(using: .utf8) else {
            throw LLMError.invalidJSON
        }
        
        let llmResponse = try JSONDecoder().decode(LLMResponse.self, from: contentData)
        if let suggestions = llmResponse.suggestions, !suggestions.isEmpty {
            return suggestions
        }
        if let text = llmResponse.text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let conf = llmResponse.confidence ?? 0.7
            return [LLMSuggestion(text: text, confidence: conf, type: "completion", source: "single")]
        }
        throw LLMError.invalidJSON
    }
    
    // NEW: Enhanced system prompt with stronger anti-hallucination rules
    private func buildEnhancedSystemPrompt() -> String {
        return """
        You are a smart completion assistant. Your goal is to provide PRECISE, RELEVANT completions.

        CRITICAL ANTI-HALLUCINATION RULES:
        1. NEVER generate repetitive patterns or circular text
        2. NEVER complete with generic placeholders or examples
        3. ONLY use ACTUAL content from the user's recent activity
        4. Keep completions short and specific (under 100 characters preferred)
        5. If you don't have relevant context, suggest practical alternatives
        
        BANNED PATTERNS:
        - "who was the X who was the X"
        - "when he became the X when he became"  
        - "example@example.com" or generic placeholders
        - Repetitive phrases or circular definitions
        
        QUALITY CHECKS:
        - Does this completion make logical sense?
        - Is it derived from actual user context?
        - Is it practically useful for the user?
        - Is it free from repetition?
        
        RESPOND ONLY WITH VALID JSON - no explanations or additional text.
        """
    }
    
    // Enhanced contextual mock suggestions with validation
    private func getContextualMockSuggestions(for prompt: String) -> [LLMSuggestion] {
        print("🤖 Generating enhanced contextual completion suggestions...")
        
        let content = prompt.lowercased()
        
        // Email completion context  
        if content.contains("@") || content.contains("email") {
            return [
                LLMSuggestion(text: "gmail.com", confidence: 0.9, type: "completion", source: "mock_email"),
                LLMSuggestion(text: "company.com", confidence: 0.8, type: "alternative", source: "mock_email"),
                LLMSuggestion(text: "outlook.com", confidence: 0.7, type: "extended", source: "mock_email")
            ]
        }
        
        // Time/meeting context
        if content.contains("time") || content.contains("meeting") {
            return [
                LLMSuggestion(text: "3:00 PM", confidence: 0.9, type: "completion", source: "mock_time"),
                LLMSuggestion(text: "tomorrow", confidence: 0.8, type: "alternative", source: "mock_time"),
                LLMSuggestion(text: "next week", confidence: 0.7, type: "extended", source: "mock_time")
            ]
        }
        
        // Safe fallback - avoid generic terms
        return [
            LLMSuggestion(text: "...", confidence: 0.6, type: "completion", source: "mock_safe"),
            LLMSuggestion(text: "", confidence: 0.5, type: "alternative", source: "mock_safe"),
            LLMSuggestion(text: " ", confidence: 0.4, type: "extended", source: "mock_safe")
        ]
    }
}

// OpenAI API response structures
private struct OpenAIResponse: Codable {
    let choices: [Choice]
    
    struct Choice: Codable {
        let message: Message
        
        struct Message: Codable {
            let content: String
        }
    }
}

// Enhanced error types
enum LLMError: Error {
    case noAPIKey
    case invalidResponse
    case noContent
    case invalidJSON
    case apiError(Int, String)
    
    var localizedDescription: String {
        switch self {
        case .noAPIKey:
            return "No API key provided"
        case .invalidResponse:
            return "Invalid response from LLM service"
        case .noContent:
            return "No content in LLM response"
        case .invalidJSON:
            return "Invalid JSON in LLM response"
        case .apiError(let code, let message):
            return "API error \(code): \(message)"
        }
    }
} 