import AppKit
import SwiftUI

struct GarminDeskBrandMark: Shape {
    func path(in rect: CGRect) -> Path {
        Path(GarminDeskBrandGeometry.path(in: rect))
    }
}

enum GarminDeskBrandImage {
    static func menuBarTemplate(size: CGFloat = 18) -> NSImage {
        let image = NSImage(size: NSSize(width: size, height: size), flipped: true) { rect in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            context.setFillColor(NSColor.black.cgColor)
            context.addPath(GarminDeskBrandGeometry.path(in: rect))
            context.fillPath()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "GarminDesk"
        return image
    }
}
