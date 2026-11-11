// Code-native icon artwork. Run from the repository root: swift app/scripts/generate_alternate_icons.swift
import AppKit
import ImageIO
import UniformTypeIdentifiers
let variants: [(String, NSColor, NSColor)] = [
  ("Midnight", NSColor(srgbRed: 0.06, green: 0.07, blue: 0.15, alpha: 1), NSColor(srgbRed: 0.55, green: 0.66, blue: 1, alpha: 1)),
  ("Sakura", NSColor(srgbRed: 0.28, green: 0.07, blue: 0.22, alpha: 1), NSColor(srgbRed: 1, green: 0.62, blue: 0.78, alpha: 1))
]
for (name, background, accent) in variants {
  for platform in ["ios", "macos"] {
    let directory = "app/\(platform)/Runner/Assets.xcassets/\(name).\(platform == "ios" ? "appiconset" : "imageset")"
    try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
    var images: [[String: String]] = []
    let specs: [(String, String, String, Int)] = platform == "ios" ? [
      ("iphone", "20x20", "2x", 40), ("iphone", "20x20", "3x", 60),
      ("iphone", "29x29", "2x", 58), ("iphone", "29x29", "3x", 87),
      ("iphone", "40x40", "2x", 80), ("iphone", "40x40", "3x", 120),
      ("iphone", "60x60", "2x", 120), ("iphone", "60x60", "3x", 180),
      ("ipad", "20x20", "1x", 20), ("ipad", "20x20", "2x", 40),
      ("ipad", "29x29", "1x", 29), ("ipad", "29x29", "2x", 58),
      ("ipad", "40x40", "1x", 40), ("ipad", "40x40", "2x", 80),
      ("ipad", "76x76", "1x", 76), ("ipad", "76x76", "2x", 152),
      ("ipad", "83.5x83.5", "2x", 167), ("ios-marketing", "1024x1024", "1x", 1024)
    ] : [("mac", "16x16", "1x", 16), ("mac", "16x16", "2x", 32),
         ("mac", "32x32", "1x", 32), ("mac", "32x32", "2x", 64),
         ("mac", "128x128", "1x", 128), ("mac", "128x128", "2x", 256),
         ("mac", "256x256", "1x", 256), ("mac", "256x256", "2x", 512),
         ("mac", "512x512", "1x", 512), ("mac", "512x512", "2x", 1024)]
    for (idiom, size, scale, pixels) in specs {
      let filename = "icon_\(pixels).png"
      let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
      let context = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8,
        bytesPerRow: pixels * 4, space: colorSpace, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
      context.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)
      let colors = [background.cgColor, accent.cgColor] as CFArray
      let gradient = CGGradient(colorsSpace: colorSpace, colors: colors, locations: [0, 1])!
      context.drawLinearGradient(gradient, start: CGPoint(x: 0, y: 1024), end: CGPoint(x: 1024, y: -900), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
      context.setStrokeColor(accent.withAlphaComponent(0.35).cgColor)
      context.setLineWidth(12)
      context.strokeEllipse(in: CGRect(x: 150, y: 150, width: 724, height: 724))
      context.setStrokeColor(CGColor(gray: 1, alpha: 1)); context.setLineWidth(72)
      context.setLineCap(.round); context.setLineJoin(.round)
      context.move(to: CGPoint(x: 330, y: 690)); context.addLine(to: CGPoint(x: 512, y: 490)); context.addLine(to: CGPoint(x: 694, y: 690))
      context.move(to: CGPoint(x: 512, y: 490)); context.addLine(to: CGPoint(x: 512, y: 300)); context.strokePath()
      let destination = CGImageDestinationCreateWithURL(URL(fileURLWithPath: "\(directory)/\(filename)") as CFURL, UTType.png.identifier as CFString, 1, nil)!
      CGImageDestinationAddImage(destination, context.makeImage()!, nil)
      guard CGImageDestinationFinalize(destination) else { fatalError("Could not write icon") }
      if platform == "ios" { images.append(["idiom": idiom, "size": size, "scale": scale, "filename": filename]) }
      else if pixels == 1024 { images.append(["idiom": "universal", "filename": filename]) }
    }
    let json = try JSONSerialization.data(withJSONObject: ["images": images, "info": ["version": 1, "author": "xcode"]], options: [.prettyPrinted, .sortedKeys])
    try json.write(to: URL(fileURLWithPath: "\(directory)/Contents.json"))
  }
}
