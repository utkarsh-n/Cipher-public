// Draws the app icon: four bars of a verse with their rhymes highlighted.
// Usage: swift make_icon.swift ../Cipher/Assets.xcassets/AppIcon.appiconset/icon.png
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let size = 1024
let space = CGColorSpace(name: CGColorSpace.sRGB)!
// A bitmap context at exactly 1024px and no alpha; actool rejects anything else.
let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0, space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!

func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: space, components: [r, g, b, a])!
}

let background = CGGradient(colorsSpace: space, colors: [color(0.10, 0.10, 0.14), color(0.03, 0.03, 0.05)] as CFArray, locations: [0, 1])!
context.drawLinearGradient(background, start: CGPoint(x: 0, y: 1024), end: CGPoint(x: 1024, y: 0), options: [])

let lime = color(0.78, 0.96, 0.20), pink = color(1.00, 0.37, 0.64), cyan = color(0.22, 0.85, 0.96)
let plain = color(1, 1, 1, 0.16)
let height: CGFloat = 96, left: CGFloat = 176, gap: CGFloat = 26

// Each bar: segments of (width, colour). Matching colours are the rhymes.
let bars: [[(CGFloat, CGColor)]] = [
    [(250, plain), (120, cyan), (250, lime)],
    [(150, plain), (120, cyan), (130, plain), (250, lime)],
    [(330, plain), (290, pink)],
    [(210, plain), (290, pink)],
]
for (row, segments) in bars.enumerated() {
    var x = left
    let y = 1024 - 212 - CGFloat(row) * (height + 72) - height
    for (width, fill) in segments {
        let rect = CGRect(x: x, y: y, width: width, height: height)
        context.addPath(CGPath(roundedRect: rect, cornerWidth: height / 2, cornerHeight: height / 2, transform: nil))
        context.setFillColor(fill)
        context.fillPath()
        x += width + gap
    }
}

let url = URL(fileURLWithPath: CommandLine.arguments[1])
let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(destination, context.makeImage()!, nil)
CGImageDestinationFinalize(destination)
