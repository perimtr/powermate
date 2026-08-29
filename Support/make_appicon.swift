// Draws the app icon: a knurled ring with the LED blue tucked into the
// band as an indicator arc. Exploring the "Knurl" identity on this
// branch, where the app is growing past a single device: the mark is
// abstract knurling rather than a picture of anyone's hardware, so it
// stays honest whether the input is the Griffin knob or a MIDI encoder.
//
// The icon is drawn rather than composited, which is what lets the small
// sizes differ. Fine knurling (44 shallow teeth) reads as milled metal at
// 1024 and turns to mush in 16 pixels, so at and below 64 the tooth count
// drops to 20 deeper teeth. Same trick the rendered artwork needed, for
// the same reason: judge any change at 16 and 32, not only at 1024.
//
// Palette is the product's own: graphite #121217, cream #F2EFE6, and the
// knob's LED blue #409EFF, which is also the accent on the website.
//
// Run from the repo root:
//   swift Support/make_appicon.swift Support/AppIcon.iconset
//   iconutil -c icns Support/AppIcon.iconset -o Support/AppIcon.icns

import AppKit

let graphite = NSColor(calibratedRed: 0.070, green: 0.070, blue: 0.090, alpha: 1)
let cream = NSColor(calibratedRed: 0.949, green: 0.937, blue: 0.902, alpha: 1)
let ledBlue = NSColor(calibratedRed: 0.251, green: 0.620, blue: 1.0, alpha: 1)

/// Pixel sizes at or below this get the simplified tooth count.
let smallSizeCutoff = 64

/// A circle milled into teeth. Shallow teeth read as a machined edge;
/// deep ones start to look like a gear, so keep depth small at large sizes.
func knurledPath(center: NSPoint, radius: CGFloat, teeth: Int, depth: CGFloat) -> NSBezierPath {
    let path = NSBezierPath()
    let steps = teeth * 2
    for index in 0..<steps {
        let angle = (CGFloat(index) / CGFloat(steps)) * 2 * .pi
        let r = index % 2 == 0 ? radius : radius - depth
        let point = NSPoint(x: center.x + r * cos(angle), y: center.y + r * sin(angle))
        if index == 0 { path.move(to: point) } else { path.line(to: point) }
    }
    path.close()
    return path
}

func circle(_ center: NSPoint, _ radius: CGFloat) -> NSBezierPath {
    NSBezierPath(ovalIn: NSRect(x: center.x - radius, y: center.y - radius,
                                width: radius * 2, height: radius * 2))
}

/// `squircle: false` draws the mark edge to edge. macOS wants the icon
/// grid's inset and transparent corners; a web surface rounds the image
/// itself, and handing it the inset version renders visibly smaller than
/// the icons beside it.
func draw(side: CGFloat, squircle: Bool) {
    // The mark is laid out against the 1024 grid and scaled from there.
    let scale = side / 1024
    let tile: NSRect
    if squircle {
        tile = NSRect(x: 100 * scale, y: 100 * scale,
                      width: 824 * scale, height: 824 * scale)
        NSBezierPath(roundedRect: tile, xRadius: 185 * scale, yRadius: 185 * scale).setClip()
    } else {
        tile = NSRect(x: 0, y: 0, width: side, height: side)
    }
    graphite.setFill()
    tile.fill()

    let center = NSPoint(x: tile.midX, y: tile.midY)
    // Edge to edge, the ring grows to fill the frame it is given.
    let outer = (squircle ? 300 : 372) * scale
    let hole = (squircle ? 150 : 186) * scale
    let fine = Int(side) > smallSizeCutoff
    let teeth = fine ? 44 : 20
    let depth = (fine ? 13 : 26) * scale

    cream.setFill()
    knurledPath(center: center, radius: outer, teeth: teeth, depth: depth).fill()
    graphite.setFill()
    circle(center, hole).fill()

    // The indicator sits inside the band, with cream either side of it, so
    // it reads as part of the knob rather than a sticker on top.
    let bandInner = hole
    let bandOuter = outer - depth
    let arc = NSBezierPath()
    arc.appendArc(withCenter: center, radius: (bandInner + bandOuter) / 2,
                  startAngle: -58, endAngle: 58)
    arc.lineWidth = (bandOuter - bandInner) * 0.52
    arc.lineCapStyle = .round
    ledBlue.setStroke()
    arc.stroke()
}

func render(side: Int, to url: URL, squircle: Bool = true) {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side, bitsPerSample: 8,
        samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    let context = NSGraphicsContext(bitmapImageRep: rep)!
    context.imageInterpolation = .high
    NSGraphicsContext.current = context
    draw(side: CGFloat(side), squircle: squircle)
    NSGraphicsContext.restoreGraphicsState()
    try! rep.representation(using: .png, properties: [:])!.write(to: url)
}

let out = URL(fileURLWithPath: CommandLine.arguments.count > 1
    ? CommandLine.arguments[1] : "Support/AppIcon.iconset")
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

// (file name, rendered pixel size)
let targets: [(String, Int)] = [
    ("icon_16x16.png", 16), ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024),
]
for (name, size) in targets {
    render(side: size, to: out.appendingPathComponent(name))
}

// The mark at a size downstream surfaces can scale from. The website
// lists products at 40px, which is small-size territory.
let smallForWeb = out.deletingLastPathComponent()
    .appendingPathComponent("appicon-small-256.png")
render(side: 256, to: smallForWeb, squircle: false)

print("wrote \(targets.count) sizes to \(out.path) (coarse teeth at \(smallSizeCutoff)px and below)")
print("wrote \(smallForWeb.lastPathComponent) for downstream small-size use")
