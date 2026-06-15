#!/usr/bin/env swift
// Forge — app icon renderer.
//
// Draws the Forge flame mark (the same ember flame used in-app and in the live
// Dock fire) onto a dark rounded-square tile, at every macOS iconset size, then
// hands off to `iconutil` to produce AppIcon.icns. Pure CoreGraphics — no
// external image model, no third-party/trademarked art.

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

// Ember palette (matches Theme.swift).
func rgb(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) -> CGColor {
    CGColor(red: r, green: g, blue: b, alpha: a)
}
let bgTop = rgb(0.11, 0.10, 0.13)
let bgBottom = rgb(0.04, 0.04, 0.06)
let deep = rgb(0.86, 0.22, 0.10)
let ember = rgb(1.00, 0.42, 0.21)
let glow = rgb(1.00, 0.62, 0.26)
let gold = rgb(1.00, 0.86, 0.45)

let space = CGColorSpaceCreateDeviceRGB()

func flamePath(_ S: CGFloat) -> CGPath {
    // Unit coordinates (y up), scaled by S.
    func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x * S, y: y * S) }
    let path = CGMutablePath()
    path.move(to: p(0.43, 0.31))
    // wide rounded bottom
    path.addCurve(to: p(0.57, 0.31), control1: p(0.43, 0.18), control2: p(0.57, 0.18))
    // right side swelling out then tapering to a tip that leans slightly right
    path.addCurve(to: p(0.55, 0.82), control1: p(0.70, 0.47), control2: p(0.655, 0.70))
    // tip curling down-left to a hook
    path.addCurve(to: p(0.435, 0.66), control1: p(0.50, 0.78), control2: p(0.45, 0.73))
    // a small concave lick on the left (what makes it read as flame, not leaf)
    path.addCurve(to: p(0.40, 0.50), control1: p(0.455, 0.62), control2: p(0.40, 0.58))
    // back down to the start
    path.addCurve(to: p(0.43, 0.31), control1: p(0.40, 0.44), control2: p(0.42, 0.40))
    path.closeSubpath()
    return path
}

func render(size px: Int) -> CGImage? {
    let S = CGFloat(px)
    guard let ctx = CGContext(
        data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0,
        space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { return nil }

    // --- Rounded-square tile ---
    let inset = S * 0.045
    let rect = CGRect(x: inset, y: inset, width: S - inset * 2, height: S - inset * 2)
    let tile = CGPath(
        roundedRect: rect, cornerWidth: S * 0.185, cornerHeight: S * 0.185, transform: nil)
    ctx.saveGState()
    ctx.addPath(tile)
    ctx.clip()
    if let bg = CGGradient(colorsSpace: space, colors: [bgTop, bgBottom] as CFArray,
        locations: [0, 1]) {
        ctx.drawLinearGradient(
            bg, start: CGPoint(x: 0, y: S), end: CGPoint(x: 0, y: 0), options: [])
    }

    // --- Soft ember glow behind the flame ---
    let cx = S * 0.5, cy = S * 0.5
    if let g = CGGradient(colorsSpace: space,
        colors: [ember.copy(alpha: 0.45)!, deep.copy(alpha: 0)!] as CFArray, locations: [0, 1]) {
        ctx.drawRadialGradient(
            g, startCenter: CGPoint(x: cx, y: cy), startRadius: 0,
            endCenter: CGPoint(x: cx, y: cy), endRadius: S * 0.40, options: [])
    }

    // --- Flame (vertical ember gradient) ---
    let flame = flamePath(S)
    ctx.saveGState()
    ctx.addPath(flame)
    ctx.clip()
    if let g = CGGradient(colorsSpace: space,
        colors: [deep, ember, glow, gold] as CFArray, locations: [0, 0.45, 0.78, 1]) {
        ctx.drawLinearGradient(
            g, start: CGPoint(x: cx, y: S * 0.28), end: CGPoint(x: cx, y: S * 0.82), options: [])
    }
    ctx.restoreGState()

    // --- Soft hot core (radial glow inside the flame, not a hard shape) ---
    ctx.saveGState()
    ctx.addPath(flame)
    ctx.clip()
    let hot = CGPoint(x: cx, y: S * 0.46)
    if let g = CGGradient(colorsSpace: space,
        colors: [gold.copy(alpha: 0.9)!, glow.copy(alpha: 0.0)!] as CFArray, locations: [0, 1]) {
        ctx.drawRadialGradient(
            g, startCenter: hot, startRadius: 0, endCenter: hot, endRadius: S * 0.16, options: [])
    }
    ctx.restoreGState()

    ctx.restoreGState()  // tile clip
    return ctx.makeImage()
}

func writePNG(_ image: CGImage, to url: URL) {
    guard let dest = CGImageDestinationCreateWithURL(
        url as CFURL, UTType.png.identifier as CFString, 1, nil) else { return }
    CGImageDestinationAddImage(dest, image, nil)
    CGImageDestinationFinalize(dest)
}

// --- Build the .iconset ---
let outDir = URL(fileURLWithPath: CommandLine.arguments.count > 1
    ? CommandLine.arguments[1] : "assets")
let iconset = outDir.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

let specs: [(name: String, px: Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]
for spec in specs {
    if let img = render(size: spec.px) {
        writePNG(img, to: iconset.appendingPathComponent("\(spec.name).png"))
    }
}
print("Wrote \(iconset.path)")
