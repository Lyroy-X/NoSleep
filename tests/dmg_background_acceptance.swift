import AppKit

let image = NSBitmapImageRep(data: try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1])))!
precondition(image.pixelsWide == 1280 && image.pixelsHigh == 720)
let arrow = image.colorAt(x: 640, y: 340)!.usingColorSpace(.deviceRGB)!
precondition(arrow.redComponent < 0.3 && arrow.greenComponent < 0.7 && arrow.blueComponent < 0.8,
             "The installation arrow is missing from the background")
let paper = image.colorAt(x: 30, y: 30)!.usingColorSpace(.deviceRGB)!
precondition(paper.redComponent > 0.8 && paper.greenComponent > 0.8 && paper.blueComponent > 0.8)
print("PASS: background contains a visible arrow at the centre of the two icons")
