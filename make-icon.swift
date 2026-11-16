import AppKit
import Foundation

let destination = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size * scale
        let image = NSImage(size: NSSize(width: pixels, height: pixels))
        image.lockFocus()
        let inset = CGFloat(pixels) * 0.04
        let rect = NSRect(x: inset, y: inset, width: CGFloat(pixels) - 2 * inset, height: CGFloat(pixels) - 2 * inset)
        let shape = NSBezierPath(roundedRect: rect, xRadius: CGFloat(pixels) * 0.22, yRadius: CGFloat(pixels) * 0.22)
        NSGradient(starting: NSColor(calibratedRed: 0.05, green: 0.45, blue: 0.52, alpha: 1), ending: NSColor(calibratedRed: 0.08, green: 0.20, blue: 0.34, alpha: 1))!.draw(in: shape, angle: -90)
        NSColor.white.setFill()
        let heights: [CGFloat] = [0.20, 0.40, 0.58, 0.30, 0.48]
        for (i, height) in heights.enumerated() {
            let width = CGFloat(pixels) * 0.065
            let x = CGFloat(pixels) * (0.24 + CGFloat(i) * 0.115)
            let bar = NSRect(x: x, y: CGFloat(pixels) * (1-height)/2, width: width, height: CGFloat(pixels) * height)
            NSBezierPath(roundedRect: bar, xRadius: width/2, yRadius: width/2).fill()
        }
        image.unlockFocus()
        let bitmap = NSBitmapImageRep(data: image.tiffRepresentation!)!
        let filename = "icon_\(size)x\(size)\(scale == 2 ? "@2x" : "").png"
        try bitmap.representation(using: .png, properties: [:])!.write(to: destination.appendingPathComponent(filename))
    }
}
