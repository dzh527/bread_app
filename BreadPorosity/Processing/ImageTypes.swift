import CoreGraphics
import CoreImage
import UIKit

struct AnalysisImageInput {
    let displayImage: UIImage
    let grayscale: GrayscaleImage

    func cropped(to normalizedRect: CGRect) throws -> AnalysisImageInput {
        let clampedROI = normalizedRect.clampedToUnit(minSize: 0.12)
        let rawCropRect = clampedROI
            .denormalized(in: CGRect(x: 0, y: 0, width: grayscale.width, height: grayscale.height))
            .integral
        let imageBounds = CGRect(x: 0, y: 0, width: grayscale.width, height: grayscale.height)
        let cropRect = rawCropRect.intersection(imageBounds)

        let cropWidth = Int(cropRect.width)
        let cropHeight = Int(cropRect.height)
        guard cropWidth >= 24, cropHeight >= 24 else {
            throw AnalysisImageFactoryError.roiTooSmall
        }

        let originX = Int(cropRect.origin.x)
        let originY = Int(cropRect.origin.y)
        var croppedPixels = [UInt8](repeating: 0, count: cropWidth * cropHeight)

        for row in 0..<cropHeight {
            let sourceRowStart = ((originY + row) * grayscale.width) + originX
            let destinationRowStart = row * cropWidth

            for column in 0..<cropWidth {
                croppedPixels[destinationRowStart + column] = grayscale.pixels[sourceRowStart + column]
            }
        }

        let croppedImage = displayImage.cropped(
            to: CGRect(
                x: cropRect.origin.x,
                y: cropRect.origin.y,
                width: CGFloat(cropWidth),
                height: CGFloat(cropHeight)
            )
        )

        return AnalysisImageInput(
            displayImage: croppedImage,
            grayscale: GrayscaleImage(width: cropWidth, height: cropHeight, pixels: croppedPixels)
        )
    }
}

struct GrayscaleImage {
    let width: Int
    let height: Int
    var pixels: [UInt8]

    init(width: Int, height: Int, pixels: [UInt8]) {
        precondition(width > 0 && height > 0, "Image dimensions must be positive.")
        precondition(pixels.count == width * height, "Pixel buffer size does not match image dimensions.")
        self.width = width
        self.height = height
        self.pixels = pixels
    }

    var pixelCount: Int {
        pixels.count
    }

    subscript(x: Int, y: Int) -> UInt8 {
        get {
            pixels[(y * width) + x]
        }
        set {
            pixels[(y * width) + x] = newValue
        }
    }

    func histogram() -> [Int] {
        var histogram = [Int](repeating: 0, count: 256)
        for pixel in pixels {
            histogram[Int(pixel)] += 1
        }
        return histogram
    }

    func meanAndStandardDeviation() -> (mean: Double, standardDeviation: Double) {
        guard !pixels.isEmpty else {
            return (0, 0)
        }

        let count = Double(pixels.count)
        let sum = pixels.reduce(0) { $0 + Int($1) }
        let mean = Double(sum) / count

        var varianceAccumulator = 0.0
        for pixel in pixels {
            let delta = Double(pixel) - mean
            varianceAccumulator += delta * delta
        }

        return (mean, sqrt(varianceAccumulator / count))
    }

    func integralImage() -> IntegralImage {
        IntegralImage(source: self)
    }
}

struct BinaryMask {
    let width: Int
    let height: Int
    var pixels: [UInt8]

    init(width: Int, height: Int, pixels: [UInt8]) {
        precondition(width > 0 && height > 0, "Mask dimensions must be positive.")
        precondition(pixels.count == width * height, "Mask buffer size does not match image dimensions.")
        self.width = width
        self.height = height
        self.pixels = pixels
    }

    var pixelCount: Int {
        pixels.count
    }

    var porePixelCount: Int {
        pixels.reduce(0) { $0 + Int($1) }
    }

    subscript(x: Int, y: Int) -> UInt8 {
        get {
            pixels[(y * width) + x]
        }
        set {
            pixels[(y * width) + x] = newValue
        }
    }
}

struct IntegralImage {
    private let width: Int
    private let height: Int
    private let storageWidth: Int
    private let values: [Int]

    init(source: GrayscaleImage) {
        width = source.width
        height = source.height
        storageWidth = source.width + 1

        var integral = [Int](repeating: 0, count: (source.width + 1) * (source.height + 1))

        for y in 0..<source.height {
            var rowSum = 0
            for x in 0..<source.width {
                rowSum += Int(source[x, y])
                integral[((y + 1) * storageWidth) + (x + 1)] = integral[(y * storageWidth) + (x + 1)] + rowSum
            }
        }

        values = integral
    }

    func sum(x0: Int, y0: Int, x1: Int, y1: Int) -> Int {
        let left = max(0, min(x0, width))
        let top = max(0, min(y0, height))
        let right = max(left, min(x1, width))
        let bottom = max(top, min(y1, height))

        return values[(bottom * storageWidth) + right]
            - values[(top * storageWidth) + right]
            - values[(bottom * storageWidth) + left]
            + values[(top * storageWidth) + left]
    }
}

enum AnalysisImageFactoryError: LocalizedError {
    case unsupportedImage
    case contextCreationFailed
    case imageRenderFailed
    case roiTooSmall

    var errorDescription: String? {
        switch self {
        case .unsupportedImage:
            return "The selected image could not be converted into a processable bitmap."
        case .contextCreationFailed:
            return "Failed to allocate the bitmap context needed for analysis."
        case .imageRenderFailed:
            return "Failed to render the image into the analysis pipeline."
        case .roiTooSmall:
            return "The selected ROI is too small. Increase the crop area and try again."
        }
    }
}

enum AnalysisImageFactory {
    private static let ciContext = CIContext(options: nil)

    static func makeInput(from image: UIImage, maxDimension: Int, roiRectNormalized: CGRect? = nil) throws -> AnalysisImageInput {
        guard let sourceCGImage = cgImage(from: image) else {
            throw AnalysisImageFactoryError.unsupportedImage
        }

        let sourceWidth = sourceCGImage.width
        let sourceHeight = sourceCGImage.height
        let longestSide = max(sourceWidth, sourceHeight)
        let scale = min(1.0, Double(maxDimension) / Double(longestSide))
        let targetWidth = max(1, Int((Double(sourceWidth) * scale).rounded()))
        let targetHeight = max(1, Int((Double(sourceHeight) * scale).rounded()))

        let bytesPerPixel = 4
        let bytesPerRow = targetWidth * bytesPerPixel
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        var rgbaPixels = [UInt8](repeating: 0, count: targetHeight * bytesPerRow)

        let renderedCGImage: CGImage = try rgbaPixels.withUnsafeMutableBytes { rawBuffer in
            guard
                let baseAddress = rawBuffer.baseAddress,
                let context = CGContext(
                    data: baseAddress,
                    width: targetWidth,
                    height: targetHeight,
                    bitsPerComponent: 8,
                    bytesPerRow: bytesPerRow,
                    space: colorSpace,
                    bitmapInfo: bitmapInfo
                )
            else {
                throw AnalysisImageFactoryError.contextCreationFailed
            }

            context.interpolationQuality = .high
            context.draw(sourceCGImage, in: CGRect(x: 0, y: 0, width: targetWidth, height: targetHeight))

            guard let cgImage = context.makeImage() else {
                throw AnalysisImageFactoryError.imageRenderFailed
            }

            return cgImage
        }

        var grayscalePixels = [UInt8](repeating: 0, count: targetWidth * targetHeight)
        for index in 0..<(targetWidth * targetHeight) {
            let base = index * bytesPerPixel
            let red = Int(rgbaPixels[base])
            let green = Int(rgbaPixels[base + 1])
            let blue = Int(rgbaPixels[base + 2])
            grayscalePixels[index] = UInt8(clamping: ((77 * red) + (150 * green) + (29 * blue)) >> 8)
        }

        let fullInput = AnalysisImageInput(
            displayImage: UIImage(cgImage: renderedCGImage, scale: 1, orientation: .up),
            grayscale: GrayscaleImage(width: targetWidth, height: targetHeight, pixels: grayscalePixels)
        )

        guard let roiRectNormalized else {
            return fullInput
        }

        return try fullInput.cropped(to: roiRectNormalized)
    }

    static func cgImage(from image: UIImage) -> CGImage? {
        if let cgImage = image.cgImage {
            return cgImage
        }

        if let ciImage = image.ciImage {
            return ciContext.createCGImage(ciImage, from: ciImage.extent)
        }

        return nil
    }
}

private extension UIImage {
    func cropped(to cropRect: CGRect) -> UIImage {
        let renderer = UIGraphicsImageRenderer(size: cropRect.size)
        return renderer.image { _ in
            draw(at: CGPoint(x: -cropRect.origin.x, y: -cropRect.origin.y))
        }
    }
}
