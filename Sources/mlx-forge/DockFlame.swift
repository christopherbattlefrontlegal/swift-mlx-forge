// Forge — live Dock fire.
//
// macOS doesn't allow an animated icon at rest (Finder/Launchpad render a still
// .icns). But while the app is RUNNING we own the Dock icon — so Forge's Dock
// icon literally burns.
//
// Transport: `NSApp.applicationIconImage`, pushed ~20×/sec. We deliberately do
// NOT use `dockTile.contentView`: custom tile views render inside the Dock's
// shared tile-host process, and a buggy third-party dock plugin crashing that
// host (observed in the wild: OpenAI Codex's plugin segfaulting it) silently
// kills every app's tile animation until relaunch. Icon-image updates go to the
// main Dock process and are re-sent every frame, so the flame self-heals even
// after a Dock crash. On quit the bundle's static icon is restored.

import AppKit

@MainActor
final class DockFlame {
    private var timer: Timer?
    private let renderer = FlameIconRenderer()

    func start() {
        startTimer()
        // Stop burning CPU (20 wakeups/sec) while the app is hidden — there's no
        // visible Dock animation worth paying for then.
        let nc = NotificationCenter.default
        nc.addObserver(
            self, selector: #selector(pause),
            name: NSApplication.didHideNotification, object: nil)
        nc.addObserver(
            self, selector: #selector(resume),
            name: NSApplication.didUnhideNotification, object: nil)
    }

    func stop() {
        NotificationCenter.default.removeObserver(self)
        timer?.invalidate()
        timer = nil
        NSApp.applicationIconImage = nil  // restore the bundle's static icon
    }

    private func startTimer() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 20.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                NSApp.applicationIconImage = self.renderer.nextFrame()
            }
        }
        // .common so the flame keeps burning during menu tracking / window resize.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    @objc private func pause() {
        timer?.invalidate()
        timer = nil
    }

    @objc private func resume() {
        startTimer()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }
}

/// Renders one flame frame as an NSImage: dark glass base, breathing ember
/// glow, three nested flame tongues swaying on incommensurate frequencies
/// (so the motion never visibly repeats), and drifting sparks. Mirrors the
/// in-app ForgeMark flame so the Dock and the sidebar burn the same fire.
@MainActor
private final class FlameIconRenderer {
    private var phase: Double = 0
    private let side: CGFloat = 256

    // Ember palette (matches Theme.swift / ForgeMark).
    private let deep = NSColor(red: 0.86, green: 0.22, blue: 0.10, alpha: 1)
    private let ember = NSColor(red: 1.00, green: 0.42, blue: 0.21, alpha: 1)
    private let glow = NSColor(red: 1.00, green: 0.62, blue: 0.26, alpha: 1)
    private let gold = NSColor(red: 1.00, green: 0.86, blue: 0.45, alpha: 1)
    private let core = NSColor(red: 1.00, green: 0.97, blue: 0.85, alpha: 1)

    func nextFrame() -> NSImage {
        phase += 1.0 / 20.0
        let size = NSSize(width: side, height: side)
        let image = NSImage(size: size)
        image.lockFocus()
        if let ctx = NSGraphicsContext.current?.cgContext {
            draw(ctx, w: side, h: side, t: phase)
        }
        image.unlockFocus()
        return image
    }

    // CG coordinates: origin bottom-left, y grows upward.
    private func draw(_ ctx: CGContext, w: CGFloat, h: CGFloat, t: Double) {
        let cx = w / 2
        let baseY = h * 0.14

        // --- Dark glass base (rounded square, like a real app icon) ---
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

        // --- Breathing ember glow ---
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

        // --- Three nested tongues (additive for glow) ---
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

        // --- Drifting sparks, faded in and out over their rise ---
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

    /// One flame tongue: teardrop with a rounded belly; tip sway and height
    /// flicker driven by two incommensurate sine frequencies.
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
