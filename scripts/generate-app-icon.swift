#!/usr/bin/env swift

import AppKit
import CoreGraphics
import Foundation

// Renders a 1024x1024 master PNG for the termy app icon and derives every size
// macOS asks for via `sips`. Run: `swift scripts/generate-app-icon.swift`.

let outDir = URL(fileURLWithPath: "apps/termy/Resources/Assets.xcassets/AppIcon.appiconset")
try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

let masterSize: CGFloat = 1024

func drawIcon(size: CGFloat) -> NSImage {
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()
    guard let ctx = NSGraphicsContext.current?.cgContext else {
        image.unlockFocus()
        return image
    }

    // squircle-like rounded rect background with subtle vertical gradient
    let inset: CGFloat = size * 0.02
    let rect = CGRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
    let radius = size * 0.2237 // Apple-ish continuous corner ratio
    let path = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
    ctx.saveGState()
    ctx.addPath(path)
    ctx.clip()

    let colors = [
        NSColor(calibratedRed: 0.08, green: 0.09, blue: 0.11, alpha: 1).cgColor,
        NSColor(calibratedRed: 0.02, green: 0.02, blue: 0.03, alpha: 1).cgColor,
    ]
    let gradient = CGGradient(
        colorsSpace: CGColorSpaceCreateDeviceRGB(),
        colors: colors as CFArray,
        locations: [0, 1]
    )!
    ctx.drawLinearGradient(
        gradient,
        start: CGPoint(x: 0, y: size),
        end: CGPoint(x: 0, y: 0),
        options: []
    )
    ctx.restoreGState()

    // eyebrows — two stacks of pane filter chips angled over each eye
    drawEyebrows(in: ctx, size: size)

    // prompt glyph ">_<" centered
    let glyph = ">_<"
    let fontSize = size * 0.38
    let font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .bold)
    let paragraph = NSMutableParagraphStyle()
    paragraph.alignment = .center
    let attrs: [NSAttributedString.Key: Any] = [
        .font: font,
        .foregroundColor: NSColor(calibratedRed: 0.56, green: 0.93, blue: 0.62, alpha: 1),
        .paragraphStyle: paragraph,
        .kern: -size * 0.01,
    ]
    let attributed = NSAttributedString(string: glyph, attributes: attrs)
    let textSize = attributed.size()
    let textRect = CGRect(
        x: (size - textSize.width) / 2,
        y: (size - textSize.height) / 2 - size * 0.02,
        width: textSize.width,
        height: textSize.height
    )
    attributed.draw(in: textRect)

    image.unlockFocus()
    return image
}

// Renders the eyebrow row — three pane-filter chips spread across the full
// width of the icon (not split per eye). Colors are sampled from the real
// PaneStyling palette so the icon reads as the same app.
func drawEyebrows(in ctx: CGContext, size: CGFloat) {
    struct Pill {
        let color: NSColor
        let width: CGFloat
        let fillAlpha: CGFloat
    }

    let teal = NSColor(calibratedRed: 0.28, green: 0.78, blue: 0.82, alpha: 1)
    // Yellow hue washes out at 0.58 alpha on near-black — without the alpha
    // bump it reads as olive/mustard next to the cyan and magenta pills.
    let yellow = NSColor(calibratedRed: 1.00, green: 0.92, blue: 0.45, alpha: 1)
    let pink = NSColor(calibratedRed: 1.00, green: 0.44, blue: 0.62, alpha: 1)

    let pillHeight = size * 0.048
    let pillSpacing = size * 0.035
    let cornerRadius = pillHeight * 0.35
    let rowY = size * 0.78
    let chipWidth = size * 0.20

    let pills: [Pill] = [
        Pill(color: teal, width: chipWidth, fillAlpha: 0.58),
        Pill(color: yellow, width: chipWidth, fillAlpha: 0.85),
        Pill(color: pink, width: chipWidth, fillAlpha: 0.58),
    ]
    let totalWidth = pills.reduce(CGFloat(0)) { $0 + $1.width }
        + CGFloat(max(0, pills.count - 1)) * pillSpacing

    ctx.saveGState()
    ctx.translateBy(x: size / 2, y: rowY)

    var x = -totalWidth / 2
    for pill in pills {
        let rect = CGRect(
            x: x,
            y: -pillHeight / 2,
            width: pill.width,
            height: pillHeight
        )
        let path = CGPath(
            roundedRect: rect,
            cornerWidth: cornerRadius,
            cornerHeight: cornerRadius,
            transform: nil
        )
        ctx.addPath(path)
        ctx.setFillColor(pill.color.withAlphaComponent(pill.fillAlpha).cgColor)
        ctx.fillPath()
        ctx.addPath(path)
        ctx.setStrokeColor(pill.color.withAlphaComponent(0.95).cgColor)
        ctx.setLineWidth(size * 0.004)
        ctx.strokePath()

        x += pill.width + pillSpacing
    }
    ctx.restoreGState()
}

func writePNG(_ image: NSImage, to url: URL) throws {
    guard
        let tiff = image.tiffRepresentation,
        let rep = NSBitmapImageRep(data: tiff),
        let data = rep.representation(using: .png, properties: [:])
    else {
        throw NSError(domain: "icon", code: 1)
    }
    try data.write(to: url)
}

let masterURL = outDir.appendingPathComponent("icon_1024.png")
let master = drawIcon(size: masterSize)
try writePNG(master, to: masterURL)

// Apple's AppIcon.appiconset for macOS expects these (size, scale) pairs.
let variants: [(String, Int, Int)] = [
    // filename, pixelSize, declaredSize
    ("icon_16x16.png", 16, 16),
    ("icon_16x16@2x.png", 32, 16),
    ("icon_32x32.png", 32, 32),
    ("icon_32x32@2x.png", 64, 32),
    ("icon_128x128.png", 128, 128),
    ("icon_128x128@2x.png", 256, 128),
    ("icon_256x256.png", 256, 256),
    ("icon_256x256@2x.png", 512, 256),
    ("icon_512x512.png", 512, 512),
    ("icon_512x512@2x.png", 1024, 512),
]

for (name, px, _) in variants {
    let url = outDir.appendingPathComponent(name)
    let task = Process()
    task.launchPath = "/usr/bin/sips"
    task.arguments = ["-Z", "\(px)", masterURL.path, "--out", url.path]
    let pipe = Pipe()
    task.standardOutput = pipe
    task.standardError = pipe
    try task.run()
    task.waitUntilExit()
    if task.terminationStatus != 0 {
        let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        FileHandle.standardError.write(Data("sips failed for \(name): \(out)\n".utf8))
        exit(1)
    }
}

// Remove the master — it's not referenced by Contents.json.
try? FileManager.default.removeItem(at: masterURL)

// Contents.json for the appiconset
struct ImageEntry: Codable {
    let size: String
    let idiom: String
    let filename: String
    let scale: String
}
struct Info: Codable { let version: Int; let author: String }
struct Contents: Codable { let images: [ImageEntry]; let info: Info }

let images: [ImageEntry] = [
    .init(size: "16x16", idiom: "mac", filename: "icon_16x16.png", scale: "1x"),
    .init(size: "16x16", idiom: "mac", filename: "icon_16x16@2x.png", scale: "2x"),
    .init(size: "32x32", idiom: "mac", filename: "icon_32x32.png", scale: "1x"),
    .init(size: "32x32", idiom: "mac", filename: "icon_32x32@2x.png", scale: "2x"),
    .init(size: "128x128", idiom: "mac", filename: "icon_128x128.png", scale: "1x"),
    .init(size: "128x128", idiom: "mac", filename: "icon_128x128@2x.png", scale: "2x"),
    .init(size: "256x256", idiom: "mac", filename: "icon_256x256.png", scale: "1x"),
    .init(size: "256x256", idiom: "mac", filename: "icon_256x256@2x.png", scale: "2x"),
    .init(size: "512x512", idiom: "mac", filename: "icon_512x512.png", scale: "1x"),
    .init(size: "512x512", idiom: "mac", filename: "icon_512x512@2x.png", scale: "2x"),
]

let contents = Contents(images: images, info: Info(version: 1, author: "xcode"))
let encoder = JSONEncoder()
encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
let contentsData = try encoder.encode(contents)
try contentsData.write(to: outDir.appendingPathComponent("Contents.json"))

// top-level Assets.xcassets Contents.json
let assetsDir = outDir.deletingLastPathComponent()
let assetsContents = Contents(images: [], info: Info(version: 1, author: "xcode"))
let assetsInfoOnly: [String: Any] = [
    "info": ["version": 1, "author": "xcode"]
]
let topData = try JSONSerialization.data(
    withJSONObject: assetsInfoOnly,
    options: [.prettyPrinted, .sortedKeys]
)
try topData.write(to: assetsDir.appendingPathComponent("Contents.json"))
_ = assetsContents

print("Wrote \(variants.count) PNGs to \(outDir.path)")
