import AppKit

let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
let image = NSImage(size: NSSize(width: 1024, height: 1024))
image.lockFocus()
let rect = NSRect(x: 70, y: 70, width: 884, height: 884)
let shape = NSBezierPath(roundedRect: rect, xRadius: 200, yRadius: 200)
NSGradient(starting: NSColor(white: 0.18, alpha: 1), ending: NSColor(white: 0.025, alpha: 1))!.draw(
  in: shape, angle: -70)
NSColor(white: 1, alpha: 0.12).setStroke()
shape.lineWidth = 2
shape.stroke()
let triangle = NSBezierPath()
triangle.move(to: NSPoint(x: 420, y: 490))
triangle.line(to: NSPoint(x: 420, y: 745))
triangle.line(to: NSPoint(x: 670, y: 618))
triangle.close()
NSColor.white.setFill()
triangle.fill()
let text = "MacTV" as NSString
let attributes: [NSAttributedString.Key: Any] = [
  .font: NSFont.systemFont(ofSize: 190, weight: .bold), .foregroundColor: NSColor.white,
]
let size = text.size(withAttributes: attributes)
text.draw(at: NSPoint(x: (1024 - size.width) / 2, y: 225), withAttributes: attributes)
image.unlockFocus()
let rep = NSBitmapImageRep(data: image.tiffRepresentation!)!
try rep.representation(using: .png, properties: [:])!.write(
  to: directory.appendingPathComponent("icon_512x512@2x.png"))
