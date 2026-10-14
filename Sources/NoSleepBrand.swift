import AppKit

enum NoSleepBrand {
    // A vector template keeps the crescent and spark sharp in both menu appearances.
    static let menuIcon: NSImage = {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            NSColor.black.setFill()
            let moon = NSBezierPath()
            moon.move(to: NSPoint(x: 10.8, y: 16.2))
            moon.curve(to: NSPoint(x: 1.6, y: 8.4), controlPoint1: NSPoint(x: 6, y: 16.4), controlPoint2: NSPoint(x: 1.6, y: 12.4))
            moon.curve(to: NSPoint(x: 9.1, y: 1.4), controlPoint1: NSPoint(x: 1.6, y: 4), controlPoint2: NSPoint(x: 5, y: 1.4))
            moon.curve(to: NSPoint(x: 16.2, y: 6.2), controlPoint1: NSPoint(x: 12.3, y: 1.4), controlPoint2: NSPoint(x: 15.1, y: 3.5))
            moon.curve(to: NSPoint(x: 15.6, y: 6.5), controlPoint1: NSPoint(x: 16.5, y: 6.8), controlPoint2: NSPoint(x: 16.1, y: 7))
            moon.curve(to: NSPoint(x: 7.7, y: 9), controlPoint1: NSPoint(x: 12.6, y: 3.2), controlPoint2: NSPoint(x: 8.1, y: 5.2))
            moon.curve(to: NSPoint(x: 10.9, y: 15.7), controlPoint1: NSPoint(x: 7.4, y: 11.9), controlPoint2: NSPoint(x: 8.8, y: 14.1))
            moon.curve(to: NSPoint(x: 10.8, y: 16.2), controlPoint1: NSPoint(x: 11.5, y: 16.1), controlPoint2: NSPoint(x: 11.3, y: 16.3))
            moon.close()
            moon.fill()
            NSBezierPath(ovalIn: NSRect(x: 11.9, y: 10.3, width: 4.5, height: 4.5)).fill()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "NoSleep"
        return image
    }()
}
