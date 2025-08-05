import Foundation

protocol TextOutputDelegate: AnyObject {
    func didExtractTextBlocks(_ blocks: [TextBlock])
} 