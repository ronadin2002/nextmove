import Foundation
import ScreenCaptureKit
import CoreMedia
import CoreGraphics
import QuartzCore
import AppKit // for CGEvent location

@available(macOS 12.3, *)
final class CaptureService: NSObject, SCStreamOutput, SCStreamDelegate {
    weak var delegate: CaptureServiceDelegate?
    private var streams: [SCStream] = []
    private var streamDisplayMap: [SCStream: SCDisplay] = [:]

    func start() async throws {
        let content = try await SCShareableContent.current
        let displays = content.displays
        guard !displays.isEmpty else { throw NSError(domain: "", code: -1) }

        // Create one stream per display
        for display in displays {
            let filter = SCContentFilter(display: display, excludingWindows: [])
            let config = SCStreamConfiguration()
            config.minimumFrameInterval = CMTime(value: 1, timescale: 2) // 0.5 fps
            config.scalesToFit = true
            config.width  = display.width
            config.height = display.height

            let stream = SCStream(filter: filter, configuration: config, delegate: self)
            try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: .global(qos: .userInitiated))
            try await stream.startCapture()

            streams.append(stream)
            streamDisplayMap[stream] = display
        }

        print("Started capturing \(streams.count) display stream(s)")
        for (idx, display) in displays.enumerated() {
            let frame = display.frame
            print("Display \(idx): id=\(display.displayID) \(display.width)x\(display.height) origin=(\(frame.origin.x),\(frame.origin.y))")
        }
    }

    // MARK: - SCStreamOutput
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of outputType: SCStreamOutputType) {
        guard let imageBuffer = sampleBuffer.imageBuffer else { return }
        let ciImage = CIImage(cvImageBuffer: imageBuffer)
        let ctx = CIContext()
        // No need to create full image before crop
        // Crop ROI around mouse pointer (~800x600)
        guard let disp = streamDisplayMap[stream] else { return }
        let globalPoint = CGEvent(source: nil)?.location ?? .zero   // origin TOP-LEFT of primary display
        // Convert to display-local, bottom-left origin
        let localX = globalPoint.x - disp.frame.origin.x
        let localYTop = globalPoint.y - disp.frame.origin.y         // still top-left
        let localY = CGFloat(disp.height) - localYTop

        var roi = CGRect(x: localX - 400,
                          y: localY - 300,
                          width: 800,
                          height: 600).intersection(ciImage.extent)

        guard !roi.isEmpty,
              let cropped = ctx.createCGImage(ciImage.cropped(to: roi), from: roi) else { return }
        let frame = CapturedFrame(cgImage: cropped,
                                   timestamp: CACurrentMediaTime(),
                                   displayID: streamDisplayMap[stream]?.displayID ?? 0,
                                   dirtyRects: [roi])
        delegate?.captureService(self, didCapture: frame)
    }
} 