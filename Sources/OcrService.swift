import Foundation
import Vision
import CoreGraphics
import QuartzCore

struct OcrBlock {
    let text: String
    let boundingBox: CGRect   // normalized [0,1] coords relative to image
    let confidence: Float
    let timestamp: TimeInterval
}

@available(macOS 10.15, *)
final class OcrService {
    private let queue = DispatchQueue(label: "ocr.queue", qos: .userInitiated)

    func recognize(cgImage: CGImage, completion: @escaping ([OcrBlock]) -> Void) {
        queue.async {
            let request = VNRecognizeTextRequest { req, _ in
                guard let observations = req.results as? [VNRecognizedTextObservation] else {
                    completion([]); return
                }
                let blocks: [OcrBlock] = observations.compactMap { obs in
                    guard let top = obs.topCandidates(1).first, top.confidence > 0.5 else { return nil }
                    return OcrBlock(text: top.string,
                                    boundingBox: obs.boundingBox,
                                    confidence: top.confidence,
                                    timestamp: CACurrentMediaTime())
                }
                completion(blocks)
            }
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            if #available(macOS 13.0, *) {
                request.revision = VNRecognizeTextRequestRevision3
            }
            // Leave recognitionLanguages nil to let Vision auto-detect many languages
            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            try? handler.perform([request])
        }
    }
} 