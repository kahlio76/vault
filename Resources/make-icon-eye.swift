import AppKit
import CoreGraphics

let size = 1024
guard let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                          space: CGColorSpace(name: CGColorSpace.sRGB)!,
                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { fatalError("no context") }
func gray(_ v: CGFloat, _ a: CGFloat = 1) -> CGColor { CGColor(srgbRed: v, green: v, blue: v, alpha: a) }

// the macOS icon grid: an 824pt rounded square centred in 1024
let plate = CGRect(x: 100, y: 100, width: 824, height: 824)
let radius: CGFloat = 186
let platePath = CGPath(roundedRect: plate, cornerWidth: radius, cornerHeight: radius, transform: nil)

// soft drop shadow under the plate
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 28, color: gray(0, 0.38))
ctx.setFillColor(gray(0.9))
ctx.addPath(platePath); ctx.fillPath()
ctx.restoreGState()

// plate: light, so it never reads as Terminal's black square
ctx.saveGState()
ctx.addPath(platePath); ctx.clip()
let grad = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [gray(0.975), gray(0.80)] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(grad, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])
ctx.restoreGState()
ctx.setStrokeColor(gray(0.55, 0.55)); ctx.setLineWidth(4)
ctx.addPath(platePath); ctx.strokePath()

// the eye: an almond outline
let ink = gray(0.04)
let left = CGPoint(x: 236, y: 500), right = CGPoint(x: 788, y: 500)
let eye = CGMutablePath()
eye.move(to: left)
eye.addQuadCurve(to: right, control: CGPoint(x: 512, y: 840))
eye.addQuadCurve(to: left, control: CGPoint(x: 512, y: 160))
ctx.setFillColor(gray(1, 0.9))
ctx.addPath(eye); ctx.fillPath()
ctx.setStrokeColor(ink); ctx.setLineWidth(58); ctx.setLineJoin(.round); ctx.setLineCap(.round)
ctx.addPath(eye); ctx.strokePath()

// iris + pupil, looking up and to the right
let c = CGPoint(x: 548, y: 506)
ctx.setFillColor(ink)
ctx.fillEllipse(in: CGRect(x: c.x - 106, y: c.y - 106, width: 212, height: 212))
ctx.setFillColor(gray(1))
ctx.fillEllipse(in: CGRect(x: c.x - 58, y: c.y + 20, width: 46, height: 46))      // highlight

// the sight line: three dots running off toward the corner
ctx.setFillColor(ink)
for (i, r) in [(0, 17.0), (1, 15.0), (2, 13.0)] {
    let p = CGPoint(x: 748 + CGFloat(i) * 48, y: 668 + CGFloat(i) * 48)
    ctx.fillEllipse(in: CGRect(x: p.x - CGFloat(r), y: p.y - CGFloat(r), width: CGFloat(r) * 2, height: CGFloat(r) * 2))
}

guard let img = ctx.makeImage() else { fatalError("no image") }
let rep = NSBitmapImageRep(cgImage: img)
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "icon_1024.png"))
print("wrote icon_1024.png")
