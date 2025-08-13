import Foundation
import AppKit
import ApplicationServices
import CoreGraphics

@available(macOS 12.3, *)
struct CursorContextSnapshot {
    let screenPoint: CGPoint
    let appName: String?
    let role: String?
    let title: String?
    let url: String?
    let markedText: String  // text with ____ inserted near cursor
}

@available(macOS 12.3, *)
final class CursorInspector {
    private let ocr = OcrService()
    // Sticky fallback so a transient OCR miss still yields useful context
    private var lastMarkedLine: String = ""
    private var lastMarkedAt: TimeInterval = 0

    func snapshotNow(radius: CGFloat = 200) async -> CursorContextSnapshot? {
        // CGEvent gives bottom-left origin; AX/window APIs expect top-left
        let locBL = CGEvent(source: nil)?.location ?? .zero
        let locTL = convertBLToTL(locBL)

        // AX hit-test under cursor (top-left coords)
        let system = AXUIElementCreateSystemWide()
        var elRef: AXUIElement?
        AXUIElementCopyElementAtPosition(system, Float(locTL.x), Float(locTL.y), &elRef)

        var pid: pid_t = 0
        var roleRef: CFTypeRef?
        var titleRef: CFTypeRef?
        var urlRef: CFTypeRef?

        if let el = elRef {
            AXUIElementGetPid(el, &pid)
            AXUIElementCopyAttributeValue(el, kAXRoleAttribute as CFString, &roleRef)
            AXUIElementCopyAttributeValue(el, kAXTitleAttribute as CFString, &titleRef)
            AXUIElementCopyAttributeValue(el, "AXURL" as CFString, &urlRef)
        }

        let appName: String? = {
            guard pid != 0, let app = NSRunningApplication(processIdentifier: pid) else { return nil }
            return app.localizedName
        }()

        // Determine the topmost window (if any) for this PID that contains the cursor point
        let win = topmostWindow(at: locTL, forPID: pid)
        let winBounds = win?.bounds

        // Try a cascade of capture strategies, expanding radius if needed
        var marked = ""
        var attemptRadius = radius
        for _ in 0..<3 { // up to 3 expansions
            var rTL = CGRect(x: locTL.x - attemptRadius, y: locTL.y - attemptRadius, width: attemptRadius * 2, height: attemptRadius * 2)
            if let wb = winBounds { rTL = rTL.intersection(wb) }
            if rTL.isEmpty {
                attemptRadius *= 1.4
                continue
            }

            // Strategy A: window-only
            if let w = win, let img = CGWindowListCreateImage(rTL, [.optionIncludingWindow], CGWindowID(w.number), [.bestResolution, .boundsIgnoreFraming]) {
                marked = await markNearestLine(in: img, cropRectTL: rTL, cursorTL: locTL)
                if !marked.isEmpty { break }
            }

            // Strategy B: on-screen composite region (all windows)
            if let img = CGWindowListCreateImage(rTL, [.optionOnScreenOnly], kCGNullWindowID, [.bestResolution, .boundsIgnoreFraming]) {
                marked = await markNearestLine(in: img, cropRectTL: rTL, cursorTL: locTL)
                if !marked.isEmpty { break }
            }

            // Strategy C: raw display pixels (rect must be in display coords; already TL global)
            if let (displayID, _) = displayContaining(pointTL: locTL), let img = CGDisplayCreateImage(displayID, rect: rTL) {
                marked = await markNearestLine(in: img, cropRectTL: rTL, cursorTL: locTL)
                if !marked.isEmpty { break }
            }

            attemptRadius *= 1.4
        }

        // Sticky fallback if OCR missed this frame
        if marked.isEmpty {
            let now = CFAbsoluteTimeGetCurrent()
            if now - lastMarkedAt < 3.0, !lastMarkedLine.isEmpty { // use last within 3s
                marked = lastMarkedLine + "____"
            } else {
                marked = "____"
            }
        } else {
            // Update sticky cache
            lastMarkedLine = marked.replacingOccurrences(of: "____", with: "")
            lastMarkedAt = CFAbsoluteTimeGetCurrent()
        }

        return CursorContextSnapshot(
            screenPoint: locBL,
            appName: appName,
            role: roleRef as? String,
            title: titleRef as? String,
            url: (urlRef as? URL)?.absoluteString,
            markedText: marked
        )
    }

    // Find the topmost on-screen window for the PID that contains the point (top-left coords)
    private func topmostWindow(at pointTL: CGPoint, forPID pid: pid_t) -> (number: Int, bounds: CGRect)? {
        guard let infos = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }
        for info in infos {
            guard let ownerPID = info[kCGWindowOwnerPID as String] as? pid_t, ownerPID == pid else { continue }
            guard let boundsDict = info[kCGWindowBounds as String] as? [String: CGFloat] else { continue }
            let bounds = CGRect(x: boundsDict["X"] ?? 0, y: boundsDict["Y"] ?? 0, width: boundsDict["Width"] ?? 0, height: boundsDict["Height"] ?? 0)
            if bounds.contains(pointTL), let number = info[kCGWindowNumber as String] as? Int {
                return (number, bounds)
            }
        }
        return nil
    }

    // Convert bottom-left origin point (CGEvent) to top-left origin global space (CGWindow/AX)
    private func convertBLToTL(_ p: CGPoint) -> CGPoint {
        var count: UInt32 = 0
        CGGetActiveDisplayList(0, nil, &count)
        let n = Int(count)
        var ids = [CGDirectDisplayID](repeating: 0, count: n)
        CGGetActiveDisplayList(count, &ids, &count)
        var maxY: CGFloat = 0
        for id in ids {
            let b = CGDisplayBounds(id)
            maxY = max(maxY, b.maxY)
        }
        // Flip Y to top-left space
        return CGPoint(x: p.x, y: maxY - p.y)
    }

    // Find display that contains a top-left-origin point
    private func displayContaining(pointTL: CGPoint) -> (CGDirectDisplayID, CGRect)? {
        var count: UInt32 = 0
        CGGetActiveDisplayList(0, nil, &count)
        let n = Int(count)
        var ids = [CGDirectDisplayID](repeating: 0, count: n)
        CGGetActiveDisplayList(count, &ids, &count)
        for id in ids {
            let b = CGDisplayBounds(id)
            if b.contains(pointTL) { return (id, b) }
        }
        let main = CGMainDisplayID()
        return (main, CGDisplayBounds(main))
    }

    private func markNearestLine(in cgImage: CGImage, cropRectTL: CGRect, cursorTL: CGPoint) async -> String {
        await withCheckedContinuation { continuation in
            ocr.recognize(cgImage: cgImage) { blocks in
                guard !blocks.isEmpty else {
                    continuation.resume(returning: "")
                    return
                }
                let size = CGSize(width: cgImage.width, height: cgImage.height)
                // Map cursor (top-left global) into image pixel coordinates
                let relX = cursorTL.x - cropRectTL.minX
                let relY = cursorTL.y - cropRectTL.minY
                // Convert TL to image coords (image has TL origin)
                let cursorPx = CGPoint(x: relX * (CGFloat(size.width) / cropRectTL.width),
                                       y: relY * (CGFloat(size.height) / cropRectTL.height))

                var bestIndex = -1
                var bestDist = CGFloat.greatestFiniteMagnitude
                var texts: [String] = []
                texts.reserveCapacity(blocks.count)
                var rects: [CGRect] = []
                rects.reserveCapacity(blocks.count)

                for (i, b) in blocks.enumerated() {
                    let rect = CGRect(x: b.boundingBox.origin.x * size.width,
                                      y: b.boundingBox.origin.y * size.height,
                                      width: b.boundingBox.size.width * size.width,
                                      height: b.boundingBox.size.height * size.height)
                    rects.append(rect)
                    texts.append(b.text)
                    // Prefer blocks containing the cursor
                    let contains = rect.contains(cursorPx)
                    let d: CGFloat = contains ? -1 : hypot(rect.midX - cursorPx.x, rect.midY - cursorPx.y)
                    if d < bestDist {
                        bestDist = d
                        bestIndex = i
                    }
                }

                var marked = ""
                if bestIndex >= 0 {
                    let line = texts[bestIndex].trimmingCharacters(in: .whitespacesAndNewlines)
                    if !line.isEmpty {
                        // Insert marker at approximate character index based on cursor X within rect
                        let r = rects[bestIndex]
                        let posRatio = max(0, min(1, (cursorPx.x - r.minX) / max(r.width, 1)))
                        let idx = Int(round(posRatio * CGFloat(line.count)))
                        let i = line.index(line.startIndex, offsetBy: min(max(0, idx), line.count))
                        marked = String(line[..<i]) + "____" + String(line[i...])
                    }
                }
                continuation.resume(returning: marked)
            }
        }
    }
} 