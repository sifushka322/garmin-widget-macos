import CoreGraphics
import Darwin
import Foundation
import ImageIO

/// Checks the packaged artwork without launching an app or accessing icon services.
@main
struct BrandIconTests {
    struct Failure: Error, CustomStringConvertible { let description: String }
    static var checks = 0

    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        checks += 1
        guard condition() else { throw Failure(description: message) }
    }

    static func largestImage(at url: URL) throws -> CGImage {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            throw Failure(description: "Cannot read icon asset: \(url.path)")
        }
        var largest: CGImage?
        for index in 0..<CGImageSourceGetCount(source) {
            guard let image = CGImageSourceCreateImageAtIndex(source, index, nil) else { continue }
            if largest == nil || image.width * image.height > largest!.width * largest!.height {
                largest = image
            }
        }
        guard let largest else {
            throw Failure(description: "No decodable image in \(url.lastPathComponent)")
        }
        return largest
    }

    static func validate(_ url: URL) throws {
        let image = try largestImage(at: url)
        let name = url.lastPathComponent
        try expect(image.width == 1024 && image.height == 1024,
                   "\(name): the largest representation must be 1024 × 1024")
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: image.width, height: image.height,
                  bitsPerComponent: 8, bytesPerRow: image.width * 4, space: space,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                      | CGBitmapInfo.byteOrder32Big.rawValue),
              let bytes = context.data?.assumingMemoryBound(to: UInt8.self) else {
            throw Failure(description: "Cannot decode \(name) into RGBA pixels")
        }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        func alpha(_ x: Int, _ y: Int) -> UInt8 { bytes[y * context.bytesPerRow + x * 4 + 3] }

        // A subtly translucent tile (the original was mostly alpha 252–253)
        // can look normal in a PNG while macOS adds a plate and shrinks it.
        let center = (image.width / 4)..<(image.width * 3 / 4)
        var opaquePixels = 0
        for y in center {
            for x in center where alpha(x, y) == 255 { opaquePixels += 1 }
        }
        let opaqueFraction = Double(opaquePixels) / Double(center.count * center.count)
        try expect(opaqueFraction > 0.995,
                   "\(name): only \(String(format: "%.3f", opaqueFraction * 100))% of the central tile is fully opaque; require >99.5%")

        // Keep transparent corners for the existing rounded legacy ICNS shape.
        let cornerSize = image.width / 20
        for (label, xStart, yStart) in [
            ("top left", 0, 0), ("top right", image.width - cornerSize, 0),
            ("bottom left", 0, image.height - cornerSize),
            ("bottom right", image.width - cornerSize, image.height - cornerSize)
        ] {
            var transparent = true
            for y in yStart..<(yStart + cornerSize) {
                for x in xStart..<(xStart + cornerSize) where alpha(x, y) != 0 { transparent = false }
            }
            try expect(transparent, "\(name): the outer \(label) corner must remain transparent")
        }
    }

    static func main() {
        do {
            // The optional resource directory also allows a known old package
            // to be checked without replacing the project's current assets.
            let resources = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "Resources",
                                isDirectory: true)
            try validate(resources.appendingPathComponent("AppIcon.icns"))
            try validate(resources.appendingPathComponent("Branding/AppIcon-1024.png"))
            print("PASS: \(checks) brand icon checks; 1024px assets have opaque centers and transparent corners")
        } catch {
            fputs("FAIL: \(error)\n", stderr)
            exit(1)
        }
    }
}
