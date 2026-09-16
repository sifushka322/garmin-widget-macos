// Package the selected artwork with a clean, opaque tile; export the shared menu glyph.
// Run: bash scripts/generate-icon.sh
import AppKit
import CoreGraphics
import ImageIO
import Foundation

@main
enum IconGenerator {
    static func preparedArtwork(_ artwork: CGImage) throws -> CGImage {
        // Image generation left the solid tile at alpha 252–253 and scattered
        // nearly invisible pixels outside it. Keep the source colors and shape,
        // but make its interior opaque before macOS classifies this legacy icon.
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: artwork.width, height: artwork.height,
                  bitsPerComponent: 8, bytesPerRow: artwork.width * 4, space: space,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                      | CGBitmapInfo.byteOrder32Big.rawValue),
              let bytes = context.data?.assumingMemoryBound(to: UInt8.self) else {
            throw NSError(domain: "IconGenerator", code: 5)
        }
        context.draw(artwork, in: CGRect(x: 0, y: 0, width: artwork.width, height: artwork.height))
        for pixel in 0..<(artwork.width * artwork.height) {
            let offset = pixel * 4
            let alpha = Int(bytes[offset + 3])
            let normalizedAlpha = alpha <= 8 ? 0 : (alpha >= 248 ? 255 : alpha)
            guard normalizedAlpha != alpha else { continue }
            for channel in 0..<3 {
                bytes[offset + channel] = alpha == 0 ? 0
                    : UInt8(min(255, (Int(bytes[offset + channel]) * normalizedAlpha + alpha / 2) / alpha))
            }
            bytes[offset + 3] = UInt8(normalizedAlpha)
        }
        guard let image = context.makeImage() else {
            throw NSError(domain: "IconGenerator", code: 6)
        }
        return image
    }

    static func png(pixels: Int, draw: (CGContext) -> Void) throws -> Data {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: pixels, height: pixels,
                  bitsPerComponent: 8, bytesPerRow: pixels * 4, space: space,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw NSError(domain: "IconGenerator", code: 1)
        }
        context.interpolationQuality = .high
        context.setAllowsAntialiasing(true)
        context.setShouldAntialias(true)
        draw(context)
        guard let image = context.makeImage(),
              let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
            throw NSError(domain: "IconGenerator", code: 2)
        }
        return data
    }

    static func drawMark(in context: CGContext, side: CGFloat) {
        context.saveGState()
        context.translateBy(x: 0, y: side)
        context.scaleBy(x: 1, y: -1)
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        context.addPath(GarminDeskBrandGeometry.path(in: CGRect(x: 0, y: 0, width: side, height: side)))
        context.fillPath()
        context.restoreGState()
    }

    static func main() throws {
        let project = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let resources = project.appendingPathComponent("Resources")
        let branding = resources.appendingPathComponent("Branding")
        let iconset = project.appendingPathComponent("build/AppIcon.iconset")
        try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
        let original = branding.appendingPathComponent("AppIcon-source.png")
        guard let source = CGImageSourceCreateWithURL(original as CFURL, nil),
              let originalArtwork = CGImageSourceCreateImageAtIndex(source, 0, nil),
              originalArtwork.width == originalArtwork.height, originalArtwork.width >= 1024 else {
            throw NSError(domain: "IconGenerator", code: 3, userInfo: [
                NSLocalizedDescriptionKey: "AppIcon-source.png must be a square PNG of at least 1024 pixels."
            ])
        }
        let artwork = try preparedArtwork(originalArtwork)
        for size in [16, 32, 128, 256, 512] {
            for scale in [1, 2] {
                let pixels = size * scale
                let data = try png(pixels: pixels) { context in
                    context.draw(artwork, in: CGRect(x: 0, y: 0, width: pixels, height: pixels))
                }
                let suffix = scale == 2 ? "@2x" : ""
                try data.write(to: iconset.appendingPathComponent("icon_\(size)x\(size)\(suffix).png"), options: .atomic)
                if pixels == 1024 {
                    try data.write(to: branding.appendingPathComponent("AppIcon-1024.png"), options: .atomic)
                }
            }
        }
        let packedIcon = project.appendingPathComponent("build/AppIcon.icns")
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
        task.arguments = ["--convert", "icns", "--output", packedIcon.path, iconset.path]
        try task.run()
        task.waitUntilExit()
        guard task.terminationStatus == 0 else {
            throw NSError(domain: "iconutil", code: Int(task.terminationStatus))
        }
        try Data(contentsOf: packedIcon).write(to: resources.appendingPathComponent("AppIcon.icns"), options: .atomic)
        for scale in [1, 2] {
            let pixels = 18 * scale
            let data = try png(pixels: pixels) { drawMark(in: $0, side: CGFloat(pixels)) }
            let suffix = scale == 2 ? "@2x" : ""
            try data.write(to: branding.appendingPathComponent("MenuBarTemplate\(suffix).png"), options: .atomic)
        }
        let pdfData = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 18, height: 18)
        guard let consumer = CGDataConsumer(data: pdfData),
              let pdf = CGContext(consumer: consumer, mediaBox: &box, nil) else {
            throw NSError(domain: "IconGenerator", code: 4)
        }
        pdf.beginPDFPage(nil)
        drawMark(in: pdf, side: 18)
        pdf.endPDFPage()
        pdf.closePDF()
        try (pdfData as Data).write(to: branding.appendingPathComponent("MenuBarTemplate.pdf"), options: .atomic)
        print("Generated round-watch AppIcon.icns, 10 PNG sizes, and monochrome menu assets.")
    }
}
