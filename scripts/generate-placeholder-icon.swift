#!/usr/bin/env swift
//
// generate-placeholder-icon.swift
//
// Generates a NEW, brand-neutral PLACEHOLDER app icon for MeetingWhisper and writes the 10 PNG
// sizes declared by AppIcon.appiconset/Contents.json. Uses only CoreGraphics + ImageIO (guaranteed
// on macOS — no PIL/third-party deps). Deterministic: fixed colors + geometry, so re-running
// overwrites identically.
//
//   swift scripts/generate-placeholder-icon.swift [output-appiconset-dir]
//
// ############################################################################################
// # PLACEHOLDER ICON — replace before any public/shipping build (owner).                     #
// # Upstream's artwork is trademark-restricted and must not be reused. This flat calendar +   #
// # waveform mark is a temporary stand-in only.                                               #
// ############################################################################################

import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

// MARK: - Colors (indigo, brand-neutral)

let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!
func rgb(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) -> CGColor {
    CGColor(colorSpace: sRGB, components: [CGFloat(r), CGFloat(g), CGFloat(b), CGFloat(a)])!
}
let gradientTop = rgb(0.388, 0.400, 0.945)   // #6366F1
let gradientBottom = rgb(0.310, 0.275, 0.898) // #4F46E5
let calendarBody = rgb(1, 1, 1)               // white
let accentDark = rgb(0.263, 0.220, 0.792)     // #4338CA (header + waveform)

// MARK: - Drawing

func roundedRectPath(_ rect: CGRect, radius: CGFloat) -> CGPath {
    CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
}

func drawIcon(pixels: Int) -> CGImage {
    let ctx = CGContext(
        data: nil, width: pixels, height: pixels,
        bitsPerComponent: 8, bytesPerRow: 0, space: sRGB,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    ctx.interpolationQuality = .high
    ctx.setAllowsAntialiasing(true)
    ctx.setShouldAntialias(true)

    let S = CGFloat(pixels)
    let simplify = pixels <= 32

    // Rounded-square (macOS squircle approximation) background with a small transparent margin.
    let margin = S * 0.085
    let bgRect = CGRect(x: margin, y: margin, width: S - 2 * margin, height: S - 2 * margin)
    let bgCorner = bgRect.width * 0.2237

    ctx.saveGState()
    ctx.addPath(roundedRectPath(bgRect, radius: bgCorner))
    ctx.clip()
    let gradient = CGGradient(colorsSpace: sRGB, colors: [gradientTop, gradientBottom] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(
        gradient,
        start: CGPoint(x: bgRect.midX, y: bgRect.maxY),
        end: CGPoint(x: bgRect.midX, y: bgRect.minY),
        options: []
    )
    ctx.restoreGState()

    // Calendar body (white rounded rect), centered, slightly below middle.
    let calW = bgRect.width * 0.60
    let calH = calW * 0.92
    let calRect = CGRect(
        x: bgRect.midX - calW / 2,
        y: bgRect.midY - calH / 2 - bgRect.height * 0.02,
        width: calW, height: calH
    )
    let calCorner = calW * 0.14
    ctx.addPath(roundedRectPath(calRect, radius: calCorner))
    ctx.setFillColor(calendarBody)
    ctx.fillPath()

    // Header bar: clip to the top strip and fill the calendar path with the accent so only the top
    // corners are rounded.
    let headerH = calH * 0.24
    ctx.saveGState()
    ctx.clip(to: CGRect(x: calRect.minX, y: calRect.maxY - headerH, width: calW, height: headerH))
    ctx.addPath(roundedRectPath(calRect, radius: calCorner))
    ctx.setFillColor(accentDark)
    ctx.fillPath()
    ctx.restoreGState()

    // Binder tabs (omit at menu-bar sizes so the mark stays legible).
    if !simplify {
        let tabW = calW * 0.085
        let tabH = calH * 0.13
        let tabY = calRect.maxY - tabH * 0.5
        for cx in [calRect.minX + calW * 0.30, calRect.minX + calW * 0.70] {
            let tab = CGRect(x: cx - tabW / 2, y: tabY, width: tabW, height: tabH)
            ctx.addPath(roundedRectPath(tab, radius: tabW * 0.5))
            ctx.setFillColor(calendarBody)
            ctx.fillPath()
        }
    }

    // Waveform: rounded vertical bars in the white body area.
    let bodyRect = CGRect(x: calRect.minX, y: calRect.minY, width: calW, height: calH - headerH)
    let pattern: [CGFloat] = simplify ? [0.5, 1.0, 0.65] : [0.40, 0.72, 1.0, 0.58, 0.86, 0.48]
    let count = pattern.count
    let areaW = bodyRect.width * (simplify ? 0.58 : 0.66)
    let areaH = bodyRect.height * 0.60
    let gapRatio: CGFloat = simplify ? 0.6 : 0.75
    let barW = areaW / (CGFloat(count) + gapRatio * CGFloat(count - 1))
    let gap = barW * gapRatio
    let startX = bodyRect.midX - areaW / 2
    let baseY = bodyRect.midY - areaH / 2
    ctx.setFillColor(accentDark)
    for (i, h) in pattern.enumerated() {
        let x = startX + CGFloat(i) * (barW + gap)
        let barH = max(barW, areaH * h)
        let bar = CGRect(x: x, y: baseY, width: barW, height: barH)
        ctx.addPath(roundedRectPath(bar, radius: barW * 0.5))
        ctx.fillPath()
    }

    return ctx.makeImage()!
}

func writePNG(_ image: CGImage, to url: URL) {
    guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
        fatalError("Could not create PNG destination at \(url.path)")
    }
    CGImageDestinationAddImage(dest, image, nil)
    guard CGImageDestinationFinalize(dest) else {
        fatalError("Could not write PNG at \(url.path)")
    }
}

// MARK: - Output targets (must match Contents.json)

let outputs: [(pixels: Int, name: String)] = [
    (16,   "icon_16x16.png"),
    (32,   "icon_16x16@2x.png"),
    (32,   "icon_32x32.png"),
    (64,   "icon_32x32@2x.png"),
    (128,  "icon_128x128.png"),
    (256,  "icon_128x128@2x.png"),
    (256,  "icon_256x256.png"),
    (512,  "icon_256x256@2x.png"),
    (512,  "icon_512x512.png"),
    (1024, "icon_512x512@2x.png"),
]

// Resolve the appiconset directory: explicit arg, else derive from this script's location.
let appiconDir: URL = {
    if CommandLine.arguments.count > 1 {
        return URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
    }
    let scriptURL = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
    let repoRoot = scriptURL.deletingLastPathComponent().deletingLastPathComponent()
    return repoRoot
        .appendingPathComponent("TypeWhisper/Resources/Assets.xcassets/AppIcon.appiconset", isDirectory: true)
}()

guard FileManager.default.fileExists(atPath: appiconDir.appendingPathComponent("Contents.json").path) else {
    FileHandle.standardError.write(Data("error: AppIcon.appiconset not found at \(appiconDir.path)\n".utf8))
    exit(1)
}

// Cache one image per unique pixel size (256 and 512 are used twice).
var cache: [Int: CGImage] = [:]
for output in outputs {
    let image = cache[output.pixels] ?? {
        let img = drawIcon(pixels: output.pixels)
        cache[output.pixels] = img
        return img
    }()
    writePNG(image, to: appiconDir.appendingPathComponent(output.name))
    print("wrote \(output.name) (\(output.pixels)x\(output.pixels))")
}

print("")
print("############################################################################")
print("# PLACEHOLDER ICON — replace before any public/shipping build (owner).      #")
print("############################################################################")
