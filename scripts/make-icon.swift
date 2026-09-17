// Renders AppIcon.icns from the same mark the menu bar uses. Generated rather
// than checked in as binaries, so the icon and the menu bar glyph cannot drift
// apart. Two build products cannot share a source file — this script is run
// standalone by scripts/build-app.sh, Controller.swift is compiled into the
// app — so the geometry below is a verbatim copy of the parameter block in
// `Controller.gridImage` (macos/Sources/TSMuxMenu/Controller.swift). Change one
// and you must change the other.
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

    // The menu bar mark, scaled up: geometry stays in the menu bar's own 18x14
    // point grid and is mapped into this square canvas, so every number below
    // reads the same as it does in Controller.gridImage.
    let k = (13.2 * s / 16.0) / 18.0
    let mid = CGPoint(x: s / 2, y: s / 2)
    func at(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
      CGPoint(x: mid.x + (x - 9) * k, y: mid.y + (y - 7) * k)
    }
    let hub = at(9, 7)
    let cols: [CGFloat] = [2.4, 15.6]
    let rows: [CGFloat] = [2.4, 7, 11.6]
    let node = 1.5 * k
    let hubR = 2.0 * k
    let line = 1.35 * k

    ctx.setStrokeColor(NSColor.white.cgColor)
    ctx.setFillColor(NSColor.white.cgColor)
    ctx.setLineWidth(line)
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)

    for cx in cols {
      for ry in rows {
        let from = at(cx, ry)
        ctx.beginPath()
        ctx.move(to: from)
        if abs(ry - 7) < 0.01 {
          ctx.addLine(to: hub)
        } else {
          let reach = (hub.x - from.x) * 0.62
          ctx.addCurve(
            to: hub,
            control1: CGPoint(x: from.x + reach, y: from.y),
            control2: CGPoint(x: hub.x - reach, y: hub.y))
        }
        ctx.strokePath()
        ctx.fillEllipse(
          in: CGRect(x: from.x - node, y: from.y - node, width: node * 2, height: node * 2))
      }
    }

    // Two spare channels straight up and down, greyed: capacity the hub has
    // that nothing is plugged into. Dimmed by the menu bar's own unlit levels,
    // which differ for the line and the dot.
    ctx.setStrokeColor(NSColor(white: 1, alpha: 0.26).cgColor)
    ctx.setFillColor(NSColor(white: 1, alpha: 0.5).cgColor)
    for ry in [rows[0], rows[2]] {
      let p = at(9, ry)
      ctx.beginPath()
      ctx.move(to: p)
      ctx.addLine(to: hub)
      ctx.strokePath()
      ctx.fillEllipse(in: CGRect(x: p.x - node, y: p.y - node, width: node * 2, height: node * 2))
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
