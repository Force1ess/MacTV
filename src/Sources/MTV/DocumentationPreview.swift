import AppKit
import MTVCore

/// Reproducible documentation artwork generated entirely by this project.
/// Explicit diagnostic mode: no user library, credentials or network content.
@MainActor enum DocumentationPreview {
  static func prepare(_ model: AppModel) throws {
    guard CommandLine.arguments.contains("--ui-smoke"), CommandLine.arguments.contains("--documentation-preview") else { return }
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("mactv-documentation-" + UUID().uuidString)
    let names = ["Aurora", "The Quiet Coast", "After Hours", "Wild Horizons", "Orbit", "Summer Light"]
    let colors: [[CGFloat]] = [[0.14,0.36,0.52], [0.12,0.48,0.5], [0.32,0.16,0.43], [0.4,0.36,0.16], [0.18,0.24,0.46], [0.55,0.28,0.17]]
    var items: [MediaItem] = []
    for (index, name) in names.enumerated() {
      let folder = root.appendingPathComponent(String(index))
      try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
      for (filename, width, height) in [("poster.jpg",600,900),("fanart.jpg",1920,1080)] {
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
          space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw CocoaError(.fileWriteUnknown) }
        let c = colors[index]
        let palette = [CGColor(red:c[0]*0.2,green:c[1]*0.2,blue:c[2]*0.3,alpha:1), CGColor(red:c[0],green:c[1],blue:c[2],alpha:1)]
        let w = CGFloat(width), h = CGFloat(height)
        if let gradient = CGGradient(colorsSpace: context.colorSpace, colors: palette as CFArray, locations: [0,1]) {
          context.drawLinearGradient(gradient, start: .zero, end: CGPoint(x:w,y:h), options: [])
        }
        context.setFillColor(CGColor(red:0.98,green:0.77,blue:0.61,alpha:0.8))
        context.fillEllipse(in: CGRect(x:w*0.63,y:h*0.47,width:w*0.21,height:w*0.21))
        for layer in 0..<3 {
          let path = CGMutablePath(); path.move(to:.zero); path.addLine(to:CGPoint(x:0,y:h*CGFloat(0.2+Double(layer)*0.1)))
          for step in 0...8 {
            let x = w * CGFloat(step) / 8
            let y = h * (CGFloat(0.22+Double(layer)*0.08) + CGFloat(sin(Double(step+index+layer)*1.4))*0.10)
            path.addLine(to:CGPoint(x:x,y:y))
          }
          path.addLine(to:CGPoint(x:w,y:0)); path.closeSubpath()
          context.setFillColor(CGColor(gray:CGFloat(layer)*0.025,alpha:0.7));context.addPath(path);context.fillPath()
        }
        guard let image = context.makeImage(), let data = NSBitmapImageRep(cgImage:image).representation(using:.jpeg,properties:[.compressionFactor:0.9]) else { throw CocoaError(.fileWriteUnknown) }
        try data.write(to:folder.appendingPathComponent(filename))
      }
      items.append(MediaItem(id:"documentation-\(index)", title:name,
        subtitle:"2026 · Original demo artwork", overview:"A journey beyond the everyday. Discover something extraordinary on your big screen.",
        poster:folder.appendingPathComponent("poster.jpg").absoluteString))
    }
    model.mediaRoot = root.path
    model.library = items; model.libraryCatalog = LibraryCatalog.build(items)
    model.setupGuideVisible = false; model.notice = nil; model.navigate(.home)
  }
}
