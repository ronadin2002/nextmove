import Foundation
import AppKit
import QuartzCore
import CoreImage
import SwiftUI
import Orb

@available(macOS 12.3, *)
@MainActor
final class ThinkingHUD: NSObject {
	private var window: NSWindow?
	private var isShowing = false
	private let hudSize = NSSize(width: 32, height: 32)
	
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
		win.backgroundColor = .clear
		win.hasShadow = false
		win.ignoresMouseEvents = true
		win.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
		win.titleVisibility = .hidden
		win.titlebarAppearsTransparent = true
		
		// Orb-only content view
		let orbSize: CGFloat = 28
		let container = NSView(frame: NSRect(origin: .zero, size: frame.size))
		container.wantsLayer = true
		win.contentView = container
		
		let config = OrbConfiguration(
			backgroundColors: [
				Color(red: 0.05, green: 0.30, blue: 0.85),
				Color(red: 0.00, green: 0.20, blue: 0.55)
			],
			glowColor: Color(red: 0.20, green: 0.45, blue: 1.00),
			coreGlowIntensity: 1.25,
			showBackground: true,
			showWavyBlobs: true,
			showParticles: false,
			showGlowEffects: true,
			showShadow: false,
			speed: 60
		)
		let orbView = OrbView(configuration: config)
			.frame(width: orbSize, height: orbSize)
			.allowsHitTesting(false)
		let host = NSHostingView(rootView: orbView)
		host.frame = CGRect(x: (frame.width - orbSize)/2, y: (frame.height - orbSize)/2, width: orbSize, height: orbSize)
		container.addSubview(host)
		
		win.alphaValue = 0
		win.makeKeyAndOrderFront(nil)
		let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
		if reduceMotion { win.alphaValue = 1 } else {
		NSAnimationContext.runAnimationGroup({ ctx in
				ctx.duration = 0.15
			win.animator().alphaValue = 1
		}, completionHandler: nil)
		}
		self.window = win
	}
	
	func hide() {
		guard isShowing, let win = window else { return }
		isShowing = false
		let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
		if reduceMotion {
			win.alphaValue = 0
			win.orderOut(nil)
			self.window = nil
			return
		}
		NSAnimationContext.runAnimationGroup({ ctx in
			ctx.duration = 0.12
			win.animator().alphaValue = 0
		}, completionHandler: {
			win.orderOut(nil)
			self.window = nil
		})
	}
	
	// NEW: Reposition the window to a new anchor point
	func reposition(at screenPoint: CGPoint) {
		guard let win = window else { return }
		let newFrame = frame(at: screenPoint)
		win.setFrame(newFrame, display: true)
	}
	
	private func frame(at screenPoint: CGPoint) -> NSRect {
		// Center orb exactly on the anchor point
		let origin = NSPoint(x: screenPoint.x - hudSize.width / 2,
							y: screenPoint.y - hudSize.height / 2)
		return NSRect(origin: origin, size: hudSize)
	}
	
	private func makeNoiseLayer(in bounds: CGRect, opacity: Float) -> CALayer? {
		guard let filt = CIFilter(name: "CIRandomGenerator") else { return nil }
		let ciImage = filt.outputImage?.cropped(to: CGRect(origin: .zero, size: bounds.size))
		guard let img = ciImage else { return nil }
		let ctx = CIContext()
		guard let cg = ctx.createCGImage(img, from: img.extent) else { return nil }
		let noise = CALayer()
		noise.frame = bounds
		noise.contents = cg
		noise.opacity = opacity
		return noise
	}
} 