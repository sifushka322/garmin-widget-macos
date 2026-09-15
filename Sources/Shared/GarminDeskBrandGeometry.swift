import CoreGraphics

/// The small GarminDesk watch mark, in a top-left-origin coordinate system.
/// Shared by the app, widgets, and the native branding asset generator.
enum GarminDeskBrandGeometry {
    static func path(in rect: CGRect) -> CGPath {
        let mark = CGMutablePath()

        // Short straps and a crown keep the silhouette recognizably a watch.
        // Build every part from stroked paths so overlapping silhouettes have
        // matching winding directions and remain solid under nonzero filling.
        for y in [3.15, 20.85] {
            let strap = CGMutablePath()
            strap.move(to: CGPoint(x: 10.45, y: y))
            strap.addLine(to: CGPoint(x: 12.35, y: y))
            mark.addPath(strap.copy(strokingWithWidth: 4.9, lineCap: .round,
                                   lineJoin: .round, miterLimit: 1))
        }
        let crown = CGMutablePath()
        crown.move(to: CGPoint(x: 20.3, y: 11.3))
        crown.addLine(to: CGPoint(x: 20.3, y: 12.7))
        mark.addPath(crown.copy(strokingWithWidth: 2.2, lineCap: .round,
                               lineJoin: .round, miterLimit: 1))

        let caseOutline = CGPath(ellipseIn: CGRect(x: 3.4, y: 4, width: 16, height: 16),
                                 transform: nil)
        mark.addPath(caseOutline.copy(strokingWithWidth: 1.9, lineCap: .round,
                                      lineJoin: .round, miterLimit: 1))

        // Simple 10:10 hands remain clear at menu-bar and widget-header sizes.
        let hands = CGMutablePath()
        hands.move(to: CGPoint(x: 7.6, y: 9))
        hands.addLine(to: CGPoint(x: 11.4, y: 12))
        hands.addLine(to: CGPoint(x: 15.8, y: 8.5))
        mark.addPath(hands.copy(strokingWithWidth: 1.8, lineCap: .round,
                               lineJoin: .round, miterLimit: 1))

        let side = min(rect.width, rect.height)
        let scale = side / 24
        var transform = CGAffineTransform(a: scale, b: 0, c: 0, d: scale,
                                         tx: rect.midX - side / 2,
                                         ty: rect.midY - side / 2)
        return mark.copy(using: &transform) ?? mark
    }
}
