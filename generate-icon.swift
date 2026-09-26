import AppKit

// Keep the Finder/Dock icon in step with the bookmark ghost in the menu bar.
let destination = CommandLine.arguments[1]
let size: CGFloat = 1024
let image = NSImage(size: NSSize(width: size, height: size))
image.lockFocus()

let background = NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: size, height: size), xRadius: 230, yRadius: 230)
NSColor(calibratedRed: 0.18, green: 0.23, blue: 0.38, alpha: 1).setFill()
background.fill()

let ghost = NSBezierPath()
ghost.move(to: NSPoint(x: 245, y: 465))
ghost.curve(to: NSPoint(x: 512, y: 800), controlPoint1: NSPoint(x: 245, y: 660), controlPoint2: NSPoint(x: 345, y: 800))
ghost.curve(to: NSPoint(x: 779, y: 465), controlPoint1: NSPoint(x: 679, y: 800), controlPoint2: NSPoint(x: 779, y: 660))
ghost.line(to: NSPoint(x: 779, y: 235))
ghost.curve(to: NSPoint(x: 730, y: 200), controlPoint1: NSPoint(x: 779, y: 195), controlPoint2: NSPoint(x: 755, y: 185))
ghost.line(to: NSPoint(x: 535, y: 305))
ghost.curve(to: NSPoint(x: 489, y: 305), controlPoint1: NSPoint(x: 522, y: 312), controlPoint2: NSPoint(x: 502, y: 312))
ghost.line(to: NSPoint(x: 294, y: 200))
ghost.curve(to: NSPoint(x: 245, y: 235), controlPoint1: NSPoint(x: 269, y: 185), controlPoint2: NSPoint(x: 245, y: 195))
ghost.line(to: NSPoint(x: 245, y: 465))
ghost.close()
ghost.windingRule = .evenOdd
ghost.appendOval(in: NSRect(x: 360, y: 500, width: 72, height: 72))
ghost.appendOval(in: NSRect(x: 592, y: 500, width: 72, height: 72))
ghost.move(to: NSPoint(x: 474, y: 445))
ghost.curve(to: NSPoint(x: 550, y: 445), controlPoint1: NSPoint(x: 494, y: 452), controlPoint2: NSPoint(x: 530, y: 452))
ghost.curve(to: NSPoint(x: 474, y: 445), controlPoint1: NSPoint(x: 550, y: 388), controlPoint2: NSPoint(x: 474, y: 388))
ghost.close()
NSColor.white.setFill()
ghost.fill()

image.unlockFocus()
guard let tiff = image.tiffRepresentation,
      let bitmap = NSBitmapImageRep(data: tiff),
      let png = bitmap.representation(using: .png, properties: [:]) else {
    fatalError("Unable to render app icon")
}
try png.write(to: URL(fileURLWithPath: destination))
