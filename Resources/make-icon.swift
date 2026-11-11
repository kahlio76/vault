import AppKit
import CoreGraphics

// Usage: mkicon2 <source.png> <out.png>
// Takes black artwork on white, makes it white on a black macOS-style plate, using the artwork's own curves.
let args = CommandLine.arguments
guard args.count == 3, let src = NSImage(contentsOfFile: args[1]),
      let cg = src.cgImage(forProposedRect: nil, context: nil, hints: nil) else { fatalError("cannot read source") }
let sw = cg.width, sh = cg.height

// read the source as 8-bit gray; darkness becomes opacity
var gray = [UInt8](repeating: 0, count: sw * sh)
let gctx = CGContext(data: &gray, width: sw, height: sh, bitsPerComponent: 8, bytesPerRow: sw,
                     space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
gctx.setFillColor(gray: 1, alpha: 1); gctx.fill(CGRect(x: 0, y: 0, width: sw, height: sh))
gctx.draw(cg, in: CGRect(x: 0, y: 0, width: sw, height: sh))

// bounding box of the shapes (rows are top-down in this buffer)
var minX = sw, minY = sh, maxX = 0, maxY = 0
for y in 0..<sh { for x in 0..<sw where gray[y * sw + x] < 200 {
    minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
} }
let bw = maxX - minX + 1, bh = maxY - minY + 1

// cropped white-on-transparent RGBA, premultiplied
var rgba = [UInt8](repeating: 0, count: bw * bh * 4)
for y in 0..<bh { for x in 0..<bw {
    let a = 255 - gray[(y + minY) * sw + (x + minX)]
    let o = (y * bw + x) * 4
    rgba[o] = a; rgba[o + 1] = a; rgba[o + 2] = a; rgba[o + 3] = a   // premultiplied white
} }
let art = CGContext(data: &rgba, width: bw, height: bh, bitsPerComponent: 8, bytesPerRow: bw * 4,
                    space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!.makeImage()!

// the plate
let size = 1024
let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                    space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
func g(_ v: CGFloat, _ a: CGFloat = 1) -> CGColor { CGColor(srgbRed: v, green: v, blue: v, alpha: a) }
let plate = CGRect(x: 100, y: 100, width: 824, height: 824)
let path = CGPath(roundedRect: plate, cornerWidth: 186, cornerHeight: 186, transform: nil)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 28, color: g(0, 0.45))
ctx.setFillColor(g(0.05)); ctx.addPath(path); ctx.fillPath()
ctx.restoreGState()
ctx.saveGState()
ctx.addPath(path); ctx.clip()
let grad = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [g(0.13), g(0.0)] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(grad, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])
ctx.restoreGState()
ctx.setStrokeColor(g(0.42, 0.7)); ctx.setLineWidth(3)
ctx.addPath(path); ctx.strokePath()

// artwork, centred, about 66% of the plate across its longer side
let target: CGFloat = 620
let scale = target / CGFloat(max(bw, bh))
let dw = CGFloat(bw) * scale, dh = CGFloat(bh) * scale
ctx.interpolationQuality = .high
ctx.draw(art, in: CGRect(x: 512 - dw / 2, y: 512 - dh / 2, width: dw, height: dh))

let out = NSBitmapImageRep(cgImage: ctx.makeImage()!)
try! out.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: args[2]))
print("art \(bw)x\(bh) -> \(Int(dw))x\(Int(dh)) on 1024 plate")
