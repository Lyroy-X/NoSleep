import AppKit

func brandTests() throws {
    let image = NoSleepBrand.menuIcon
    assert(image.isTemplate && image.size == NSSize(width: 18, height: 18))
    assert(image.accessibilityDescription == "NoSleep")
    for size in [18, 36] {
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        image.draw(in: NSRect(x: 0, y: 0, width: size, height: size))
        NSGraphicsContext.restoreGraphicsState()
        var pixels = Set<Int>()
        for y in 0..<size { for x in 0..<size {
            if bitmap.colorAt(x: x, y: y)!.alphaComponent > 0.5 { pixels.insert(y * size + x) }
        } }
        assert(!pixels.isEmpty)
        // The spark must not disappear or merge into the moon at normal/Retina scale.
        var components = [Int]()
        while let first = pixels.first {
            var stack = [first], count = 0
            pixels.remove(first)
            while let point = stack.popLast() {
                count += 1
                let x = point % size, y = point / size
                for (dx, dy) in [(-1, 0), (1, 0), (0, -1), (0, 1)] {
                    let nx = x + dx, ny = y + dy
                    if nx >= 0 && nx < size && ny >= 0 && ny < size {
                        let next = ny * size + nx
                        if pixels.remove(next) != nil { stack.append(next) }
                    }
                }
            }
            components.append(count)
        }
        assert(components.count == 2 && components.min()! >= 10)
        assert(bitmap.colorAt(x: 0, y: 0)!.alphaComponent == 0)
        assert(bitmap.colorAt(x: size - 1, y: size - 1)!.alphaComponent == 0)
    }
    print("PASS: moon template has separate crescent/spark and transparency at 1x/2x")
}
