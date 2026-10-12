// Renders a synthetic 4x6 "grid photo": 24 toast slices on a dark tray, with the
// pore density rising column by column so the porosity matrix shows a gradient.
//
// This is a stand-in for the screenshot pipeline — it exercises slice detection,
// the crust gate and the grid path end to end — and it is deliberately *not* what
// should ship in the App Store listing: use a real photo of a real bake there.
//
//     swift Scripts/make_demo_grid.swift /tmp/demo_grid.png

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

struct SeededGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return state
    }
    mutating func double(_ lower: Double, _ upper: Double) -> Double {
        lower + (upper - lower) * Double(next() % 1_000_000) / 1_000_000
    }
}

let outputPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "/tmp/demo_grid.png"

let width = 2000
let height = 1500
let rows = 4
let columns = 6

guard let context = CGContext(
    data: nil,
    width: width,
    height: height,
    bitsPerComponent: 8,
    bytesPerRow: 0,
    space: CGColorSpaceCreateDeviceRGB(),
    bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
) else {
    FileHandle.standardError.write(Data("could not create the bitmap context\n".utf8))
    exit(1)
}

// Dark tray.
context.setFillColor(CGColor(red: 0.09, green: 0.09, blue: 0.10, alpha: 1))
context.fill(CGRect(x: 0, y: 0, width: width, height: height))

var generator = SeededGenerator(state: 0xB12EAD)

let cellWidth = width / columns
let cellHeight = height / rows

for row in 0..<rows {
    for column in 0..<columns {
        let cellOriginX = column * cellWidth
        let cellOriginY = row * cellHeight
        let slice = CGRect(
            x: Double(cellOriginX) + Double(cellWidth) * 0.14,
            y: Double(cellOriginY) + Double(cellHeight) * 0.12,
            width: Double(cellWidth) * 0.72,
            height: Double(cellHeight) * 0.76
        )
        let corner = slice.width * 0.16

        // Crust ring.
        context.setFillColor(CGColor(red: 0.76, green: 0.53, blue: 0.24, alpha: 1))
        context.addPath(CGPath(roundedRect: slice, cornerWidth: corner, cornerHeight: corner, transform: nil))
        context.fillPath()

        // Crumb.
        let crustThickness = slice.width * 0.055
        let crumb = slice.insetBy(dx: crustThickness, dy: crustThickness)
        let crumbCorner = max(2, corner - crustThickness * 0.7)
        context.setFillColor(CGColor(red: 0.945, green: 0.906, blue: 0.804, alpha: 1))
        context.addPath(CGPath(roundedRect: crumb, cornerWidth: crumbCorner, cornerHeight: crumbCorner, transform: nil))
        context.fillPath()

        // Pores. Column index sets the target porosity (6% .. 13.5%), so the matrix
        // the app prints has a visible gradient to show — the improver comparison.
        let targetPorosity = 0.06 + 0.015 * Double(column)
        let poreTargetArea = crumb.width * crumb.height * targetPorosity
        var drawnArea = 0.0
        var attempts = 0

        while drawnArea < poreTargetArea && attempts < 60_000 {
            attempts += 1
            let radius = generator.double(3.5, 17)
            let centerX = generator.double(crumb.minX + radius, crumb.maxX - radius)
            let centerY = generator.double(crumb.minY + radius, crumb.maxY - radius)
            guard crumb.insetBy(dx: radius, dy: radius).contains(CGPoint(x: centerX, y: centerY)) else {
                continue
            }

            let shade = generator.double(0.74, 0.84)
            context.setFillColor(CGColor(red: shade + 0.06, green: shade, blue: shade - 0.10, alpha: 1))
            context.fillEllipse(in: CGRect(
                x: centerX - radius,
                y: centerY - radius * generator.double(0.75, 1.25),
                width: radius * 2,
                height: radius * generator.double(1.5, 2.5)
            ))
            drawnArea += .pi * radius * radius
        }
    }
}

guard let image = context.makeImage() else {
    FileHandle.standardError.write(Data("could not render the image\n".utf8))
    exit(1)
}

let url = URL(fileURLWithPath: outputPath) as CFURL
guard
    let destination = CGImageDestinationCreateWithURL(url, UTType.png.identifier as CFString, 1, nil)
else {
    FileHandle.standardError.write(Data("could not open \(outputPath) for writing\n".utf8))
    exit(1)
}
CGImageDestinationAddImage(destination, image, nil)
guard CGImageDestinationFinalize(destination) else {
    FileHandle.standardError.write(Data("could not write \(outputPath)\n".utf8))
    exit(1)
}
print("wrote \(outputPath) (\(width)x\(height), \(rows)x\(columns) slices)")
