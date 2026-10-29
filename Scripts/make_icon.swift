// Builds Resources/Icon/Saywell.icns from the square artwork (Resources/Icon/Saywell-source.jpg):
// cuts the rounded tile out of its white background, places it on Apple's icon grid
// (824 px tile on a 1024 px canvas), and writes every size iconutil needs.
// Usage: swift Scripts/make_icon.swift [source] [tile x y size radius]
import AppKit

let args = CommandLine.arguments
let source = args.count > 1 ? args[1] : "Resources/Icon/Saywell-source.jpg"
let tile = args.count > 5 ? CGRect(x: Double(args[2])!, y: Double(args[3])!, width: Double(args[4])!, height: Double(args[4])!)
                          : CGRect(x: 77, y: 77, width: 870, height: 870)
let radius = args.count > 5 ? CGFloat(Double(args[5])!) : 190

guard let src = NSImage(contentsOfFile: source)?.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
    print("can't read \(source)"); exit(1)
}
// Source rect in CoreGraphics coordinates (origin bottom-left).
let flipped = CGRect(x: tile.minX, y: CGFloat(src.height) - tile.maxY, width: tile.width, height: tile.height)
let cropped = src.cropping(to: flipped)!

func render(_ px: Int) -> Data {
    let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.interpolationQuality = .high
    let scale = CGFloat(px) / 1024
    let box = CGRect(x: 100 * scale, y: 100 * scale, width: 824 * scale, height: 824 * scale)
    let r = radius * box.width / tile.width
    ctx.addPath(CGPath(roundedRect: box, cornerWidth: r, cornerHeight: r, transform: nil))
    ctx.clip()
    ctx.draw(cropped, in: box)
    let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
    return rep.representation(using: .png, properties: [:])!
}

let set = URL(fileURLWithPath: "build/Saywell.iconset")
try? FileManager.default.removeItem(at: set)
try! FileManager.default.createDirectory(at: set, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    try! render(base).write(to: set.appendingPathComponent("icon_\(base)x\(base).png"))
    try! render(base * 2).write(to: set.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
try! render(1024).write(to: URL(fileURLWithPath: "Resources/Icon/Saywell-1024.png"))
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", set.path, "-o", "Resources/Icon/Saywell.icns"]
try! p.run(); p.waitUntilExit()
print(p.terminationStatus == 0 ? "wrote Resources/Icon/Saywell.icns" : "iconutil failed")
