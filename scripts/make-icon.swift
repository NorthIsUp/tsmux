// Renders AppIcon.icns from the same mark the menu bar uses: a dot grid with
// a chevron rising through it. Generated rather than checked in as binaries,
// so the icon and the menu bar glyph cannot drift apart.
import AppKit
import Foundation

func drawIcon(size: CGFloat) -> NSImage {
  let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { _ in
    guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
    let s = size

    // macOS app icons sit on a rounded square with a little breathing room.
    let inset = s * 0.055
    let rect = CGRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
    let radius = rect.width * 0.2237  // Apple's squircle-ish corner ratio
    let path = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
    ctx.saveGState()
    ctx.addPath(path)
    ctx.clip()
    let colors =
      [
        NSColor(srgbRed: 0.26, green: 0.42, blue: 0.96, alpha: 1).cgColor,
        NSColor(srgbRed: 0.16, green: 0.24, blue: 0.72, alpha: 1).cgColor,
      ] as CFArray
    if let grad = CGGradient(
      colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1])
    {
      ctx.drawLinearGradient(
        grad, start: CGPoint(x: rect.minX, y: rect.maxY),
        end: CGPoint(x: rect.maxX, y: rect.minY), options: [])
    }
    ctx.restoreGState()

    // A multiplexer: several tailnets on the left and right, each running on
    // its own line, all converging on one hub. That is literally what tsmux
    // does, so the mark says it rather than decorating it.
    let u = s / 16.0
    let hub = CGPoint(x: 8 * u, y: 8 * u)
    let colL = 3.05 * u
    let colR = 12.95 * u
    let rows: [CGFloat] = [4.05, 8.0, 11.95].map { $0 * u }
    let node = 1.28 * u
    let hubR = 1.72 * u
    let line = 0.92 * u

    ctx.setStrokeColor(NSColor.white.cgColor)
    ctx.setFillColor(NSColor.white.cgColor)
    ctx.setLineWidth(line)
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)

    for x in [colL, colR] {
      let dir: CGFloat = x < hub.x ? 1 : -1
      for y in rows {
        ctx.beginPath()
        ctx.move(to: CGPoint(x: x, y: y))
        if abs(y - hub.y) < 0.01 {
          ctx.addLine(to: CGPoint(x: hub.x, y: y))
        } else {
          // Leave the node flat, then bend once into the hub — the straight
          // run is what makes the lines read as separate channels.
          // Run flat, then dive: approaching the hub diagonally rather than
          // horizontally keeps the centre column clear for the spare channels.
          let turn = CGPoint(x: x + dir * 1.75 * u, y: y)
          ctx.addLine(to: turn)
          ctx.addCurve(
            to: hub,
            control1: CGPoint(x: turn.x + dir * 1.15 * u, y: y),
            control2: CGPoint(x: hub.x - dir * 1.5 * u, y: y - (y - hub.y) * 0.62))
        }
        ctx.strokePath()
      }
    }

    for x in [colL, colR] {
      for y in rows {
        ctx.fillEllipse(in: CGRect(x: x - node, y: y - node, width: node * 2, height: node * 2))
      }
    }
    // Two more channels straight up and down, greyed: capacity the hub has
    // but nothing is plugged into yet. They keep the mark from reading as a
    // fixed six-way splitter.
    let spare: [CGFloat] = [rows[2], rows[0]]
    let grey = NSColor(white: 1, alpha: 0.62)
    ctx.setStrokeColor(grey.cgColor)
    ctx.setFillColor(grey.cgColor)
    for y in spare {
      ctx.beginPath()
      ctx.move(to: CGPoint(x: hub.x, y: y))
      ctx.addLine(to: hub)
      ctx.strokePath()
      ctx.fillEllipse(
        in: CGRect(x: hub.x - node, y: y - node, width: node * 2, height: node * 2))
    }

    ctx.setFillColor(NSColor.white.cgColor)
    ctx.fillEllipse(
      in: CGRect(x: hub.x - hubR, y: hub.y - hubR, width: hubR * 2, height: hubR * 2))

    return true
  }
  return image
}

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.iconset"
try? FileManager.default.createDirectory(
  atPath: out, withIntermediateDirectories: true)

// The set iconutil expects: each nominal size at 1x and 2x.
for (nominal, scale) in [
  (16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2),
] {
  let px = CGFloat(nominal * scale)
  let img = drawIcon(size: px)
  guard let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
    let png = rep.representation(using: .png, properties: [:])
  else { continue }
  let suffix = scale == 1 ? "" : "@2x"
  let name = "\(out)/icon_\(nominal)x\(nominal)\(suffix).png"
  try? png.write(to: URL(fileURLWithPath: name))
}
print("wrote \(out)")
