import Foundation
import AppKit
import CoreGraphics

final class CursorView: NSView {
    var pressed = false
    override var isOpaque: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.clear.setFill()
        dirtyRect.fill()
        let path = NSBezierPath()
        path.move(to: NSPoint(x: 2, y: 24))
        path.line(to: NSPoint(x: 2, y: 2))
        path.line(to: NSPoint(x: 18, y: 17))
        path.line(to: NSPoint(x: 10, y: 18))
        path.close()
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowOffset = NSSize(width: 0, height: -1)
        shadow.shadowBlurRadius = 2.5
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.45)
        shadow.set()
        (pressed ? NSColor.systemBlue : NSColor.black).setFill()
        path.fill()
        NSGraphicsContext.restoreGraphicsState()
        NSColor.white.withAlphaComponent(0.95).setStroke()
        path.lineWidth = 2.2
        path.stroke()
    }
}

final class CursorController: NSObject {
    let panel: NSPanel
    let view: CursorView
    var visible = false
    var animationTimer: Timer?
    var animationStart = NSPoint.zero
    var animationEnd = NSPoint.zero
    var animationStarted = Date()
    var animationDuration = 0.0

    override init() {
        let frame = NSRect(x: -100, y: -100, width: 28, height: 28)
        panel = NSPanel(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        view = CursorView(frame: NSRect(x: 0, y: 0, width: 28, height: 28))
        super.init()
        panel.contentView = view
        panel.title = "Mac Developer Bridge AI Cursor"
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.level = .statusBar + 1
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
    }

    func appKitOrigin(globalX x: Double, globalY y: Double, displayId explicit: UInt32?) -> NSPoint? {
        for screen in NSScreen.screens {
            guard let id = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value else { continue }
            if let explicit, id != explicit { continue }
            let bounds = CGDisplayBounds(id)
            let point = CGPoint(x: x, y: y)
            guard bounds.contains(point) else { continue }
            let localX = x - bounds.minX
            let localY = y - bounds.minY
            return NSPoint(
                x: screen.frame.minX + localX - 2,
                y: screen.frame.minY + screen.frame.height - localY - 24
            )
        }
        return nil
    }

    func stopAnimation() {
        animationTimer?.invalidate()
        animationTimer = nil
    }

    @objc func tick(_ timer: Timer) {
        let elapsed = Date().timeIntervalSince(animationStarted)
        let progress = animationDuration <= 0 ? 1 : min(1, elapsed / animationDuration)
        let eased = 1 - pow(1 - progress, 3)
        panel.setFrameOrigin(NSPoint(
            x: animationStart.x + (animationEnd.x - animationStart.x) * eased,
            y: animationStart.y + (animationEnd.y - animationStart.y) * eased
        ))
        if progress >= 1 { stopAnimation() }
    }

    func place(_ command: [String: Any], animate: Bool) {
        var x = (command["x"] as? NSNumber)?.doubleValue ?? 0
        var y = (command["y"] as? NSNumber)?.doubleValue ?? 0
        var explicitDisplay: UInt32? = nil
        if let display = command["display_id"] as? NSNumber {
            explicitDisplay = display.uint32Value
            let bounds = CGDisplayBounds(display.uint32Value)
            x += bounds.minX
            y += bounds.minY
        }
        guard let origin = appKitOrigin(globalX: x, globalY: y, displayId: explicitDisplay) else {
            hide()
            return
        }
        let duration = max(0, min(10.0, ((command["duration_ms"] as? NSNumber)?.doubleValue ?? 160) / 1000.0))
        if animate && visible && duration > 0 {
            stopAnimation()
            animationStart = panel.frame.origin
            animationEnd = origin
            animationStarted = Date()
            animationDuration = duration
            animationTimer = Timer.scheduledTimer(timeInterval: 1.0 / 60.0, target: self, selector: #selector(tick(_:)), userInfo: nil, repeats: true)
        } else {
            stopAnimation()
            panel.setFrameOrigin(origin)
        }
        panel.orderFrontRegardless()
        visible = true
    }

    func hide() {
        stopAnimation()
        panel.orderOut(nil)
        visible = false
    }

    func click() {
        guard visible else { return }
        view.pressed = true
        view.needsDisplay = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.11) { [weak self] in
            self?.view.pressed = false
            self?.view.needsDisplay = true
        }
    }

    func handle(_ command: [String: Any]) {
        switch (command["action"] as? String)?.lowercased() {
        case "move": place(command, animate: true)
        case "show": place(command, animate: false)
        case "hide": hide()
        case "click": click()
        case "quit":
            hide()
            NSApp.terminate(nil)
        default: break
        }
    }
}

@main
struct MacUICursorOverlay {
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        let controller = CursorController()
        DispatchQueue.global(qos: .userInteractive).async {
            while let line = readLine() {
                guard let data = line.data(using: .utf8),
                      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
                DispatchQueue.main.async { controller.handle(object) }
            }
            DispatchQueue.main.async { controller.handle(["action": "quit"]) }
        }
        app.run()
    }
}
