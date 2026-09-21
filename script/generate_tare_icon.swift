import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

guard CommandLine.arguments.count == 2 else {
    fputs("usage: generate_tare_icon.swift output.png\n", stderr)
    exit(2)
}

let outputURL = URL(fileURLWithPath: CommandLine.arguments[1])
let size: CGFloat = 1024
let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue
guard let context = CGContext(
    data: nil,
    width: Int(size),
    height: Int(size),
    bitsPerComponent: 8,
    bytesPerRow: Int(size) * 4,
    space: colorSpace,
    bitmapInfo: bitmapInfo
) else {
    fputs("could not create bitmap context\n", stderr)
    exit(1)
}

context.setFillColor(CGColor(gray: 0.04, alpha: 1))
context.fill(CGRect(x: 0, y: 0, width: size, height: size))

let outerRect = CGRect(x: 54, y: 54, width: size - 108, height: size - 108)
let outerPath = CGPath(roundedRect: outerRect, cornerWidth: 218, cornerHeight: 218, transform: nil)
context.addPath(outerPath)
context.clip()

let gradientColors = [
    CGColor(red: 0.04, green: 0.12, blue: 0.24, alpha: 1),
    CGColor(red: 0.04, green: 0.43, blue: 0.47, alpha: 1),
    CGColor(red: 0.94, green: 0.37, blue: 0.22, alpha: 1)
] as CFArray
let locations: [CGFloat] = [0, 0.58, 1]
let gradient = CGGradient(colorsSpace: colorSpace, colors: gradientColors, locations: locations)!
context.drawLinearGradient(
    gradient,
    start: CGPoint(x: 90, y: size - 90),
    end: CGPoint(x: size - 90, y: 90),
    options: []
)

let panelRect = outerRect.insetBy(dx: 38, dy: 38)
let panelPath = CGPath(roundedRect: panelRect, cornerWidth: 184, cornerHeight: 184, transform: nil)
context.setFillColor(CGColor(red: 0.02, green: 0.07, blue: 0.13, alpha: 0.48))
context.addPath(panelPath)
context.fillPath()

context.setStrokeColor(CGColor(red: 0.92, green: 0.98, blue: 0.96, alpha: 0.88))
context.setLineWidth(42)
context.setLineCap(.round)
context.setLineJoin(.round)

let bars: [(CGFloat, CGFloat)] = [
    (280, 92),
    (360, 180),
    (440, 304),
    (520, 218),
    (600, 120),
    (680, 260),
    (760, 158)
]
for (x, height) in bars {
    context.move(to: CGPoint(x: x, y: 560 - height / 2))
    context.addLine(to: CGPoint(x: x, y: 560 + height / 2))
}
context.strokePath()

context.setStrokeColor(CGColor(red: 1, green: 0.67, blue: 0.32, alpha: 1))
context.setLineWidth(46)
context.move(to: CGPoint(x: 256, y: 770))
context.addLine(to: CGPoint(x: 784, y: 770))
context.move(to: CGPoint(x: 520, y: 770))
context.addLine(to: CGPoint(x: 520, y: 694))
context.strokePath()

context.setStrokeColor(CGColor(red: 0.92, green: 0.98, blue: 0.96, alpha: 0.22))
context.setLineWidth(8)
context.addPath(outerPath)
context.strokePath()

guard let image = context.makeImage(),
      let destination = CGImageDestinationCreateWithURL(
        outputURL as CFURL,
        UTType.png.identifier as CFString,
        1,
        nil
      ) else {
    fputs("could not create PNG destination\n", stderr)
    exit(1)
}

CGImageDestinationAddImage(destination, image, nil)
guard CGImageDestinationFinalize(destination) else {
    fputs("could not finalize PNG\n", stderr)
    exit(1)
}
