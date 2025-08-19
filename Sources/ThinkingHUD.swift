import Foundation
import AppKit

@available(macOS 12.3, *)
@MainActor
final class ThinkingHUD: NSObject {
	private var window: NSWindow?
	private var spinner: NSProgressIndicator?
	private var label: NSTextField?
	private var isShowing = false
	private let padding: CGFloat = 10
	private let hudSize = NSSize(width: 160, height: 44)
	
	func show(at screenPoint: CGPoint) {
		guard !isShowing else { return }
		isShowing = true
		let frame = frame(at: screenPoint)
		let win = NSWindow(contentRect: frame,
						styleMask: [.borderless],
						backing: .buffered,
						defer: false)
		win.level = .floating
		win.isOpaque = false
		win.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.85)
		win.hasShadow = true
		win.ignoresMouseEvents = true
		win.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
		win.titleVisibility = .hidden
		win.titlebarAppearsTransparent = true
		
		let content = NSView(frame: NSRect(origin: .zero, size: frame.size))
		win.contentView = content
		
		let spinner = NSProgressIndicator(frame: NSRect(x: padding, y: (frame.height-16)/2, width: 16, height: 16))
		spinner.style = .spinning
		spinner.controlSize = .small
		spinner.startAnimation(nil)
		content.addSubview(spinner)
		
		let label = NSTextField(labelWithString: "Thinking…")
		label.textColor = NSColor.secondaryLabelColor
		label.font = NSFont.systemFont(ofSize: 12)
		label.frame = NSRect(x: padding + 20, y: (frame.height-18)/2, width: frame.width - (padding + 24), height: 18)
		content.addSubview(label)
		
		self.spinner = spinner
		self.label = label
		self.window = win
		
		win.alphaValue = 0
		win.makeKeyAndOrderFront(nil)
		NSAnimationContext.runAnimationGroup({ ctx in
			ctx.duration = 0.12
			win.animator().alphaValue = 1
		}, completionHandler: nil)
	}
	
	func hide() {
		guard isShowing, let win = window else { return }
		isShowing = false
		NSAnimationContext.runAnimationGroup({ ctx in
			ctx.duration = 0.12
			win.animator().alphaValue = 0
		}, completionHandler: {
			win.orderOut(nil)
			self.spinner = nil
			self.label = nil
			self.window = nil
		})
	}
	
	private func frame(at screenPoint: CGPoint) -> NSRect {
		// Position slightly down-right from the cursor; convert to AppKit coordinate space
		let origin = NSPoint(x: screenPoint.x + 12, y: screenPoint.y - hudSize.height - 12)
		return NSRect(origin: origin, size: hudSize)
	}
} 