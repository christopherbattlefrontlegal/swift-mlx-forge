// Forge — live Dock fire.
//
// macOS doesn't allow an animated icon at rest (Finder/Launchpad render a still
// .icns). But while the app is RUNNING we own the Dock icon — so Forge's Dock
// icon literally burns.
//
// Transport: `NSApp.applicationIconImage`, pushed ~8×/sec. Frames render OFF the
// main thread; only the NSImage handoff runs on main. The timer uses the default
// run-loop mode (not `.common`) and pauses during live window resize so split
// bars and edge drags stay responsive.

import AppKit

@MainActor
final class DockFlame {
    private var timer: Timer?
    private let renderer = FlameIconRenderer()
    private var pausedForResize = false
    private var renderGeneration = 0

    /// Paint the first animated frame immediately so the Dock never flashes the
    /// static bundle icon before the flame loop starts.
    func prime() {
        NSApp.applicationIconImage = renderer.renderNextFrame()
    }

    func start() {
        prime()
        startTimer()
        let nc = NotificationCenter.default
        nc.addObserver(
            self, selector: #selector(pause),
            name: NSApplication.didHideNotification, object: nil)
        nc.addObserver(
            self, selector: #selector(resume),
            name: NSApplication.didUnhideNotification, object: nil)
        nc.addObserver(
            self, selector: #selector(pauseForResize),
            name: NSWindow.willStartLiveResizeNotification, object: nil)
        nc.addObserver(
            self, selector: #selector(resumeFromResize),
            name: NSWindow.didEndLiveResizeNotification, object: nil)
    }

    func stop() {
        NotificationCenter.default.removeObserver(self)
        timer?.invalidate()
        timer = nil
        renderGeneration += 1
        NSApp.applicationIconImage = nil
    }

    private func startTimer() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 8.0, repeats: true) { [weak self] _ in
            self?.pushNextFrame()
        }
        // Default mode — do NOT use `.common` (that fires during resize drags and
        // competes with window splitters / sliders for main-thread time).
        RunLoop.main.add(timer, forMode: .default)
        self.timer = timer
    }

    private func pushNextFrame() {
        guard !pausedForResize else { return }
        let generation = renderGeneration
        let image = renderer.renderNextFrame()
        guard generation == renderGeneration else { return }
        NSApp.applicationIconImage = image
    }

    @objc private func pause() {
        timer?.invalidate()
        timer = nil
    }

    @objc private func resume() {
        guard !pausedForResize else { return }
        startTimer()
        pushNextFrame()
    }

    @objc private func pauseForResize() {
        pausedForResize = true
        timer?.invalidate()
        timer = nil
    }

    @objc private func resumeFromResize() {
        pausedForResize = false
        startTimer()
        pushNextFrame()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }
}

/// Renders one flame frame as an NSImage. Thread-safe — drawing never blocks UI.
private final class FlameIconRenderer: @unchecked Sendable {
    private let lock = NSLock()
    private var phase: Double = 0
    private let side: CGFloat = 256

    private let deep = NSColor(red: 0.86, green: 0.22, blue: 0.10, alpha: 1)
    private let ember = NSColor(red: 1.00, green: 0.42, blue: 0.21, alpha: 1)
    private let glow = NSColor(red: 1.00, green: 0.62, blue: 0.26, alpha: 1)
    private let gold = NSColor(red: 1.00, green: 0.86, blue: 0.45, alpha: 1)
    private let core = NSColor(red: 1.00, green: 0.97, blue: 0.85, alpha: 1)

    func renderNextFrame() -> NSImage {
        lock.lock()
        phase += 1.0 / 8.0
        let t = phase
        lock.unlock()

        let size = NSSize(width: side, height: side)
        let image = NSImage(size: size)
        image.lockFocus()
        if let ctx = NSGraphicsContext.current?.cgContext {
            draw(ctx, w: side, h: side, t: t)
        }
        image.unlockFocus()
        return image
    }

    private func draw(_ ctx: CGContext, w: CGFloat, h: CGFloat, t: Double) {
        let cx = w / 2
        let baseY = h * 0.14

        let inset = w * 0.06
        let basePath = CGPath(
            roundedRect: CGRect(x: inset, y: inset, width: w - inset * 2, height: h - inset * 2),
            cornerWidth: w * 0.22, cornerHeight: w * 0.22, transform: nil)
        ctx.addPath(basePath)
        ctx.clip()
        drawLinear(
            ctx,
            colors: [
                NSColor(red: 0.10, green: 0.09, blue: 0.12, alpha: 1),
                NSColor(red: 0.04, green: 0.04, blue: 0.06, alpha: 1),
            ],
            locations: [0, 1],
            start: CGPoint(x: 0, y: h), end: CGPoint(x: 0, y: 0))

        let pulse = 0.75 + 0.25 * sin(t * 1.9) * sin(t * 0.63)
        if let g = gradient(
            [ember.withAlphaComponent(0.50 * pulse), deep.withAlphaComponent(0)],
            locations: [0, 1])
        {
            let center = CGPoint(x: cx, y: h * 0.34)
            ctx.drawRadialGradient(
                g, startCenter: center, startRadius: 0,
                endCenter: center, endRadius: w * 0.46, options: [])
        }

        ctx.setBlendMode(.plusLighter)
        tongue(
            ctx, cx: cx, baseY: baseY, width: w * 0.56, height: h * 0.66,
            t: t, f: 1.6, sway: w * 0.035,
            colors: [deep, ember, glow], locations: [0, 0.55, 1])
        tongue(
            ctx, cx: cx, baseY: baseY + h * 0.015, width: w * 0.35, height: h * 0.47,
            t: t + 1.37, f: 2.5, sway: w * 0.042,
            colors: [ember, gold], locations: [0, 1])
        tongue(
            ctx, cx: cx, baseY: baseY + h * 0.03, width: w * 0.20, height: h * 0.30,
            t: t + 2.18, f: 3.3, sway: w * 0.035,
            colors: [gold, core], locations: [0, 1])

        for i in 0..<5 {
            let fi = Double(i)
            let speed = 0.15 + 0.045 * fi
            let rise = (t * speed + fi * 0.41).truncatingRemainder(dividingBy: 1.0)
            let y = baseY + rise * h * 0.66
            let x = cx + sin(t * (1.4 + fi * 0.35) + fi * 2.1) * w * 0.07
            let fade = sin(rise * .pi)
            let r = w * (0.010 + 0.005 * fi.truncatingRemainder(dividingBy: 3))
            ctx.setFillColor(
                (i % 2 == 0 ? glow : gold).withAlphaComponent(0.8 * fade).cgColor)
            ctx.fillEllipse(in: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2))
        }
        ctx.setBlendMode(.normal)
    }

    private func tongue(
        _ ctx: CGContext, cx: CGFloat, baseY: CGFloat, width: CGFloat,
        height: CGFloat, t: Double, f: Double, sway: CGFloat,
        colors: [NSColor], locations: [CGFloat]
    ) {
        let flick = 0.86 + 0.10 * sin(t * f * 1.9) + 0.04 * sin(t * f * 3.7 + 1.2)
        let tipX = cx + (sin(t * f) * 0.6 + sin(t * f * 0.43 + 0.8) * 0.4) * sway
        let tipY = baseY + height * CGFloat(flick)
        let half = width / 2
        let midSway = CGFloat(sin(t * f * 0.8 + 1.0)) * sway * 0.7

        let path = CGMutablePath()
        path.move(to: CGPoint(x: cx - half, y: baseY))
        path.addCurve(
            to: CGPoint(x: tipX, y: tipY),
            control1: CGPoint(x: cx - half + midSway, y: baseY + height * 0.45),
            control2: CGPoint(x: tipX - half * 0.28, y: tipY - height * 0.25))
        path.addCurve(
            to: CGPoint(x: cx + half, y: baseY),
            control1: CGPoint(x: tipX + half * 0.28, y: tipY - height * 0.25),
            control2: CGPoint(x: cx + half + midSway, y: baseY + height * 0.45))
        path.addQuadCurve(
            to: CGPoint(x: cx - half, y: baseY),
            control: CGPoint(x: cx, y: baseY - width * 0.30))
        path.closeSubpath()

        ctx.saveGState()
        ctx.addPath(path)
        ctx.clip()
        drawLinear(
            ctx, colors: colors, locations: locations,
            start: CGPoint(x: cx, y: baseY), end: CGPoint(x: tipX, y: tipY))
        ctx.restoreGState()
    }

    private func drawLinear(
        _ ctx: CGContext, colors: [NSColor], locations: [CGFloat],
        start: CGPoint, end: CGPoint
    ) {
        if let g = gradient(colors, locations: locations) {
            ctx.drawLinearGradient(g, start: start, end: end, options: [])
        }
    }

    private func gradient(_ colors: [NSColor], locations: [CGFloat]) -> CGGradient? {
        CGGradient(
            colorsSpace: CGColorSpaceCreateDeviceRGB(),
            colors: colors.map(\.cgColor) as CFArray,
            locations: locations)
    }
}