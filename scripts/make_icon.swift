import AppKit

// Crops the squircle out of the generated icon, masks it with transparency,
// and writes a 1024x1024 PNG on the standard macOS icon grid (824pt content).
let args = CommandLine.arguments
let src = NSImage(contentsOfFile: args[1])!
var rect = CGRect(x: 0, y: 0, width: src.size.width, height: src.size.height)
let cg = src.cgImage(forProposedRect: &rect, context: nil, hints: nil)!

let scale = CGFloat(cg.width) / 1024
let crop = CGRect(x: 142 * scale, y: 142 * scale, width: 744 * scale, height: 746 * scale)
let cropped = cg.cropping(to: crop)!

let size = 1024
let ctx = CGContext(
  data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
let content = CGRect(x: 100, y: 100, width: 824, height: 824)
let path = CGPath(roundedRect: content, cornerWidth: 185, cornerHeight: 185, transform: nil)
ctx.addPath(path)
ctx.clip()
ctx.draw(cropped, in: content.insetBy(dx: -6, dy: -6))
let out = ctx.makeImage()!
let rep = NSBitmapImageRep(cgImage: out)
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: args[2]))
print("wrote \(args[2])")
