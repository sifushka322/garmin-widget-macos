import AppKit
import SwiftUI
import CoreGraphics

/// Test-only capture into an explicitly allocated bitmap. Production views and
/// fixture coverage stay unchanged; ImageRenderer receives the target context.
enum FixtureBitmapRenderer {
    @MainActor static func png<Content: View>(_ content: Content, size: CGSize, scale: CGFloat = 2) -> Data {
        autoreleasepool {
            guard size.width.isFinite, size.height.isFinite, scale.isFinite,
                  size.width > 0, size.height > 0, scale > 0 else {
                fatalError("Invalid fixture bitmap dimensions")
            }
            let width = Int((size.width * scale).rounded(.up))
            let height = Int((size.height * scale).rounded(.up))
            let renderer = ImageRenderer(content: content)
            renderer.proposedSize = ProposedViewSize(width: size.width, height: size.height)
            var image: CGImage?
            renderer.render(rasterizationScale: scale) { actualSize, draw in
                guard abs(actualSize.width - size.width) < 0.01,
                      abs(actualSize.height - size.height) < 0.01 else {
                    fatalError("Fixture layout changed its requested size: \(actualSize), expected \(size)")
                }
                guard let space = CGColorSpace(name: CGColorSpace.sRGB),
                      let context = CGContext(data: nil, width: width, height: height,
                          bitsPerComponent: 8, bytesPerRow: 0, space: space,
                          bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue
                              | CGImageAlphaInfo.premultipliedLast.rawValue) else {
                    fatalError("Unable to allocate fixture bitmap context")
                }
                context.scaleBy(x: scale, y: scale)
                // Apple's drawing closure expects a bottom-left coordinate origin.
                draw(context)
                // These fixtures paint their center. Reject a blank result even
                // when allocation and PNG encoding happen to succeed.
                guard let pixels = context.data?.assumingMemoryBound(to: UInt8.self),
                      pixels[(height / 2) * context.bytesPerRow + (width / 2) * 4 + 3] > 0 else {
                    fatalError("Fixture render produced a transparent center")
                }
                image = context.makeImage()
            }
            guard let image, image.width == width, image.height == height,
                  let bytes = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
                fatalError("Unable to encode fixture bitmap at its exact pixel size")
            }
            return bytes
        }
    }
}
