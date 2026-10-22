// Run from the repo root: swift scripts/prepare-brand.swift
// Only resamples approved artwork. Sources in final/src stay untouched.
import AppKit
import ImageIO
import UniformTypeIdentifiers

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let output = root.appendingPathComponent("designs/branding/final")
let source = output.appendingPathComponent("src")

func load(_ url: URL) -> CGImage {
    let data = CGImageSourceCreateWithURL(url as CFURL, nil)!
    return CGImageSourceCreateImageAtIndex(data, 0, nil)!
}

func write(_ image: CGImage, _ url: URL) {
    try! FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, image, nil)
    precondition(CGImageDestinationFinalize(dest))
    print("\(url.path.replacingOccurrences(of: root.path + "/", with: "")): \(image.width)×\(image.height)")
}

func canvas(_ width: Int, _ height: Int, opaque: Bool = false) -> CGContext {
    CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
              space: CGColorSpace(name: CGColorSpace.sRGB)!,
              bitmapInfo: (opaque ? CGImageAlphaInfo.noneSkipLast : .premultipliedLast).rawValue)!
}

func resize(_ image: CGImage, _ width: Int, _ height: Int, opaque: Bool = false) -> CGImage {
    let ctx = canvas(width, height, opaque: opaque)
    ctx.interpolationQuality = .high
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    return ctx.makeImage()!
}

let light = resize(load(source.appendingPathComponent("icon-light.png")), 1024, 1024, opaque: true)
let dark = resize(load(source.appendingPathComponent("icon-dark.png")), 1024, 1024, opaque: true)
write(light, output.appendingPathComponent("icon-1024.png"))
write(dark, output.appendingPathComponent("icon-dark-1024.png"))
// Apple's tinted artwork is grayscale. The dark source keeps a bright subject on a
// subdued background, so the system's chosen tint reads clearly at Home Screen size.
let gray = CGContext(data: nil, width: 1024, height: 1024, bitsPerComponent: 8, bytesPerRow: 1024,
                     space: CGColorSpace(name: CGColorSpace.genericGrayGamma2_2)!, bitmapInfo: CGImageAlphaInfo.none.rawValue)!
gray.draw(dark, in: CGRect(x: 0, y: 0, width: 1024, height: 1024))
write(gray.makeImage()!, output.appendingPathComponent("icon-tinted-1024.png"))

for name in ["listening", "sleeping", "waving", "empty", "searching", "confused"] {
    let image = load(source.appendingPathComponent("mascot-\(name).png"))
    let ctx = canvas(image.width, image.height)
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    let bytes = ctx.data!.assumingMemoryBound(to: UInt8.self)
    var minX = image.width, minY = image.height, maxX = 0, maxY = 0
    for y in 0..<image.height {
        for x in 0..<image.width where bytes[(y * image.width + x) * 4 + 3] > 2 {
            minX = min(minX, x); maxX = max(maxX, x)
            minY = min(minY, y); maxY = max(maxY, y)
        }
    }
    // Three percent transparent breathing room around the visible silhouette.
    let padding = Int(ceil(Double(max(maxX - minX + 1, maxY - minY + 1)) * 0.03))
    let width = maxX - minX + 1 + 2 * padding, height = maxY - minY + 1 + 2 * padding
    let trimmed = canvas(width, height)
    // Bitmap rows start at the top; CGContext drawing coordinates start at the bottom.
    let bottomInset = image.height - maxY - 1
    trimmed.draw(ctx.makeImage()!, in: CGRect(x: padding - minX, y: padding - bottomInset, width: image.width, height: image.height))
    let scale = min(1, 800.0 / Double(max(width, height)))
    write(resize(trimmed.makeImage()!, Int((Double(width) * scale).rounded()), Int((Double(height) * scale).rounded())),
          output.appendingPathComponent("mascot-\(name).png"))
    let processed = load(output.appendingPathComponent("mascot-\(name).png"))
    write(processed, root.appendingPathComponent("App/Assets.xcassets/Mascot/\(name).imageset/\(name).png"))
    if ["waving", "empty", "confused"].contains(name) {
        write(processed, root.appendingPathComponent("web/public/mascots/\(name).png"))
    }
}

let iconSet = root.appendingPathComponent("App/Assets.xcassets/AppIcon.appiconset")
for size in [16, 32, 64, 128, 256, 512, 1024] {
    write(resize(light, size, size, opaque: true), iconSet.appendingPathComponent("icon-\(size).png"))
}
write(light, iconSet.appendingPathComponent("icon-mac-1024.png"))
for variant in ["dark", "tinted"] {
    write(load(output.appendingPathComponent("icon-\(variant)-1024.png")), iconSet.appendingPathComponent("icon-\(variant)-1024.png"))
}
write(light, root.appendingPathComponent("App/Assets.xcassets/BrandIcon.imageset/icon-1024.png"))
write(dark, root.appendingPathComponent("App/Assets.xcassets/BrandIcon.imageset/icon-dark-1024.png"))
let web = root.appendingPathComponent("web/public")
for (name, size) in [("favicon-16", 16), ("favicon-32", 32), ("favicon", 32), ("apple-touch-icon", 180), ("icon-192", 192), ("icon-512", 512), ("icon", 192)] {
    write(resize(light, size, size, opaque: true), web.appendingPathComponent("\(name).png"))
}

// A deterministic social card using the same cream and rounded heavy type as the app.
let card = canvas(1200, 630, opaque: true)
card.setFillColor(CGColor(red: 245/255, green: 238/255, blue: 227/255, alpha: 1))
card.fill(CGRect(x: 0, y: 0, width: 1200, height: 630))
card.saveGState()
card.addPath(CGPath(roundedRect: CGRect(x: 88, y: 339, width: 144, height: 144), cornerWidth: 32, cornerHeight: 32, transform: nil))
card.clip()
card.draw(light, in: CGRect(x: 88, y: 339, width: 144, height: 144))
card.restoreGState()
let listening = load(output.appendingPathComponent("mascot-listening.png"))
let mascotWidth: CGFloat = 390
let mascotHeight = mascotWidth * CGFloat(listening.height) / CGFloat(listening.width)
card.draw(listening, in: CGRect(x: 730, y: (630 - mascotHeight) / 2, width: mascotWidth, height: mascotHeight))
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(cgContext: card, flipped: false)
let rounded = NSFont.systemFont(ofSize: 104, weight: .heavy).fontDescriptor.withDesign(.rounded)!
("Poddle" as NSString).draw(at: NSPoint(x: 78, y: 196), withAttributes: [.font: NSFont(descriptor: rounded, size: 104)!, .foregroundColor: NSColor(srgbRed: 43/255, green: 35/255, blue: 32/255, alpha: 1)])
NSGraphicsContext.restoreGraphicsState()
write(card.makeImage()!, output.appendingPathComponent("og-default.png"))
write(card.makeImage()!, web.appendingPathComponent("og-default.png"))
