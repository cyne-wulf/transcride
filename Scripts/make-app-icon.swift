#!/usr/bin/env swift
// Generates the Transcride app icon set (run once, outputs are committed):
//   swift Scripts/make-app-icon.swift
//
// Design: macOS squircle on a deep teal→indigo gradient, a white waveform
// becoming text lines — the product thesis (audio is the draft, the
// transcript is the artifact) as a mark.

import AppKit

let master: CGFloat = 1024

func drawMaster(into ctx: CGContext) {
    let size = master

    // Standard macOS icon grid: content inset ~10%, corner radius ~22.5%.
    let inset = size * 0.098
    let rect = CGRect(x: inset, y: inset, width: size - 2 * inset, height: size - 2 * inset)
    let radius = rect.width * 0.225
    let squircle = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)

    // Soft drop shadow behind the plate, like system icons.
    ctx.saveGState()
    ctx.setShadow(
        offset: CGSize(width: 0, height: -size * 0.008),
        blur: size * 0.02,
        color: NSColor.black.withAlphaComponent(0.35).cgColor
    )
    ctx.addPath(squircle)
    ctx.setFillColor(NSColor(calibratedRed: 0.09, green: 0.30, blue: 0.36, alpha: 1).cgColor)
    ctx.fillPath()
    ctx.restoreGState()

    // Gradient plate: deep teal (top) into indigo (bottom).
    ctx.saveGState()
    ctx.addPath(squircle)
    ctx.clip()
    let colors = [
        NSColor(calibratedRed: 0.10, green: 0.42, blue: 0.46, alpha: 1).cgColor,
        NSColor(calibratedRed: 0.13, green: 0.22, blue: 0.42, alpha: 1).cgColor,
        NSColor(calibratedRed: 0.16, green: 0.13, blue: 0.38, alpha: 1).cgColor,
    ]
    let gradient = CGGradient(
        colorsSpace: CGColorSpaceCreateDeviceRGB(),
        colors: colors as CFArray,
        locations: [0.0, 0.62, 1.0]
    )!
    ctx.drawLinearGradient(
        gradient,
        start: CGPoint(x: rect.midX, y: rect.maxY),
        end: CGPoint(x: rect.midX, y: rect.minY),
        options: []
    )
    // Faint radial glow top-center for depth.
    let glow = CGGradient(
        colorsSpace: CGColorSpaceCreateDeviceRGB(),
        colors: [
            NSColor.white.withAlphaComponent(0.14).cgColor,
            NSColor.white.withAlphaComponent(0).cgColor,
        ] as CFArray,
        locations: [0, 1]
    )!
    ctx.drawRadialGradient(
        glow,
        startCenter: CGPoint(x: rect.midX, y: rect.maxY - rect.height * 0.1),
        startRadius: 0,
        endCenter: CGPoint(x: rect.midX, y: rect.maxY - rect.height * 0.1),
        endRadius: rect.width * 0.9,
        options: []
    )
    ctx.restoreGState()

    // The mark. All in white; waveform bars left, text lines right.
    ctx.saveGState()
    ctx.setFillColor(NSColor.white.cgColor)
    ctx.setShadow(
        offset: .zero, blur: size * 0.012,
        color: NSColor.black.withAlphaComponent(0.25).cgColor
    )

    let stroke: CGFloat = 58
    let gap: CGFloat = 42
    let cy = size / 2

    func rounded(_ r: CGRect) {
        ctx.addPath(CGPath(roundedRect: r, cornerWidth: stroke / 2, cornerHeight: stroke / 2, transform: nil))
    }

    // Waveform: four bars, heights like a spoken syllable.
    let barHeights: [CGFloat] = [170, 330, 440, 250]
    let lineWidths: [CGFloat] = [178, 178, 122]
    let lineSpan = 3 * stroke + 2 * (gap - 6)
    let barsWidth = CGFloat(barHeights.count) * stroke + CGFloat(barHeights.count - 1) * gap
    let blockGap: CGFloat = 74
    let totalWidth = barsWidth + blockGap + lineWidths.max()!
    var x = (size - totalWidth) / 2

    for height in barHeights {
        rounded(CGRect(x: x, y: cy - height / 2, width: stroke, height: height))
        x += stroke + gap
    }

    // Text lines: three rows, the last one shorter — a paragraph trailing off.
    x += blockGap - gap
    var y = cy + lineSpan / 2 - stroke
    for width in lineWidths {
        rounded(CGRect(x: x, y: y, width: width, height: stroke))
        y -= stroke + (gap - 6)
    }

    ctx.fillPath()
    ctx.restoreGState()
}

func renderMaster() -> CGImage {
    let ctx = CGContext(
        data: nil, width: Int(master), height: Int(master),
        bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    drawMaster(into: ctx)
    return ctx.makeImage()!
}

func writePNG(_ image: CGImage, size: Int, to url: URL) {
    let ctx = CGContext(
        data: nil, width: size, height: size,
        bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    ctx.interpolationQuality = .high
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: size, height: size))
    let scaled = ctx.makeImage()!
    let rep = NSBitmapImageRep(cgImage: scaled)
    rep.size = NSSize(width: size, height: size)
    let data = rep.representation(using: .png, properties: [:])!
    try! data.write(to: url)
    print("wrote \(url.lastPathComponent) (\(size)px)")
}

let scriptURL = URL(fileURLWithPath: CommandLine.arguments[0])
let repoRoot = scriptURL.deletingLastPathComponent().deletingLastPathComponent()
let setURL = repoRoot.appending(path: "Transcride/Assets.xcassets/AppIcon.appiconset")
try! FileManager.default.createDirectory(at: setURL, withIntermediateDirectories: true)

let masterImage = renderMaster()
for px in [16, 32, 64, 128, 256, 512, 1024] {
    writePNG(masterImage, size: px, to: setURL.appending(path: "icon_\(px).png"))
}

let contents = """
{
  "images" : [
    { "filename" : "icon_16.png",   "idiom" : "mac", "scale" : "1x", "size" : "16x16" },
    { "filename" : "icon_32.png",   "idiom" : "mac", "scale" : "2x", "size" : "16x16" },
    { "filename" : "icon_32.png",   "idiom" : "mac", "scale" : "1x", "size" : "32x32" },
    { "filename" : "icon_64.png",   "idiom" : "mac", "scale" : "2x", "size" : "32x32" },
    { "filename" : "icon_128.png",  "idiom" : "mac", "scale" : "1x", "size" : "128x128" },
    { "filename" : "icon_256.png",  "idiom" : "mac", "scale" : "2x", "size" : "128x128" },
    { "filename" : "icon_256.png",  "idiom" : "mac", "scale" : "1x", "size" : "256x256" },
    { "filename" : "icon_512.png",  "idiom" : "mac", "scale" : "2x", "size" : "256x256" },
    { "filename" : "icon_512.png",  "idiom" : "mac", "scale" : "1x", "size" : "512x512" },
    { "filename" : "icon_1024.png", "idiom" : "mac", "scale" : "2x", "size" : "512x512" }
  ],
  "info" : { "author" : "xcode", "version" : 1 }
}
"""
try! contents.write(to: setURL.appending(path: "Contents.json"), atomically: true, encoding: .utf8)
print("wrote Contents.json")
