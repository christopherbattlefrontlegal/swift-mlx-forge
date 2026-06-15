// Forge — design tokens. Molten-metal-on-graphite: deep neutral surfaces,
// an ember gradient for identity and accents, glass panels for chrome.

import SwiftUI

enum Theme {
    // Spacing (8pt grid)
    static let s1: CGFloat = 4
    static let s2: CGFloat = 8
    static let s3: CGFloat = 12
    static let s4: CGFloat = 16
    static let s5: CGFloat = 24
    static let s6: CGFloat = 32

    // Radius
    static let radiusSmall: CGFloat = 8
    static let radiusMedium: CGFloat = 12
    static let radiusLarge: CGFloat = 16

    // Palette
    static let ember = Color(red: 1.00, green: 0.42, blue: 0.21)
    static let emberDeep = Color(red: 0.86, green: 0.22, blue: 0.10)
    static let emberGlow = Color(red: 1.00, green: 0.62, blue: 0.26)
    static let steel = Color(red: 0.55, green: 0.60, blue: 0.68)
    static let okGreen = Color(red: 0.35, green: 0.78, blue: 0.45)

    static let emberGradient = LinearGradient(
        colors: [emberGlow, ember, emberDeep],
        startPoint: .topLeading, endPoint: .bottomTrailing)

    static let backgroundGradient = LinearGradient(
        colors: [
            Color(red: 0.09, green: 0.09, blue: 0.11),
            Color(red: 0.05, green: 0.05, blue: 0.07),
        ],
        startPoint: .top, endPoint: .bottom)

    static let userBubble = Color(red: 0.16, green: 0.17, blue: 0.21)
    static let assistantBubble = Color(red: 0.11, green: 0.11, blue: 0.14)
    static let codeBackground = Color(red: 0.07, green: 0.07, blue: 0.09)
}

/// A subtle glass card used for panels and grouped content.
struct GlassCard: ViewModifier {
    var radius: CGFloat = Theme.radiusMedium

    func body(content: Content) -> some View {
        content
            .background(.ultraThinMaterial)
            .clipShape(.rect(cornerRadius: radius))
            .overlay(
                RoundedRectangle(cornerRadius: radius)
                    .strokeBorder(.white.opacity(0.08), lineWidth: 1)
            )
    }
}

extension View {
    func glassCard(radius: CGFloat = Theme.radiusMedium) -> some View {
        modifier(GlassCard(radius: radius))
    }
}

/// The Forge mark: a living flame. Procedural — layered tongues swaying on
/// incommensurate sine frequencies, so the motion never visibly repeats.
/// Gentle by design: low sway amplitude, slow flicker, soft additive glow.
struct ForgeMark: View {
    var size: CGFloat = 20

    // Ember palette, base → tip.
    private static let deep = Color(red: 0.86, green: 0.22, blue: 0.10)
    private static let ember = Color(red: 1.00, green: 0.42, blue: 0.21)
    private static let glow = Color(red: 1.00, green: 0.62, blue: 0.26)
    private static let gold = Color(red: 1.00, green: 0.86, blue: 0.45)
    private static let core = Color(red: 1.00, green: 0.97, blue: 0.85)

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            Canvas { ctx, canvasSize in
                Self.draw(&ctx, size: canvasSize, t: t)
            }
        }
        .frame(width: size * 1.3, height: size * 1.45)
        .accessibilityHidden(true)
    }

    private static func draw(_ ctx: inout GraphicsContext, size: CGSize, t: TimeInterval) {
        let w = size.width
        let h = size.height
        let cx = w / 2
        let baseY = h * 0.94

        // Soft breathing glow behind everything.
        let pulse = 0.75 + 0.25 * sin(t * 1.9) * sin(t * 0.63)
        ctx.fill(
            Path(ellipseIn: CGRect(x: cx - w * 0.55, y: h * 0.25, width: w * 1.1, height: h * 0.75)),
            with: .radialGradient(
                Gradient(colors: [glow.opacity(0.30 * pulse), .clear]),
                center: CGPoint(x: cx, y: h * 0.70),
                startRadius: 0, endRadius: w * 0.62))

        ctx.blendMode = .plusLighter

        // Three nested tongues: slow outer body, livelier middle, bright core.
        tongue(
            &ctx, cx: cx, baseY: baseY, width: w * 0.74, height: h * 0.84,
            t: t, f: 1.6, sway: w * 0.045,
            gradient: Gradient(stops: [
                .init(color: deep, location: 0),
                .init(color: ember, location: 0.55),
                .init(color: glow, location: 1),
            ]))
        tongue(
            &ctx, cx: cx, baseY: baseY - h * 0.02, width: w * 0.46, height: h * 0.60,
            t: t + 1.37, f: 2.5, sway: w * 0.055,
            gradient: Gradient(colors: [ember, gold]))
        tongue(
            &ctx, cx: cx, baseY: baseY - h * 0.04, width: w * 0.26, height: h * 0.38,
            t: t + 2.18, f: 3.3, sway: w * 0.045,
            gradient: Gradient(colors: [gold, core]))

        // A few drifting sparks, faded in and out over their rise.
        for i in 0..<3 {
            let fi = Double(i)
            let speed = 0.16 + 0.05 * fi
            let rise = (t * speed + fi * 0.41).truncatingRemainder(dividingBy: 1.0)
            let y = baseY - rise * h * 0.80
            let x = cx + sin(t * (1.4 + fi * 0.35) + fi * 2.1) * w * 0.09
            let fade = sin(rise * .pi)
            let r = w * (0.022 + 0.008 * fi)
            ctx.fill(
                Path(ellipseIn: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2)),
                with: .color((i == 1 ? gold : glow).opacity(0.75 * fade)))
        }

        ctx.blendMode = .normal
    }

    /// One flame tongue: a teardrop whose tip sways and whose height flickers
    /// on two incommensurate frequencies, with a rounded belly at the base.
    private static func tongue(
        _ ctx: inout GraphicsContext, cx: CGFloat, baseY: CGFloat,
        width: CGFloat, height: CGFloat, t: TimeInterval, f: Double,
        sway: CGFloat, gradient: Gradient
    ) {
        let flick = 0.86 + 0.10 * sin(t * f * 1.9) + 0.04 * sin(t * f * 3.7 + 1.2)
        let tipX = cx + (sin(t * f) * 0.6 + sin(t * f * 0.43 + 0.8) * 0.4) * sway
        let tipY = baseY - height * flick
        let half = width / 2
        let midSway = sin(t * f * 0.8 + 1.0) * sway * 0.7

        var path = Path()
        path.move(to: CGPoint(x: cx - half, y: baseY))
        path.addCurve(
            to: CGPoint(x: tipX, y: tipY),
            control1: CGPoint(x: cx - half + midSway, y: baseY - height * 0.45),
            control2: CGPoint(x: tipX - half * 0.28, y: tipY + height * 0.25))
        path.addCurve(
            to: CGPoint(x: cx + half, y: baseY),
            control1: CGPoint(x: tipX + half * 0.28, y: tipY + height * 0.25),
            control2: CGPoint(x: cx + half + midSway, y: baseY - height * 0.45))
        path.addQuadCurve(
            to: CGPoint(x: cx - half, y: baseY),
            control: CGPoint(x: cx, y: baseY + width * 0.30))
        path.closeSubpath()

        ctx.fill(
            path,
            with: .linearGradient(
                gradient,
                startPoint: CGPoint(x: cx, y: baseY),
                endPoint: CGPoint(x: tipX, y: tipY)))
    }
}
