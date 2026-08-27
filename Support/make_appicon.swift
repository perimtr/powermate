// Builds the PowerMate .iconset from Support/appicon-source.png.
//
// The artwork is composited into the standard macOS icon squircle
// (80.5% of the canvas, corner radius 18.1%, transparent outside it).
//
// Small sizes get DIFFERENT artwork, which is what .icns is for. The
// full render carries a command glyph above the knob and lettering on
// the base; both are illegible below about 128px and turn the icon into
// a dark smudge. At 16, 32 and 64 pixels the source is cropped to the
// knob itself, so the aluminium disc and the blue LED ring fill the
// tile and still read. Apple simplifies its own icons the same way.
//
// Run from the repo root:
//   swift Support/make_appicon.swift Support/AppIcon.iconset
//   iconutil -c icns Support/AppIcon.iconset -o Support/AppIcon.icns

import AppKit

let sourcePath = "Support/appicon-source.png"
guard let source = NSImage(contentsOfFile: sourcePath) else {
    fputs("\(sourcePath) not found (run from the repo root)\n", stderr)
    exit(1)
}
var proposed = NSRect(origin: .zero, size: source.size)
guard let full = source.cgImage(forProposedRect: &proposed, context: nil, hints: nil) else {
    fputs("could not read \(sourcePath) as a bitmap\n", stderr)
    exit(1)
}

// The knob and its full glow, without the command glyph above it.
// Expressed as fractions of the source so the crop survives a re-render
// at another resolution. The knob with its LED ring spans nearly the
// whole width of the artwork, so this is wide: cropping tighter clips
// the glow and leaves the disc jammed against the frame.
let knobCrop = CGRect(
    x: CGFloat(full.width) * 0.106, y: CGFloat(full.height) * 0.216,
    width: CGFloat(full.width) * 0.788, height: CGFloat(full.height) * 0.788)
guard let knob = full.cropping(to: knobCrop) else {
    fputs("crop failed\n", stderr)
    exit(1)
}

// The artwork's own background, sampled from a corner that is only
// background, so the padding around the knob is the same material.
let backdrop: NSColor = {
    let rep = NSBitmapImageRep(cgImage: full)
    return rep.colorAt(x: 6, y: 6) ?? NSColor(calibratedWhite: 0.09, alpha: 1)
}()

/// How much of the small tile the knob occupies. The rest is backdrop,
/// which is what keeps the disc from touching the edge.
let knobScale: CGFloat = 0.86

/// Pixel sizes at or below this use the simplified artwork.
let smallSizeCutoff = 64

/// `squircle: false` writes the art edge to edge. macOS wants the icon
/// grid's inset and transparent corners, but a web surface applies its
/// own rounding, and handing it the inset version makes the icon render
/// visibly smaller than icons that fill their frame.
func render(
    _ art: CGImage, size: Int, to url: URL,
    squircle: Bool = true, padWith backdrop: NSColor? = nil, scale: CGFloat = 1
) {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
        samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    let context = NSGraphicsContext(bitmapImageRep: rep)!
    context.imageInterpolation = .high
    NSGraphicsContext.current = context

    let side = CGFloat(size)
    let tile = squircle
        ? NSRect(x: side * 0.09766, y: side * 0.09766,
                 width: side * 0.80469, height: side * 0.80469)
        : NSRect(x: 0, y: 0, width: side, height: side)
    if squircle {
        NSBezierPath(
            roundedRect: tile, xRadius: side * 0.18066, yRadius: side * 0.18066
        ).setClip()
    }
    // Fill first so the space around a scaled-down knob is the artwork's
    // own material rather than a transparent gap.
    if let backdrop {
        backdrop.setFill()
        tile.fill()
    }
    let art_rect = tile.insetBy(
        dx: tile.width * (1 - scale) / 2, dy: tile.height * (1 - scale) / 2)
    context.cgContext.draw(art, in: art_rect)

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
    let small = size <= smallSizeCutoff
    render(
        small ? knob : full, size: size, to: out.appendingPathComponent(name),
        padWith: small ? backdrop : nil, scale: small ? knobScale : 1)
}

// The knob artwork at a size downstream surfaces can scale from. The
// website lists products at 40px, which is small-size territory, so it
// needs this rather than the full render. Written edge to edge: web
// surfaces round it themselves, and the icon grid's inset would make it
// render smaller than the icons beside it.
let smallForWeb = out.deletingLastPathComponent()
    .appendingPathComponent("appicon-small-256.png")
render(knob, size: 256, to: smallForWeb, squircle: false,
       padWith: backdrop, scale: knobScale)

print("wrote \(targets.count) sizes to \(out.path) (knob-only artwork at \(smallSizeCutoff)px and below)")
print("wrote \(smallForWeb.lastPathComponent) for downstream small-size use")
