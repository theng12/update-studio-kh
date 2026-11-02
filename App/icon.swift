// Draws the app icon PNG: a white arrow into a tray on a green squircle, the page's mark.
import AppKit
let size = 1024.0
let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { _ in
    let tile = NSRect(x: 100, y: 100, width: 824, height: 824)
    NSGraphicsContext.current?.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowOffset = NSSize(width: 0, height: -12)
    shadow.shadowBlurRadius = 28
    shadow.shadowColor = NSColor(white: 0, alpha: 0.28)
    shadow.set()
    let squircle = NSBezierPath(roundedRect: tile, xRadius: 185, yRadius: 185)
    NSColor(calibratedRed: 0.11, green: 0.42, blue: 0.32, alpha: 1).setFill()
    squircle.fill()
    NSGraphicsContext.current?.restoreGraphicsState()
    NSGradient(starting: NSColor(calibratedRed: 0.20, green: 0.56, blue: 0.43, alpha: 1),
               ending: NSColor(calibratedRed: 0.09, green: 0.36, blue: 0.27, alpha: 1))!.draw(in: squircle, angle: -90)
    // The mark on a 32-unit grid, as in the page's SVG: an arrow down into an open tray.
    let unit = 824.0 / 32, ox = 100.0
    func p(_ x: Double, _ y: Double) -> NSPoint { NSPoint(x: ox + x * unit, y: ox + (32 - y) * unit) }
    let mark = NSBezierPath()
    mark.move(to: p(16, 7)); mark.line(to: p(16, 19))
    mark.move(to: p(11, 14)); mark.line(to: p(16, 19)); mark.line(to: p(21, 14))
    mark.move(to: p(9, 21)); mark.line(to: p(9, 24)); mark.line(to: p(23, 24)); mark.line(to: p(23, 21))
    mark.lineWidth = 2.4 * unit
    mark.lineCapStyle = .round
    mark.lineJoinStyle = .round
    NSColor.white.setStroke()
    mark.stroke()
    return true
}
let rep = NSBitmapImageRep(data: image.tiffRepresentation!)!
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
