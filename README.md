# 🚀 PasteRecall - AI Writing Assistant

**The intelligent macOS writing assistant that transforms your screen activity into AI-powered text suggestions.**

Press `CMD+G` anywhere and get contextual AI-generated text pasted directly into your application!

## ✨ Features

- 🔥 **Global CMD+G Hotkey** - Works across all macOS applications
- 🧠 **AI-Powered Suggestions** - Uses OpenAI GPT-4o-mini for intelligent text generation
- 📸 **Screen Context Analysis** - Analyzes current screen content and cursor position
- 📝 **Auto-Paste** - Automatically pastes the best AI suggestion
- 🎯 **Mouse-Centered OCR** - Captures text around your cursor across multiple displays
- 📊 **Activity Logging** - Continuously logs screen text for context analysis
- 🔒 **Privacy-Focused** - All data stays local, only sends context to AI when triggered

## 🎬 How It Works

1. **Press CMD+G** in any application (TextEdit, Email, Browser, etc.)
2. **AI analyzes** your current screen content + recent activity
3. **GPT generates** 3 contextual text suggestions 
4. **Best suggestion** automatically gets pasted at your cursor
5. **You keep writing** with AI assistance!

## 🛠️ Setup

### Prerequisites

- macOS 12.3+ (Monterey or newer)
- Swift 5.7+
- OpenAI API key

### Quick Start

1. **Clone the repository:**
   ```bash
   git clone https://github.com/ronadin2002/nextmove.git
   cd nextmove-2
   ```

2. **Set your OpenAI API key:**
   ```bash
   export OPENAI_API_KEY="your-api-key-here"
   ```
   
   Or edit `Sources/LLMService.swift` and replace `"your-openai-api-key-here"` with your actual key.

3. **Build and run:**
   ```bash
   swift build -c release
   mkdir -p PasteRecall.app/Contents/MacOS
   cp .build/release/nextmove-2 PasteRecall.app/Contents/MacOS/
   open PasteRecall.app
   ```

4. **Grant permissions:**
   - **Screen Recording**: System Settings > Privacy & Security > Screen Recording
   - **Accessibility**: System Settings > Privacy & Security > Accessibility
   - Add and enable `PasteRecall.app` for both

5. **Test it:**
   - Open TextEdit or any text editor
   - Position your cursor
   - Press `CMD+G`
   - Watch AI magic happen! 🎉

## 📋 Terminal Output

When you press CMD+G, you'll see detailed logs:

```
🔥 CMD+G detected! Triggering AI assistant...
🔍 Step 1: Analyzing current context...
🧠 Context: App=TextEdit, Confidence=0.8
📄 Screen preview: Dear John, I wanted to follow up on our meeting...

🤖 Step 2: Building LLM prompt...
💭 Step 3: Getting AI suggestions...

✨ GPT-4o-mini Responses:
  1. [COMPLETION] Thank you for taking the time to meet with me yesterday.
     Confidence: 0.9
  2. [ALTERNATIVE] I appreciate the productive discussion we had.
     Confidence: 0.8
  3. [EXTENDED] Thank you for the insightful conversation. I wanted to summarize the key points we discussed and outline next steps.
     Confidence: 0.7

🎯 Auto-pasting best suggestion: [COMPLETION] Thank you for taking the time to meet...
📝 Step 5: Auto-pasting text...
✅ Text pasted successfully!
📖 Learning from auto-paste for future improvements...
🎉 AI assistance complete!
```

## 🏗️ Architecture

### Core Components

- **`HotkeyService`** - Global CMD+G detection using CGEventTap + fallbacks
- **`CaptureService`** - Multi-display screen capture with ScreenCaptureKit
- **`OcrService`** - Apple Vision OCR for text extraction
- **`ContextAnalyzer`** - Combines screen content + activity history
- **`LLMService`** - OpenAI API integration with smart prompting
- **`PasteService`** - Cross-application text insertion
- **`TextStorage`** - Efficient content logging and deduplication

### Data Flow

```
CMD+G → Screen Capture → OCR → Context Analysis → LLM Prompt → AI Response → Auto-Paste
```

## 📁 Output Files

- **`content.jsonl`** - Compressed activity logs in JSON Lines format
- Logs contain deduplicated screen text with timestamps and app context
- Used for building contextual AI prompts

## 🔧 Configuration

### Environment Variables

- `OPENAI_API_KEY` - Your OpenAI API key

### Customization

- **Model**: Change in `LLMService.swift` (default: `gpt-4o-mini`)
- **Capture Rate**: Modify in `CaptureService.swift`
- **OCR Region**: Adjust mouse-centered capture area
- **Hotkey**: Currently CMD+G (can be modified in `HotkeyService.swift`)

## 🐛 Troubleshooting

### CMD+G Not Working

1. **Check permissions**: Accessibility + Screen Recording must be enabled
2. **Try manual trigger**: Type `trigger` in the terminal
3. **Check logs**: Look for "CMD+key detected" messages
4. **Restart app**: After granting new permissions

### No AI Responses

1. **Verify API key**: Check `OPENAI_API_KEY` environment variable
2. **Check network**: Ensure internet connectivity
3. **View logs**: Look for API error messages in terminal

### Pasting Issues

1. **Focus target app**: Ensure cursor is in a text field
2. **Check clipboard**: If auto-paste fails, text is copied for manual CMD+V
3. **App compatibility**: Some apps may block programmatic text insertion

## 🔐 Privacy & Security

- **Local-first**: All screen analysis happens on your device
- **Minimal data**: Only sends relevant context to OpenAI (not full screen)
- **No storage**: API responses aren't permanently stored
- **Encrypted logs**: Activity logs use efficient, privacy-focused format

## 🎯 Use Cases

- **Email writing** - Complete professional responses
- **Code completion** - Generate functions and comments  
- **Document writing** - Continue paragraphs and thoughts
- **Chat responses** - Quick, contextual replies
- **Note-taking** - Expand on bullet points
- **Creative writing** - Break through writer's block

## 🚀 Future Features

- [ ] Multiple LLM providers (Anthropic, local models)
- [ ] Custom hotkey configuration
- [ ] UI for suggestion selection
- [ ] Learning from user preferences
- [ ] Offline mode with local models
- [ ] Multi-language support

## 📄 License

MIT License - see LICENSE file for details.

## 🤝 Contributing

Pull requests welcome! This is an experimental AI writing assistant - let's make it even better.

---

**Made with ❤️ for productive writing**

*Transform your screen into an intelligent writing companion!* 