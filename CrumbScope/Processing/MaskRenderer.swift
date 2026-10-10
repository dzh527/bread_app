import CoreGraphics
import UIKit

enum MaskRendererError: LocalizedError {
    case contextCreationFailed
    case imageCreationFailed
    case unsupportedBaseImage

    var errorDescription: String? {
        switch self {
        case .contextCreationFailed:
            return "Failed to create the rendering context for the analysis images."
        case .imageCreationFailed:
            return "Failed to render the pore mask or overlay image."
        case .unsupportedBaseImage:
            return "The processed image could not be converted into an overlay."
        }
    }
}

enum MaskRenderer {
    static func makeMaskImage(from mask: BinaryMask) throws -> UIImage {
        var grayscalePixels = mask.pixels.map { $0 == 1 ? UInt8(255) : UInt8(0) }
        let colorSpace = CGColorSpaceCreateDeviceGray()

        let cgImage: CGImage = try grayscalePixels.withUnsafeMutableBytes { rawBuffer in
            guard
                let baseAddress = rawBuffer.baseAddress,
                let context = CGContext(
                    data: baseAddress,
                    width: mask.width,
                    height: mask.height,
                    bitsPerComponent: 8,
                    bytesPerRow: mask.width,
                    space: colorSpace,
                    bitmapInfo: CGImageAlphaInfo.none.rawValue
                )
            else {
                throw MaskRendererError.contextCreationFailed
            }

            guard let cgImage = context.makeImage() else {
                throw MaskRendererError.imageCreationFailed
            }

            return cgImage
        }

        return UIImage(cgImage: cgImage, scale: 1, orientation: .up)
    }

    static func makeOverlayImage(baseImage: UIImage, mask: BinaryMask) throws -> UIImage {
        guard let baseCGImage = AnalysisImageFactory.cgImage(from: baseImage) else {
            throw MaskRendererError.unsupportedBaseImage
        }

        let overlayCGImage = try makeOverlayMaskImage(from: mask)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bytesPerRow = mask.width * 4
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        var outputPixels = [UInt8](repeating: 0, count: mask.height * bytesPerRow)

        let compositedImage: CGImage = try outputPixels.withUnsafeMutableBytes { rawBuffer in
            guard
                let baseAddress = rawBuffer.baseAddress,
                let context = CGContext(
                    data: baseAddress,
                    width: mask.width,
                    height: mask.height,
                    bitsPerComponent: 8,
                    bytesPerRow: bytesPerRow,
                    space: colorSpace,
                    bitmapInfo: bitmapInfo
                )
            else {
                throw MaskRendererError.contextCreationFailed
            }

            context.interpolationQuality = .high
            context.draw(baseCGImage, in: CGRect(x: 0, y: 0, width: mask.width, height: mask.height))
            context.draw(overlayCGImage, in: CGRect(x: 0, y: 0, width: mask.width, height: mask.height))

            guard let cgImage = context.makeImage() else {
                throw MaskRendererError.imageCreationFailed
            }

            return cgImage
        }

        return UIImage(cgImage: compositedImage, scale: 1, orientation: .up)
    }

    private static func makeOverlayMaskImage(from mask: BinaryMask) throws -> CGImage {
        let bytesPerRow = mask.width * 4
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        var overlayPixels = [UInt8](repeating: 0, count: mask.height * bytesPerRow)

        for index in 0..<mask.pixelCount {
            guard mask.pixels[index] == 1 else {
                continue
            }

            let base = index * 4
            overlayPixels[base] = 231
            overlayPixels[base + 1] = 76
            overlayPixels[base + 2] = 60
            overlayPixels[base + 3] = 110
        }

        return try overlayPixels.withUnsafeMutableBytes { rawBuffer in
            guard
                let baseAddress = rawBuffer.baseAddress,
                let context = CGContext(
                    data: baseAddress,
                    width: mask.width,
                    height: mask.height,
                    bitsPerComponent: 8,
                    bytesPerRow: bytesPerRow,
                    space: colorSpace,
                    bitmapInfo: bitmapInfo
                )
            else {
                throw MaskRendererError.contextCreationFailed
            }

            guard let cgImage = context.makeImage() else {
                throw MaskRendererError.imageCreationFailed
            }

            return cgImage
        }
    }
}
