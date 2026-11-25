import AppKit
import Foundation

let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
for size in [16, 32, 64, 128, 256, 512, 1024] {
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    let s = CGFloat(size)
    let background = NSBezierPath(roundedRect: NSRect(x: s*0.06, y: s*0.06, width: s*0.88, height: s*0.88), xRadius: s*0.19, yRadius: s*0.19)
    NSColor(calibratedRed: 0.34, green: 0.31, blue: 0.88, alpha: 1).setFill(); background.fill()
    let play = NSBezierPath()
    play.move(to: NSPoint(x:s*0.43,y:s*0.37)); play.line(to:NSPoint(x:s*0.43,y:s*0.63)); play.line(to:NSPoint(x:s*0.64,y:s*0.5)); play.close()
    NSColor.white.setFill(); play.fill()
    let brackets = NSBezierPath()
    brackets.move(to:NSPoint(x:s*0.33,y:s*0.7)); brackets.line(to:NSPoint(x:s*0.25,y:s*0.7)); brackets.line(to:NSPoint(x:s*0.25,y:s*0.3)); brackets.line(to:NSPoint(x:s*0.33,y:s*0.3))
    brackets.move(to:NSPoint(x:s*0.67,y:s*0.7)); brackets.line(to:NSPoint(x:s*0.75,y:s*0.7)); brackets.line(to:NSPoint(x:s*0.75,y:s*0.3)); brackets.line(to:NSPoint(x:s*0.67,y:s*0.3))
    brackets.lineWidth = s*0.055; brackets.lineCapStyle = .round; brackets.lineJoinStyle = .round
    NSColor.white.withAlphaComponent(0.85).setStroke(); brackets.stroke()
    NSGraphicsContext.restoreGraphicsState()
    let data = bitmap.representation(using: .png, properties: [:])!
    if size <= 512 { try data.write(to: root.appendingPathComponent("icon_\(size)x\(size).png")) }
    if size >= 32 { try data.write(to: root.appendingPathComponent("icon_\(size/2)x\(size/2)@2x.png")) }
}
