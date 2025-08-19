import Foundation
import CoreGraphics

struct TextBlock: @unchecked Sendable {
    let text: String
    let rect: CGRect   // screen-space rect (pixels)
    let sourceApp: String?
    let windowTitle: String?
    let sourceURL: String?
    let ts: TimeInterval
    let confidence: Float
}

func normalize(blocks: [OcrBlock], in imageSize: CGSize, app: String?, title: String?, url: String? = nil) -> [TextBlock] {
    // naive: one block == one TextBlock
    return blocks.map { b in
        let rect = CGRect(x: b.boundingBox.origin.x * imageSize.width,
                          y: b.boundingBox.origin.y * imageSize.height,
                          width: b.boundingBox.size.width * imageSize.width,
                          height: b.boundingBox.size.height * imageSize.height)
        return TextBlock(text: b.text, rect: rect, sourceApp: app, windowTitle: title, sourceURL: url, ts: b.timestamp, confidence: b.confidence)
    }
} 