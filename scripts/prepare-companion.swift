// Run from the repo root: swift scripts/prepare-companion.swift
// Trims the companion poses in designs/branding/final/src-companion to their visible silhouette
// (the same way prepare-brand.swift trims the mascots), writes them beside the other mascots and
// into the app's Mascot asset catalog. The sources stay untouched.
import AppKit
import ImageIO
import UniformTypeIdentifiers

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let output = root.appendingPathComponent("designs/branding/final")
let source = output.appendingPathComponent("src-companion")
let catalog = root.appendingPathComponent("App/Assets.xcassets/Mascot")

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

func canvas(_ width: Int, _ height: Int) -> CGContext {
    CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
              space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
}

func resize(_ image: CGImage, _ width: Int, _ height: Int) -> CGImage {
    let ctx = canvas(width, height)
    ctx.interpolationQuality = .high
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    return ctx.makeImage()!
}

/// `padding` is a fraction of the longer side. Peeks get none at the bottom, so their paws sit
/// exactly on whatever edge they're peeking over.
func trim(_ image: CGImage, padding fraction: Double, bottomPadding: Bool) -> CGImage {
    let ctx = canvas(image.width, image.height)
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    let bytes = ctx.data!.assumingMemoryBound(to: UInt8.self)
    var minX = image.width, minY = image.height, maxX = 0, maxY = 0
    for y in 0..<image.height {
        for x in 0..<image.width where bytes[(y * image.width + x) * 4 + 3] > 8 {
            minX = min(minX, x); maxX = max(maxX, x)
            minY = min(minY, y); maxY = max(maxY, y)
        }
    }
    let padding = Int(ceil(Double(max(maxX - minX + 1, maxY - minY + 1)) * fraction))
    let bottom = bottomPadding ? padding : 0
    let width = maxX - minX + 1 + 2 * padding, height = maxY - minY + 1 + padding + bottom
    let trimmed = canvas(width, height)
    // Bitmap rows start at the top; CGContext drawing coordinates start at the bottom.
    let bottomInset = image.height - maxY - 1
    trimmed.draw(ctx.makeImage()!, in: CGRect(x: padding - minX, y: bottom - bottomInset, width: image.width, height: image.height))
    return trimmed.makeImage()!
}

for name in ["peek", "peek-sleepy", "celebrate", "trot"] {
    let isPeek = name.hasPrefix("peek")
    let trimmed = trim(load(source.appendingPathComponent("\(name).png")), padding: 0.03, bottomPadding: !isPeek)
    // The companion is drawn at most ~200 pt wide, so 600 px covers 3×.
    let scale = min(1, 600.0 / Double(max(trimmed.width, trimmed.height)))
    let image = resize(trimmed, Int((Double(trimmed.width) * scale).rounded()), Int((Double(trimmed.height) * scale).rounded()))
    write(image, output.appendingPathComponent("mascot-\(name).png"))
    let set = catalog.appendingPathComponent("\(name).imageset")
    write(image, set.appendingPathComponent("\(name).png"))
    let contents = """
    {
      "images" : [
        {
          "filename" : "\(name).png",
          "idiom" : "universal"
        }
      ],
      "info" : {
        "author" : "xcode",
        "version" : 1
      }
    }

    """
    try! contents.write(to: set.appendingPathComponent("Contents.json"), atomically: true, encoding: .utf8)
}
