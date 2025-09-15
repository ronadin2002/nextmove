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
            print("✅ LLM returned \(rawSuggestions.count) suggestions")
            return rawSuggestions
        } catch {
            print("❌ LLM API error: \(error)")
            print("🔄 Falling back to contextual mock suggestions...")
            return getContextualMockSuggestions(for: prompt)
        }
    }
    
    // Validation helpers removed per request; return raw suggestions as-is
    
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
        6. Do NOT repeat text that already exists before the ____ marker; output ONLY the missing continuation after ____.
        
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