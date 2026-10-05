// Builds Assets/AppIcon.icns from Assets/logo.png: crops the mark above the wordmark,
// centres it on a white macOS-style rounded square. Run: swift scripts/make_icon.swift
import AppKit

let logoURL = URL(fileURLWithPath: "Assets/logo.png")
guard let src = NSImage(contentsOf: logoURL)?.cgImage(forProposedRect: nil, context: nil, hints: nil) else { fatalError("no logo") }
let w = src.width, h = src.height
let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
ctx.draw(src, in: CGRect(x: 0, y: 0, width: w, height: h))
let px = ctx.data!.bindMemory(to: UInt8.self, capacity: w * h * 4)
// row 0 of the buffer is the top of the image
func ink(_ x: Int, _ y: Int) -> Bool {
    let i = (y * w + x) * 4
    let a = px[i + 3], r = px[i], g = px[i + 1], b = px[i + 2]
    return a > 20 && !(r > 235 && g > 235 && b > 235)
}
var rowHasInk = [Bool](repeating: false, count: h)
for y in 0..<h { for x in stride(from: 0, to: w, by: 2) where ink(x, y) { rowHasInk[y] = true; break } }
// Split mark from wordmark at the largest empty band between inked rows.
let inked = (0..<h).filter { rowHasInk[$0] }
var bestGap = 0, splitAt = h
for (a, b) in zip(inked, inked.dropFirst()) where b - a > bestGap { bestGap = b - a; splitAt = a + 1 }
var minX = w, maxX = 0, minY = h, maxY = 0
for y in 0..<splitAt { for x in 0..<w where ink(x, y) { minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y) } }
print("mark bbox x \(minX)-\(maxX), y \(minY)-\(maxY), wordmark starts at \(splitAt + bestGap)")
let mark = src.cropping(to: CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1))!

let S = 1024, plate: CGFloat = 824, radius: CGFloat = 185
let out = CGContext(data: nil, width: S, height: S, bitsPerComponent: 8, bytesPerRow: S * 4,
                    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
let plateRect = CGRect(x: (CGFloat(S) - plate) / 2, y: (CGFloat(S) - plate) / 2 + 10, width: plate, height: plate)
out.saveGState()
out.setShadow(offset: CGSize(width: 0, height: -10), blur: 24, color: NSColor.black.withAlphaComponent(0.28).cgColor)
out.addPath(CGPath(roundedRect: plateRect, cornerWidth: radius, cornerHeight: radius, transform: nil))
out.setFillColor(NSColor.white.cgColor); out.fillPath()
out.restoreGState()
let inner = plate * 0.70
let scale = min(inner / CGFloat(mark.width), inner / CGFloat(mark.height))
let mw = CGFloat(mark.width) * scale, mh = CGFloat(mark.height) * scale
out.interpolationQuality = .high
out.draw(mark, in: CGRect(x: plateRect.midX - mw / 2, y: plateRect.midY - mh / 2, width: mw, height: mh))
let rep = NSBitmapImageRep(cgImage: out.makeImage()!)
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "Assets/AppIcon-1024.png"))
print("wrote Assets/AppIcon-1024.png")
