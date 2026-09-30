import CoreGraphics
import UIKit
@testable import BreadPorosity

/// A synthetic crumb with an **exact** known pore area.
///
/// The pore mask is rasterised first, by an exact ellipse test, so
/// `truthMask.porePixelCount` is ground truth — not an estimate. The rendered image is
/// derived *from* that mask afterwards, so grain, lighting and pore depth can be varied
/// freely without moving the answer key.
struct Phantom {
    let image: UIImage
    let truthMask: BinaryMask
    let truePorosity: Double
    let note: String
}

enum PhantomFactory {
    /// Builds a phantom of `width` × `height` whose true pore area is as close to
    /// `targetPorosity` as whole-pixel placement allows.
    ///
    /// Pores are placed at random with radii drawn from `poreRadius`, so the same target
    /// area can be realised as few large holes or many small ones — which is what the
    /// structure-bias control needs.
    static func make(
        width: Int,
        height: Int,
        targetPorosity: Double,
        poreRadius: ClosedRange<Double>,
        seed: UInt64,
        grain: Int = 5,
        crumbLevel: Int = 200,
        poreDepth: Int = 90,
        lightingFalloff: Double = 0.18
    ) -> Phantom {
        var rng = SeededGenerator(seed: seed)
        let targetPorePixels = Int((Double(width * height) * targetPorosity).rounded())
        var mask = [UInt8](repeating: 0, count: width * height)
        var porePixels = 0
        var placedPores = 0

        // Overlapping pores are possible; only newly covered pixels count, so the
        // accumulated area stays exact even when they collide.
        var attempts = 0
        let maximumAttempts = 400_000
        while porePixels < targetPorePixels && attempts < maximumAttempts {
            attempts += 1

            func randomRadius() -> Double {
                let unit = Double(rng.next() % 10_000) / 10_000.0
                return poreRadius.lowerBound + unit * (poreRadius.upperBound - poreRadius.lowerBound)
            }

            let radiusX = randomRadius()
            let radiusY = randomRadius()
            let centerX = Double(rng.next() % UInt64(width))
            let centerY = Double(rng.next() % UInt64(height))

            let minX = max(0, Int(centerX - radiusX))
            let maxX = min(width - 1, Int(centerX + radiusX))
            let minY = max(0, Int(centerY - radiusY))
            let maxY = min(height - 1, Int(centerY + radiusY))
            guard minX <= maxX, minY <= maxY else { continue }

            placedPores += 1
            for y in minY...maxY {
                for x in minX...maxX {
                    let dx = (Double(x) + 0.5 - centerX) / radiusX
                    let dy = (Double(y) + 0.5 - centerY) / radiusY
                    guard dx * dx + dy * dy <= 1 else { continue }

                    let index = (y * width) + x
                    if mask[index] == 0 {
                        mask[index] = 1
                        porePixels += 1
                    }
                }
            }
        }

        let truthMask = BinaryMask(width: width, height: height, pixels: mask)
        let truePorosity = Double(porePixels) / Double(width * height)

        // Render an image *from* the mask. Grain, depth and lighting are appearance
        // only — none of them can change the answer key.
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let centerX = Double(width) / 2
        let centerY = Double(height) / 2
        let maximumDistance = (centerX * centerX + centerY * centerY).squareRoot()

        for y in 0..<height {
            for x in 0..<width {
                let index = (y * width) + x
                var value = Double(crumbLevel)
                if mask[index] == 1 {
                    value -= Double(poreDepth)
                }
                value += Double(Int(rng.next() % UInt64(2 * grain + 1))) - Double(grain)

                let dx = Double(x) - centerX
                let dy = Double(y) - centerY
                let normalizedDistance = (dx * dx + dy * dy).squareRoot() / maximumDistance
                value *= 1 - (lightingFalloff * normalizedDistance * normalizedDistance)

                let level = UInt8(clamping: Int(value.rounded()))
                let base = index * 4
                pixels[base] = level
                pixels[base + 1] = level
                pixels[base + 2] = level
                pixels[base + 3] = 255
            }
        }

        let image = makeImage(width: width, height: height, rgba: pixels)
        let computed = (Double(porePixels) / Double(width * height)) * 100
        let requested = targetPorosity * 100
        let note = String(
            format: "target %.2f%% -> actual %.2f%% in %d pores (radius %.1f-%.1f)",
            requested, computed, placedPores,
            poreRadius.lowerBound, poreRadius.upperBound
        )

        return Phantom(image: image, truthMask: truthMask, truePorosity: truePorosity, note: note)
    }

    static func makeImage(width: Int, height: Int, rgba: [UInt8]) -> UIImage {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        let provider = CGDataProvider(data: Data(rgba) as CFData)!
        let cgImage = CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGBitmapInfo(rawValue: bitmapInfo),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )!
        return UIImage(cgImage: cgImage, scale: 1, orientation: .up)
    }
}

/// SplitMix64, so every run uses byte-identical imagery.
struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed &+ 0x9E3779B97F4A7C15
    }

    mutating func next() -> UInt64 {
        state = state &+ 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}

/// Collects a report and writes it to disk at teardown.
///
/// `xcodebuild` does not surface the test process's stdout and Xcode 26 records no
/// activities for unit tests, so a file on the host is the only reliable channel.
/// Simulator absolute paths resolve against the macOS filesystem.
/// Lines are held statically, not per instance: XCTest constructs a fresh test object
/// for every test method, so an instance property would be empty in all but the one
/// whose `tearDown` happens to run last. XCTest runs methods in a class serially, so no
/// locking is needed.
final class QualityReport {
    private static var lines: [String] = []

    func emit(_ line: String) {
        QualityReport.lines.append(line)
    }

    func flush(to path: String) {
        let text = QualityReport.lines.joined(separator: "\n") + "\n"
        try? text.write(toFile: path, atomically: true, encoding: .utf8)
    }
}
