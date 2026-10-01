// Draws OrbitDrop's app icon with Core Graphics and writes an .iconset
// folder for iconutil. Original artwork: a teal-to-blue rounded square with
// an orbit ring and a small satellite dot. No external assets are used.
//
//   swift scripts/make-icon.swift <output.iconset>

import CoreGraphics
import Foundation
import ImageIO

func drawIcon(side: Int) -> CGImage? {
    guard let space = CGColorSpace(name: CGColorSpace.sRGB),
          let context = CGContext(
            data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0, space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
    let size = CGFloat(side)
    let inset = size * 0.09
    let body = CGRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
    let shape = CGPath(roundedRect: body, cornerWidth: size * 0.2, cornerHeight: size * 0.2, transform: nil)

    context.saveGState()
    context.addPath(shape)
    context.clip()
    let colors = [
        CGColor(srgbRed: 0.10, green: 0.74, blue: 0.72, alpha: 1),
        CGColor(srgbRed: 0.11, green: 0.42, blue: 0.90, alpha: 1),
    ] as CFArray
    if let gradient = CGGradient(colorsSpace: space, colors: colors, locations: [0, 1]) {
        context.drawLinearGradient(
            gradient, start: CGPoint(x: body.minX, y: body.maxY), end: CGPoint(x: body.maxX, y: body.minY), options: [])
    }
    context.restoreGState()

    let center = CGPoint(x: size / 2, y: size / 2)
    let white = CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)

    // Orbit ring, tilted.
    context.saveGState()
    context.translateBy(x: center.x, y: center.y)
    context.rotate(by: -.pi / 7)
    context.setStrokeColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.85))
    context.setLineWidth(size * 0.035)
    context.strokeEllipse(in: CGRect(x: -size * 0.31, y: -size * 0.15, width: size * 0.62, height: size * 0.30))
    // Satellite dot on the ring.
    context.setFillColor(white)
    let dot = size * 0.055
    context.fillEllipse(in: CGRect(x: size * 0.31 - dot, y: -dot, width: dot * 2, height: dot * 2))
    context.restoreGState()

    // Core.
    context.setFillColor(white)
    let core = size * 0.105
    context.fillEllipse(in: CGRect(x: center.x - core, y: center.y - core, width: core * 2, height: core * 2))

    return context.makeImage()
}

func writePNG(_ image: CGImage, to url: URL) -> Bool {
    guard let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else {
        return false
    }
    CGImageDestinationAddImage(destination, image, nil)
    return CGImageDestinationFinalize(destination)
}

guard CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write(Data("usage: swift make-icon.swift <output.iconset>\n".utf8))
    exit(2)
}
let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
do {
    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
} catch {
    FileHandle.standardError.write(Data("cannot create \(output.path)\n".utf8))
    exit(1)
}

let variants: [(name: String, side: Int)] = [
    ("icon_16x16.png", 16), ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024),
]
for variant in variants {
    guard let image = drawIcon(side: variant.side),
          writePNG(image, to: output.appendingPathComponent(variant.name)) else {
        FileHandle.standardError.write(Data("failed to draw \(variant.name)\n".utf8))
        exit(1)
    }
}
