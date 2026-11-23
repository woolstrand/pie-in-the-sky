import AppKit

/// Menu bar icon: headphones whose headband is twisted like a pretzel. Drawn in code as a
/// template image, so it adapts to light/dark menu bars.
enum Icon {
    static let size = NSSize(width: 18, height: 18)
    private static let line: CGFloat = 1.5

    /// `filled`: solid ear cups (used while the proxy is active).
    static func headphones(filled: Bool) -> NSImage {
        let image = NSImage(size: size, flipped: false) { _ in
            draw(filled: filled)
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Pie in the Sky"
        return image
    }

    // Coordinates are in points, origin bottom-left, 18×18 canvas. The band rises from the left
    // cup, crosses the centre, loops over the top and crosses back down to the right cup.
    private static let cross = NSPoint(x: 9, y: 10.2)

    private static let leftCup = NSPoint(x: 3.3, y: 7.4), rightCup = NSPoint(x: 14.7, y: 7.4)
    private static let rightSide = NSPoint(x: 15.7, y: 13.2), leftSide = NSPoint(x: 2.3, y: 13.2)

    /// Left cup → crossing → right side of the loop.
    private static func addStrandA(_ p: NSBezierPath) {
        p.curve(to: cross, controlPoint1: NSPoint(x: 3.3, y: 9.4), controlPoint2: NSPoint(x: 7.9, y: 8.4))
        p.curve(to: rightSide, controlPoint1: NSPoint(x: 10.1, y: 12.0), controlPoint2: NSPoint(x: 15.7, y: 10.6))
    }

    /// The whole band: strand A, over the top, then back down through the crossing to the right cup.
    private static var band: NSBezierPath {
        let p = NSBezierPath()
        p.move(to: leftCup)
        addStrandA(p)
        p.curve(to: leftSide, controlPoint1: NSPoint(x: 15.7, y: 18.2), controlPoint2: NSPoint(x: 2.3, y: 18.2))
        p.curve(to: cross, controlPoint1: NSPoint(x: 2.3, y: 10.6), controlPoint2: NSPoint(x: 7.9, y: 12.0))
        p.curve(to: rightCup, controlPoint1: NSPoint(x: 10.1, y: 8.4), controlPoint2: NSPoint(x: 14.7, y: 9.4))
        return p
    }

    /// The part of the band that passes over the other at the crossing.
    private static var strandA: NSBezierPath {
        let p = NSBezierPath()
        p.move(to: leftCup)
        addStrandA(p)
        return p
    }

    private static func draw(filled: Bool) {
        NSColor.black.set()
        // The whole band as one path (no seams at the joins), then the over-strand on top.
        let band = band
        band.lineWidth = line
        band.lineJoinStyle = .round
        band.stroke()

        // Strand A passes over strand B: cut a gap into B around the crossing, then draw A.
        if let ctx = NSGraphicsContext.current {
            ctx.saveGraphicsState()
            ctx.compositingOperation = .clear
            let gap = strandA
            gap.lineWidth = line + 1.6
            gap.lineCapStyle = .butt
            NSBezierPath(ovalIn: NSRect(x: cross.x - 2.6, y: cross.y - 2.6, width: 5.2, height: 5.2)).addClip()
            gap.stroke()
            ctx.restoreGraphicsState()
        }
        let a = strandA
        a.lineWidth = line
        a.lineCapStyle = .butt
        a.stroke()

        // Ear cups.
        for x in [1.4, 12.8] as [CGFloat] {
            let cup = NSBezierPath(roundedRect: NSRect(x: x, y: 1.5, width: 3.8, height: 5.9), xRadius: 1.4, yRadius: 1.4)
            if filled {
                cup.fill()
            } else {
                cup.lineWidth = line
                cup.stroke()
            }
        }
    }
}
