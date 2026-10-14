import AppKit

func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw NSError(domain: "NoSleep.IconBackground", code: 1,
        userInfo: [NSLocalizedDescriptionKey: message]) }
}

do {
    let app = URL(fileURLWithPath: CommandLine.arguments[1]).standardizedFileURL.path
    try require(FileManager.default.fileExists(atPath: app + "/Contents/Info.plist"),
                "Icon check requires an existing app bundle")
    let source = NSBitmapImageRep(data: try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[2])))!
    for (x, y) in [(0, 0), (source.pixelsWide - 1, 0), (0, source.pixelsHigh - 1),
                   (source.pixelsWide - 1, source.pixelsHigh - 1)] {
        let color = source.colorAt(x: x, y: y)!.usingColorSpace(.deviceRGB)!
        try require(color.alphaComponent >= 0.99, "Source background must reach the opaque corners")
        try require(color.blueComponent > color.redComponent && color.redComponent < 0.35,
                    "Source corners must keep the navy background")
    }
    if #available(macOS 26, *) {
        // NSWorkspace returns the system-processed icon, not just the raw ICNS.
        let image = NSWorkspace.shared.icon(forFile: app)
        image.size = NSSize(width: 1024, height: 1024)
        let bitmap = NSBitmapImageRep(data: image.tiffRepresentation!)!
        for (x, y) in [(0.12, 0.5), (0.88, 0.5), (0.5, 0.12), (0.5, 0.88)] {
            let color = bitmap.colorAt(x: Int(Double(bitmap.pixelsWide) * x),
                y: Int(Double(bitmap.pixelsHigh) * y))!.usingColorSpace(.deviceRGB)!
            try require(color.alphaComponent > 0.9 && color.redComponent < 0.35 &&
                        color.greenComponent < 0.35 && color.blueComponent < 0.55 &&
                        color.blueComponent > color.redComponent,
                        "System icon contains a pale outer tile instead of the navy background")
        }
        if CommandLine.arguments.count > 3 {
            try bitmap.representation(using: .png, properties: [:])!.write(
                to: URL(fileURLWithPath: CommandLine.arguments[3]))
        }
        print("PASS: system-rendered macOS icon keeps navy edges without a pale outer tile")
    } else {
        print("SKIP: modern system masking requires macOS 26+; full-bleed source verified")
    }
} catch {
    fputs("FAIL: \(error.localizedDescription)\n", stderr)
    exit(1)
}
