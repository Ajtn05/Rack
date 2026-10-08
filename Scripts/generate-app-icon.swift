#!/usr/bin/swift
//
// generate-app-icon.swift — draws Rack's icon and rasterises it into
// Resources/AppIcon.icns.
//
//   swift Scripts/generate-app-icon.swift
//
// The mark is a VU needle mid-deflection on a cream meter face, set into a
// gunmetal plate — the same instrument every theme in DesignSystem draws in
// some form, since it is the one glance that reads "hi-fi hardware, not a
// generic audio app" even at 16×16. Drawn with AppKit's own path/gradient
// primitives rather than authored in a design tool and imported, so the mark
// can be regenerated here if it ever needs to change, the same way the rest
// of this codebase treats its visuals as code rather than assets.
//
// Run whenever the design changes; the output — Resources/AppIcon.icns — is
// checked in like any other bundled resource, since macOS can only take an
// app icon as a static image, unlike everything DesignSystem draws live.

import AppKit
import Foundation

// MARK: - The mark

/// Draws the icon into a fresh `NSImage` at `size`×`size`. Every metric below
/// is a fraction of `size` rather than a fixed point value, so the same
/// function produces a crisp 16pt glyph and a crisp 1024pt master — nothing
/// here is a downscaled copy of anything else.
func drawIcon(size: CGFloat) -> NSImage {
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()
    defer { image.unlockFocus() }

    guard let context = NSGraphicsContext.current?.cgContext else { return image }
    context.setShouldAntialias(true)

    // Below 128px, tick marks sized as a fraction of `size` fall under a
    // point wide and vanish into the beige of the face — a real VU meter
    // photographed from across the room does the same thing, and a Dock or
    // Finder-list icon is that photograph. Professional icon sets are hand-
    // simplified per size for exactly this reason rather than one drawing
    // scaled down, so below the threshold this drops the ticks and draws a
    // visibly heavier needle and bezel instead of a thinner version of the
    // same composition.
    let isCompact = size <= 64

    let bounds = CGRect(x: 0, y: 0, width: size, height: size)

    // --- Outer plate -------------------------------------------------------
    // A macOS-style continuous corner, approximated with a rounded rect —
    // exact superellipse math buys nothing a viewer would notice at any of
    // these sizes.
    let plateInset = size * 0.045
    let plateRect = bounds.insetBy(dx: plateInset, dy: plateInset)
    let plateRadius = plateRect.width * 0.22
    let platePath = NSBezierPath(roundedRect: plateRect, xRadius: plateRadius, yRadius: plateRadius)

    let plateGradient = NSGradient(colors: [
        NSColor(calibratedWhite: 0.26, alpha: 1),
        NSColor(calibratedWhite: 0.10, alpha: 1)
    ])
    plateGradient?.draw(in: platePath, angle: -90)

    // A hairline top highlight — the same single-pixel bevel every brushed
    // panel in DesignSystem's own themes uses to read as metal instead of
    // flat color.
    context.saveGState()
    plateGradient.map { _ in () }
    let bevel = NSBezierPath()
    bevel.move(to: NSPoint(x: plateRect.minX + plateRadius * 0.6, y: plateRect.maxY - size * 0.006))
    bevel.line(to: NSPoint(x: plateRect.maxX - plateRadius * 0.6, y: plateRect.maxY - size * 0.006))
    bevel.lineWidth = size * 0.008
    NSColor(calibratedWhite: 1, alpha: 0.16).setStroke()
    bevel.stroke()
    context.restoreGState()

    // --- Meter face ----------------------------------------------------------
    let faceInsetSide = plateRect.width * 0.16
    let faceInsetTop = plateRect.height * 0.14
    let faceInsetBottom = plateRect.height * 0.30
    let faceRect = CGRect(
        x: plateRect.minX + faceInsetSide,
        y: plateRect.minY + faceInsetBottom,
        width: plateRect.width - faceInsetSide * 2,
        height: plateRect.height - faceInsetTop - faceInsetBottom
    )
    let faceRadius = faceRect.width * 0.06
    let facePath = NSBezierPath(roundedRect: faceRect, xRadius: faceRadius, yRadius: faceRadius)

    // A thin amber bezel around the face — the one warm accent, echoing the
    // glow every "emissive" VFD/readout style in DesignSystem's themes uses,
    // and the only saturated colour in the whole mark.
    context.saveGState()
    let bezelWidth = size * (isCompact ? 0.032 : 0.014)
    let bezelPath = NSBezierPath(
        roundedRect: faceRect.insetBy(dx: -size * 0.012, dy: -size * 0.012),
        xRadius: faceRadius, yRadius: faceRadius
    )
    bezelPath.lineWidth = bezelWidth
    NSColor(calibratedRed: 0.75, green: 0.53, blue: 0.16, alpha: 0.9).setStroke()
    bezelPath.stroke()
    context.restoreGState()

    let faceGradient = NSGradient(colors: [
        NSColor(calibratedRed: 0.95, green: 0.90, blue: 0.79, alpha: 1),
        NSColor(calibratedRed: 0.85, green: 0.79, blue: 0.65, alpha: 1)
    ])
    faceGradient?.draw(in: facePath, angle: -90)

    facePath.setClip()

    // --- Tick arc ------------------------------------------------------------
    // The needle's pivot sits below the face and out of view — a real VU
    // meter's arc is a shallow slice of a much larger circle, which is what
    // keeps the ticks reading as parallel-ish radii rather than a tight fan.
    let pivot = CGPoint(x: faceRect.midX, y: faceRect.minY - faceRect.height * 0.55)
    let arcRadius = faceRect.height * 1.55

    // ±18° either side of vertical is what actually stays inside the face's
    // horizontal bounds at this pivot distance — the first version swept
    // ±40° and lost four of its seven ticks past the face's own clip.
    //
    // Skipped entirely at compact sizes — see `isCompact`'s own comment.
    if !isCompact {
        let tickCount = 5
        let startAngle: CGFloat = 108   // degrees, measured from +x axis
        let endAngle: CGFloat = 72
        for index in 0..<tickCount {
            let t = CGFloat(index) / CGFloat(tickCount - 1)
            let angle = (startAngle + (endAngle - startAngle) * t) * .pi / 180
            let outer = CGPoint(
                x: pivot.x + arcRadius * cos(angle),
                y: pivot.y + arcRadius * sin(angle)
            )
            let inner = CGPoint(
                x: pivot.x + (arcRadius - faceRect.height * 0.16) * cos(angle),
                y: pivot.y + (arcRadius - faceRect.height * 0.16) * sin(angle)
            )
            let tick = NSBezierPath()
            tick.move(to: inner)
            tick.line(to: outer)
            tick.lineWidth = size * (index == tickCount - 1 ? 0.012 : 0.007)
            // The last tick — the top of the scale — reads hot, the same red
            // a real VU meter's overload zone uses.
            let color = index == tickCount - 1
                ? NSColor(calibratedRed: 0.72, green: 0.16, blue: 0.12, alpha: 1)
                : NSColor(calibratedWhite: 0.15, alpha: 0.6)
            color.setStroke()
            tick.stroke()
        }
    }

    // --- Needle ----------------------------------------------------------------
    // Deflected past the last tick into the red — mid-signal-hot, not resting
    // at zero and not sitting placidly mid-scale, the one moment that reads
    // as "this thing is alive and driving" rather than "this thing is off."
    let needleAngle: CGFloat = 66 * .pi / 180
    let needleLength = arcRadius * 0.94
    let tip = CGPoint(
        x: pivot.x + needleLength * cos(needleAngle),
        y: pivot.y + needleLength * sin(needleAngle)
    )
    // A tapered wedge rather than a stroked line — a stroke of constant width
    // reads as a hairline at icon sizes; a wedge stays a *needle*, wide at
    // the pivot and fine at the tip, all the way down to 16px.
    let perp = CGPoint(x: -sin(needleAngle), y: cos(needleAngle))
    let baseHalfWidth = size * (isCompact ? 0.034 : 0.012)
    let needle = NSBezierPath()
    needle.move(to: CGPoint(x: pivot.x + perp.x * baseHalfWidth, y: pivot.y + perp.y * baseHalfWidth))
    needle.line(to: tip)
    needle.line(to: CGPoint(x: pivot.x - perp.x * baseHalfWidth, y: pivot.y - perp.y * baseHalfWidth))
    needle.close()
    NSColor(calibratedRed: 0.62, green: 0.11, blue: 0.09, alpha: 1).setFill()
    needle.fill()

    // Pivot cap.
    let capRadius = size * (isCompact ? 0.05 : 0.022)
    let cap = NSBezierPath(ovalIn: CGRect(
        x: pivot.x - capRadius, y: pivot.y - capRadius,
        width: capRadius * 2, height: capRadius * 2
    ))
    NSColor(calibratedWhite: 0.08, alpha: 1).setFill()
    cap.fill()

    context.resetClip()
    return image
}

// MARK: - The menu bar glyph

/// The same needle-mid-deflection mark as `drawIcon`, redrawn as a standalone
/// silhouette on a transparent background — no plate, no face, no colour —
/// for use as a macOS status-item template image.
///
/// A template image is what every other app's monochrome menu bar icon is:
/// `isTemplate = true` tells AppKit to read only this bitmap's *alpha*
/// channel and paint it with whatever the menu bar's own current appearance
/// calls for, which is what lets one asset sit correctly in both a light and
/// a dark menu bar without this script knowing which it will be. Filled in
/// solid black here for that reason — the colour is discarded, only the
/// shape survives.
///
/// A SwiftUI `Canvas` drawn directly as the `MenuBarExtra` label was the
/// first approach; it produced a correctly-sized status item that had
/// nothing legible drawn on it. `NSStatusItem` content has always meant
/// `NSImage`, and reaching for the same AppKit path-drawing this file already
/// uses for the Dock icon — proven to render correctly — is the direct route
/// to a mark that shows up, not the first thing that happened to compile.
func drawMenuBarGlyph(pixels: Int) -> NSImage {
    let size = CGFloat(pixels)
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()
    defer { image.unlockFocus() }

    let pivot = CGPoint(x: size * 0.42, y: -size * 0.35)
    let armLength = size * 1.28

    let ticks = NSBezierPath()
    ticks.lineWidth = size * 0.05
    for degrees: CGFloat in [-16, 0, 16] {
        let radians = degrees * .pi / 180
        let outerRadius = armLength * 0.98
        let innerRadius = armLength * 0.72
        ticks.move(to: CGPoint(
            x: pivot.x + innerRadius * sin(radians), y: pivot.y + innerRadius * cos(radians)
        ))
        ticks.line(to: CGPoint(
            x: pivot.x + outerRadius * sin(radians), y: pivot.y + outerRadius * cos(radians)
        ))
    }
    NSColor.black.withAlphaComponent(0.45).setStroke()
    ticks.stroke()

    // Deflected past the ticks — a needle resting dead centre reads as
    // "idle," and this glyph is meant to say the opposite even standing
    // still. Same 20°-off-vertical lean `MenuBarGlyph` documents.
    let needleRadians: CGFloat = 20 * .pi / 180
    let tip = CGPoint(
        x: pivot.x + armLength * sin(needleRadians),
        y: pivot.y + armLength * cos(needleRadians)
    )
    let needle = NSBezierPath()
    needle.lineWidth = size * 0.09
    needle.lineCapStyle = .round
    needle.move(to: pivot)
    needle.line(to: tip)
    NSColor.black.setStroke()
    needle.stroke()

    let capRadius = size * 0.09
    let cap = NSBezierPath(ovalIn: CGRect(
        x: pivot.x - capRadius, y: pivot.y - capRadius, width: capRadius * 2, height: capRadius * 2
    ))
    NSColor.black.setFill()
    cap.fill()

    return image
}

// MARK: - Rasterise at every size `iconutil` expects

struct IconSpec {
    let pixels: Int
    let filename: String
}

let specs: [IconSpec] = [
    IconSpec(pixels: 16, filename: "icon_16x16.png"),
    IconSpec(pixels: 32, filename: "icon_16x16@2x.png"),
    IconSpec(pixels: 32, filename: "icon_32x32.png"),
    IconSpec(pixels: 64, filename: "icon_32x32@2x.png"),
    IconSpec(pixels: 128, filename: "icon_128x128.png"),
    IconSpec(pixels: 256, filename: "icon_128x128@2x.png"),
    IconSpec(pixels: 256, filename: "icon_256x256.png"),
    IconSpec(pixels: 512, filename: "icon_256x256@2x.png"),
    IconSpec(pixels: 512, filename: "icon_512x512.png"),
    IconSpec(pixels: 1024, filename: "icon_512x512@2x.png")
]

func pngData(for image: NSImage, pixels: Int) -> Data {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: pixels, pixelsHigh: pixels,
        bitsPerSample: 8, samplesPerPixel: 4,
        hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0, bitsPerPixel: 0
    )!
    rep.size = NSSize(width: pixels, height: pixels)

    let context = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    image.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels))
    NSGraphicsContext.restoreGraphicsState()

    return rep.representation(using: .png, properties: [:])!
}

let scriptURL = URL(fileURLWithPath: CommandLine.arguments[0])
let root = scriptURL.deletingLastPathComponent().deletingLastPathComponent()
let iconsetURL = root.appendingPathComponent("Resources/AppIcon.iconset")
let icnsURL = root.appendingPathComponent("Resources/AppIcon.icns")

try? FileManager.default.removeItem(at: iconsetURL)
try FileManager.default.createDirectory(at: iconsetURL, withIntermediateDirectories: true)

// One draw per *distinct* pixel size, not per file — 32×32 backs both
// icon_16x16@2x and icon_32x32, and re-rendering the vector each time a
// bigger canvas asks for it is what keeps every emitted file crisp rather
// than a scaled copy of whatever was drawn first.
var cache: [Int: NSImage] = [:]
for spec in specs {
    let image = cache[spec.pixels] ?? drawIcon(size: CGFloat(spec.pixels))
    cache[spec.pixels] = image
    let data = pngData(for: image, pixels: spec.pixels)
    try data.write(to: iconsetURL.appendingPathComponent(spec.filename))
}

print("→ wrote \(specs.count) PNGs to \(iconsetURL.path)")

let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
process.arguments = ["-c", "icns", iconsetURL.path, "-o", icnsURL.path]
try process.run()
process.waitUntilExit()
guard process.terminationStatus == 0 else {
    print("iconutil failed with status \(process.terminationStatus)")
    exit(1)
}

try? FileManager.default.removeItem(at: iconsetURL)
print("✓ \(icnsURL.path)")

// --- Menu bar glyph ---------------------------------------------------------
// Rendered well past the 18pt a status item actually displays at — a single
// oversized bitmap that `MenuBarGlyph` asks to draw at 18×18 stays sharp up
// to Retina's usual 2x, without needing separate @1x/@2x files or the asset
// catalog machinery this hand-assembled bundle otherwise has no use for.
let menuBarIconURL = root.appendingPathComponent("Resources/MenuBarIcon.png")
let menuBarGlyphPixels = 72
let menuBarData = pngData(for: drawMenuBarGlyph(pixels: menuBarGlyphPixels), pixels: menuBarGlyphPixels)
try menuBarData.write(to: menuBarIconURL)
print("✓ \(menuBarIconURL.path)")
