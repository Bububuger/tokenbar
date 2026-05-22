#!/usr/bin/env swift
// Renders the TokenBar macOS app icon at every Asset-Catalog size.
//
// Design source: docs/design-prd/tokenbar/ (TBMark in shell.jsx, BrandMarkBoard
// in menubar.jsx, .tb-mark styling in styles.css). Same visual DNA:
//   * ink-dark squircle (#18313D → #0B1A22 vertical) with a soft lime radial
//     at the lower-right (rgba(212,247,106,0.18))
//   * 3-bar histogram glyph — top teal #22C7C6, mid lime #D4F76A (the "live"
//     bar, longest), bottom darker teal #1F8A8A
//   * a small lime "cursor" square in the bottom-right corner (the blink dot)
//
// Output:
//   Resources/Assets.xcassets/AppIcon.appiconset/{*.png, Contents.json}
//
// Xcode's actool compiles the appiconset into Assets.car + AppIcon.icns
// at build time, so no standalone .icns is needed.

import AppKit
import CoreGraphics
import Foundation

// MARK: - Geometry

struct IconSlot {
    let pixelSize: Int                  // final raster size in pixels
    let idiomSize: String               // "16x16", "32x32", ...
    let scale: String                   // "1x" or "2x"
    var filename: String { "icon_\(idiomSize)@\(scale).png" }
}

let slots: [IconSlot] = [
    IconSlot(pixelSize: 16,   idiomSize: "16x16",   scale: "1x"),
    IconSlot(pixelSize: 32,   idiomSize: "16x16",   scale: "2x"),
    IconSlot(pixelSize: 32,   idiomSize: "32x32",   scale: "1x"),
    IconSlot(pixelSize: 64,   idiomSize: "32x32",   scale: "2x"),
    IconSlot(pixelSize: 128,  idiomSize: "128x128", scale: "1x"),
    IconSlot(pixelSize: 256,  idiomSize: "128x128", scale: "2x"),
    IconSlot(pixelSize: 256,  idiomSize: "256x256", scale: "1x"),
    IconSlot(pixelSize: 512,  idiomSize: "256x256", scale: "2x"),
    IconSlot(pixelSize: 512,  idiomSize: "512x512", scale: "1x"),
    IconSlot(pixelSize: 1024, idiomSize: "512x512", scale: "2x"),
]

// MARK: - Squircle (continuous-corner rounded rect, Apple-style)

func squirclePath(in rect: CGRect, cornerRatio: CGFloat = 0.225) -> CGPath {
    let r = min(rect.width, rect.height) * cornerRatio
    let path = CGMutablePath()
    let x = rect.minX, y = rect.minY, w = rect.width, h = rect.height
    let k: CGFloat = 0.55228  // cubic bezier circle approximation, smoothed
    let cr = r * (1.0 - k)

    path.move(to: CGPoint(x: x + r, y: y))
    path.addLine(to: CGPoint(x: x + w - r, y: y))
    path.addCurve(to: CGPoint(x: x + w, y: y + r),
                  control1: CGPoint(x: x + w - cr, y: y),
                  control2: CGPoint(x: x + w, y: y + cr))
    path.addLine(to: CGPoint(x: x + w, y: y + h - r))
    path.addCurve(to: CGPoint(x: x + w - r, y: y + h),
                  control1: CGPoint(x: x + w, y: y + h - cr),
                  control2: CGPoint(x: x + w - cr, y: y + h))
    path.addLine(to: CGPoint(x: x + r, y: y + h))
    path.addCurve(to: CGPoint(x: x, y: y + h - r),
                  control1: CGPoint(x: x + cr, y: y + h),
                  control2: CGPoint(x: x, y: y + h - cr))
    path.addLine(to: CGPoint(x: x, y: y + r))
    path.addCurve(to: CGPoint(x: x + r, y: y),
                  control1: CGPoint(x: x, y: y + cr),
                  control2: CGPoint(x: x + cr, y: y))
    path.closeSubpath()
    return path
}

func roundedRectPath(in rect: CGRect, radius: CGFloat) -> CGPath {
    return CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
}

// MARK: - Colors

extension CGColor {
    static func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
        return CGColor(srgbRed: r/255.0, green: g/255.0, blue: b/255.0, alpha: a)
    }
}

let inkTop      = CGColor.rgb(24,  49,  61)        // #18313D
let inkBottom   = CGColor.rgb(11,  26,  34)        // #0B1A22
let inkOuter    = CGColor.rgb(7,   18,  24)        // deeper edge
let limeAccent  = CGColor.rgb(212, 247, 106)       // #D4F76A
let teal        = CGColor.rgb(34,  199, 198)       // #22C7C6
let tealDark    = CGColor.rgb(31,  138, 138)       // #1F8A8A

// MARK: - Rendering

func renderIcon(size px: Int) -> CGImage {
    let cs = CGColorSpace(name: CGColorSpace.sRGB)!
    let ctx = CGContext(
        data: nil,
        width: px,
        height: px,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: cs,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    let canvas = CGRect(x: 0, y: 0, width: CGFloat(px), height: CGFloat(px))
    ctx.clear(canvas)

    // Apple icon margin: ~100/1024 transparent ring around the squircle.
    let inset = canvas.width * (100.0 / 1024.0)
    let tile = canvas.insetBy(dx: inset, dy: inset)

    // Drop shadow under the tile (very subtle).
    ctx.saveGState()
    ctx.setShadow(
        offset: CGSize(width: 0, height: -canvas.width * 0.012),
        blur: canvas.width * 0.030,
        color: CGColor.rgb(0, 0, 0, 0.55)
    )
    ctx.beginPath()
    ctx.addPath(squirclePath(in: tile))
    ctx.setFillColor(inkBottom)
    ctx.fillPath()
    ctx.restoreGState()

    // Clip to the squircle so all interior fills respect the rounded shape.
    ctx.saveGState()
    ctx.beginPath()
    ctx.addPath(squirclePath(in: tile))
    ctx.clip()

    // 1) Vertical ink gradient (top #18313D -> bottom #0B1A22).
    if let grad = CGGradient(
        colorsSpace: cs,
        colors: [inkTop, inkBottom, inkOuter] as CFArray,
        locations: [0.0, 0.78, 1.0]
    ) {
        ctx.drawLinearGradient(
            grad,
            start: CGPoint(x: tile.midX, y: tile.maxY),
            end: CGPoint(x: tile.midX, y: tile.minY),
            options: []
        )
    }

    // 2) Soft lime radial highlight at lower-right (matches .tb-mark CSS).
    //    radial-gradient(140% 90% at 70% 110%, rgba(212,247,106,0.18) -> 0)
    let glowCenter = CGPoint(x: tile.minX + tile.width * 0.72,
                             y: tile.minY + tile.height * 0.18)
    let glowRadius = tile.width * 0.95
    if let glow = CGGradient(
        colorsSpace: cs,
        colors: [
            CGColor.rgb(212, 247, 106, 0.28),
            CGColor.rgb(212, 247, 106, 0.0)
        ] as CFArray,
        locations: [0.0, 1.0]
    ) {
        ctx.drawRadialGradient(
            glow,
            startCenter: glowCenter, startRadius: 0,
            endCenter:   glowCenter, endRadius:   glowRadius,
            options: []
        )
    }

    // 3) Very subtle teal sheen top-left (depth, mirroring popover backdrop).
    if let sheen = CGGradient(
        colorsSpace: cs,
        colors: [
            CGColor.rgb(34, 199, 198, 0.10),
            CGColor.rgb(34, 199, 198, 0.0)
        ] as CFArray,
        locations: [0.0, 1.0]
    ) {
        let c = CGPoint(x: tile.minX + tile.width * 0.18,
                        y: tile.minY + tile.height * 0.88)
        ctx.drawRadialGradient(
            sheen,
            startCenter: c, startRadius: 0,
            endCenter:   c, endRadius:   tile.width * 0.7,
            options: []
        )
    }

    ctx.restoreGState()

    // 4) Inner top highlight + inner border (glass affordance).
    ctx.saveGState()
    ctx.beginPath()
    ctx.addPath(squirclePath(in: tile))
    ctx.setStrokeColor(CGColor.rgb(255, 255, 255, 0.10))
    ctx.setLineWidth(max(1.0, canvas.width * 0.0018))
    ctx.strokePath()
    ctx.restoreGState()

    // Top thin highlight stroke
    ctx.saveGState()
    let highlightInset = canvas.width * 0.004
    let highlightRect = tile.insetBy(dx: highlightInset, dy: highlightInset)
    ctx.beginPath()
    ctx.addPath(squirclePath(in: highlightRect))
    ctx.setStrokeColor(CGColor.rgb(255, 255, 255, 0.05))
    ctx.setLineWidth(max(0.5, canvas.width * 0.001))
    ctx.strokePath()
    ctx.restoreGState()

    // 5) The 3-bar histogram glyph (TBMark) — centered, slightly above center.
    //    Reference geometry from shell.jsx (viewBox 16):
    //      top  bar:  x=3, y=3.5,  w=6,    h=2.1
    //      mid  bar:  x=3, y=6.95, w=10,   h=2.1   (lime — live)
    //      bot  bar:  x=3, y=10.4, w=7.5,  h=2.1
    //    We re-anchor to tile-relative coords. Glyph occupies ~56% of tile width.
    let glyphBoxW = tile.width  * 0.58
    let glyphBoxH = tile.height * 0.40
    let glyphBox = CGRect(
        x: tile.minX + (tile.width  - glyphBoxW) * 0.5,
        y: tile.minY + (tile.height - glyphBoxH) * 0.5 + tile.height * 0.02,
        width:  glyphBoxW,
        height: glyphBoxH
    )

    // Within the glyph box, three rows with vertical gaps mirroring the JSX.
    // The JSX uses rows at y= 3.5 / 6.95 / 10.4 in a 16-unit box, with h=2.1.
    // Translate to glyphBox local coordinates (note: CG y is bottom-up).
    func bar(widthFrac: CGFloat, rowIndex: Int) -> CGRect {
        // rowIndex: 0 = top, 1 = middle, 2 = bottom
        let barH = glyphBox.height * (2.1 / (2.1 * 3 + 2 * 1.35)) // 3 bars + 2 gaps
        let gap  = glyphBox.height * (1.35 / (2.1 * 3 + 2 * 1.35))
        let totalH = barH * 3 + gap * 2
        let topY = glyphBox.maxY - (glyphBox.height - totalH) * 0.5
        let y = topY - barH - CGFloat(rowIndex) * (barH + gap)
        let w = glyphBox.width * widthFrac
        return CGRect(x: glyphBox.minX, y: y, width: w, height: barH)
    }

    let topRect = bar(widthFrac: 0.60, rowIndex: 0)
    let midRect = bar(widthFrac: 1.00, rowIndex: 1)
    let botRect = bar(widthFrac: 0.75, rowIndex: 2)
    let cornerR = topRect.height * 0.32

    // Subtle glow under the lime middle bar.
    ctx.saveGState()
    ctx.setShadow(
        offset: .zero,
        blur: canvas.width * 0.012,
        color: CGColor.rgb(212, 247, 106, 0.55)
    )
    ctx.beginPath()
    ctx.addPath(roundedRectPath(in: midRect, radius: cornerR))
    ctx.setFillColor(limeAccent)
    ctx.fillPath()
    ctx.restoreGState()

    // Top bar
    ctx.beginPath()
    ctx.addPath(roundedRectPath(in: topRect, radius: cornerR))
    ctx.setFillColor(teal)
    ctx.fillPath()

    // Re-fill the mid bar non-shadowed (cleaner edge).
    ctx.beginPath()
    ctx.addPath(roundedRectPath(in: midRect, radius: cornerR))
    ctx.setFillColor(limeAccent)
    ctx.fillPath()

    // Bottom bar
    ctx.beginPath()
    ctx.addPath(roundedRectPath(in: botRect, radius: cornerR))
    ctx.setFillColor(tealDark)
    ctx.fillPath()

    // 6) "Cursor blink" lime dot in the lower-right corner.
    //    Only meaningful above ~64px; skip at tiny sizes (16, 32) to prevent
    //    visual mud — the bars themselves carry brand recognition there.
    if px >= 64 {
        let cursorSide = tile.width * 0.045
        let cursorRect = CGRect(
            x: tile.maxX - tile.width * 0.13 - cursorSide,
            y: tile.minY + tile.height * 0.13,
            width: cursorSide,
            height: cursorSide * 2.2
        )
        ctx.saveGState()
        ctx.setShadow(
            offset: .zero,
            blur: canvas.width * 0.018,
            color: CGColor.rgb(212, 247, 106, 0.85)
        )
        ctx.beginPath()
        ctx.addPath(roundedRectPath(in: cursorRect, radius: cursorSide * 0.25))
        ctx.setFillColor(limeAccent)
        ctx.fillPath()
        ctx.restoreGState()
    }

    return ctx.makeImage()!
}

// MARK: - File writing

func writePNG(_ image: CGImage, to url: URL) {
    let rep = NSBitmapImageRep(cgImage: image)
    rep.size = NSSize(width: image.width, height: image.height)
    guard let data = rep.representation(using: .png, properties: [:]) else {
        fputs("failed to encode PNG for \(url.lastPathComponent)\n", stderr)
        exit(1)
    }
    do {
        try data.write(to: url, options: .atomic)
    } catch {
        fputs("failed to write \(url.path): \(error)\n", stderr)
        exit(1)
    }
}

// MARK: - Asset catalog Contents.json

func contentsJSON() -> String {
    var images: [[String: String]] = []
    for slot in slots {
        images.append([
            "size":     slot.idiomSize,
            "idiom":    "mac",
            "filename": slot.filename,
            "scale":    slot.scale,
        ])
    }
    let payload: [String: Any] = [
        "images": images,
        "info": ["version": 1, "author": "xcode"],
    ]
    let data = try! JSONSerialization.data(
        withJSONObject: payload,
        options: [.prettyPrinted, .sortedKeys]
    )
    return String(data: data, encoding: .utf8)!
}

// MARK: - Driver

let cwd = FileManager.default.currentDirectoryPath
let root = URL(fileURLWithPath: cwd)
let appiconset = root
    .appendingPathComponent("Resources")
    .appendingPathComponent("Assets.xcassets")
    .appendingPathComponent("AppIcon.appiconset")
let xcassetsDir = root
    .appendingPathComponent("Resources")
    .appendingPathComponent("Assets.xcassets")

try? FileManager.default.createDirectory(at: appiconset, withIntermediateDirectories: true)

// Asset-catalog "root" Contents.json
let rootContents = """
{
  "info" : {
    "author" : "xcode",
    "version" : 1
  }
}
"""
try? rootContents.write(
    to: xcassetsDir.appendingPathComponent("Contents.json"),
    atomically: true,
    encoding: .utf8
)

print("Rendering TokenBar app icon (\(slots.count) sizes)…")
for slot in slots {
    let img = renderIcon(size: slot.pixelSize)
    writePNG(img, to: appiconset.appendingPathComponent(slot.filename))
    print("  ✓ \(slot.filename)  (\(slot.pixelSize)px)")
}

// AppIcon.appiconset/Contents.json
try? contentsJSON().write(
    to: appiconset.appendingPathComponent("Contents.json"),
    atomically: true,
    encoding: .utf8
)

print("Done. Wrote:")
print("  \(appiconset.path)")
