#!/bin/bash

# PasteRecall Build Script
# Builds the AI Writing Assistant with your API key

echo "🚀 Building PasteRecall AI Writing Assistant..."

# Check if API key is set
if [ -z "$OPENAI_API_KEY" ]; then
    echo "❌ Error: OPENAI_API_KEY environment variable not set"
    echo ""
    echo "🔧 To fix this:"
    echo "1. Get an API key from: https://platform.openai.com/api-keys"
    echo "2. Export it: export OPENAI_API_KEY='your-key-here'"
    echo "3. Run this script again"
    echo ""
    echo "💡 Or edit Sources/LLMService.swift manually"
    exit 1
fi

echo "✅ API key found"

# Build the project
echo "🔨 Building Swift project..."
swift build -c release

if [ $? -ne 0 ]; then
    echo "❌ Build failed"
    exit 1
fi

echo "📦 Creating app bundle..."

# Create app bundle structure
mkdir -p PasteRecall.app/Contents/MacOS

# Copy executable
cp .build/release/nextmove-2 PasteRecall.app/Contents/MacOS/

# Make executable
chmod +x PasteRecall.app/Contents/MacOS/nextmove-2

echo "🎉 Build complete!"
echo ""
echo "🚀 To run:"
echo "   open PasteRecall.app"
echo ""
echo "🔧 Don't forget to grant permissions:"
echo "   • Screen Recording: System Settings > Privacy & Security"
echo "   • Accessibility: System Settings > Privacy & Security"
echo ""
echo "🎯 Then press CMD+G in any app to test!" 