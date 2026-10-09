import CoreGraphics
import UIKit

enum GridSlicerError: LocalizedError {
    case imageTooSmall
    case cellTooSmall

    var errorDescription: String? {
        switch self {
        case .imageTooSmall:
            return "The image is too small to divide into the specified grid."
        case .cellTooSmall:
            return "The grid cells are too small for meaningful analysis. Use fewer rows or columns."
        }
    }
}

struct CellRegion {
    let cellIndex: GridCellIndex
    let pixelRect: CGRect
    let sliceROINormalized: CGRect?
}

/// A slice found by `detectSlice`: where it is, and which pixels of it are actually
/// bread.
///
/// Both matter to the crust gate. The ROI box overstates the slice by a few pixels of
/// search padding on every side, and for a shape that is not a rectangle it also
/// encloses whatever sits at the box corners — bench or tray. Sampling the band over the
/// box lets those non-bread pixels drive the trim decision in both directions, so the
/// component's own pixels travel with the ROI.
struct DetectedSlice {
    let roi: CGRect
    let mask: BinaryMask
}

/// What the crust gate sees in the band a trim would remove: the band, the interior it
/// surrounds, and the illumination the interior predicts for it.
struct CrustBandMeasurement {
    let interiorMean: Double
    let bandMean: Double
    let bandPredictedFromInterior: Double
    let interiorPixelCount: Int
    let bandPixelCount: Int
    /// The gate's verdict: the band is far enough below its predicted illumination to be
    /// taken for a crust ring.
    let holdsCrustRing: Bool

    /// How far the band falls below the illumination its own interior predicts — the
    /// part of the raw difference that is a *step* rather than a smooth field.
    var crustStep: Double {
        bandPredictedFromInterior - bandMean
    }
}

enum GridSlicer {
    private static let minimumCellDimension = 48
    private static let minimumTrimmedROIDimension = 24
    /// How far the band a trim would remove has to sit below the illumination its
    /// interior predicts before it is taken for a crust ring.
    ///
    /// Coverage cannot decide this. A macro close-up and a whole slice filling its cell
    /// both report a detected slice ROI of ~100%, and they need opposite treatment.
    /// Ring contrast separates them: measured across a real 4x6 grid, the 24 cells that
    /// have crust came in at +42..+72 grey levels, while two close-ups with no crust came
    /// in at -0.5 and +1.3. Those were raw band-versus-interior differences, so they also
    /// carried the smooth part of the frame — camera falloff, and bench wherever the band
    /// crossed the detector's padding ring. The margin is kept at the calibrated 12 grey
    /// levels; what changed is that the smooth part is measured and removed first, and
    /// the band is sampled over the slice's own pixels (`measureCrustBand`), so falloff
    /// cannot spend the margin and the same crumb reads the same at any exposure.
    private static let crustRingContrastThreshold = 12.0

    /// Below this many interior pixels the quadratic fit is not trusted: the flat model
    /// (the interior's own mean) is used instead, or the mask that shrank the sample is
    /// dropped.
    private static let minimumFitPixels = 32

    static func sliceCells(
        imageWidth: Int,
        imageHeight: Int,
        gridSpec: GridSpec,
        boundsNormalized: CGRect? = nil
    ) throws -> [[CellRegion]] {
        guard imageWidth >= minimumCellDimension, imageHeight >= minimumCellDimension else {
            throw GridSlicerError.imageTooSmall
        }

        let imageBounds = CGRect(x: 0, y: 0, width: imageWidth, height: imageHeight)
        let sliceBounds = (boundsNormalized ?? CGRect(x: 0, y: 0, width: 1, height: 1))
            .clampedToUnit(minSize: 0.05)
            .denormalized(in: imageBounds)
            .integral
            .intersection(imageBounds)

        let boundsWidth = Int(sliceBounds.width)
        let boundsHeight = Int(sliceBounds.height)
        guard boundsWidth >= minimumCellDimension, boundsHeight >= minimumCellDimension else {
            throw GridSlicerError.imageTooSmall
        }

        let cellWidth = boundsWidth / gridSpec.columns
        let cellHeight = boundsHeight / gridSpec.rows

        guard cellWidth >= minimumCellDimension, cellHeight >= minimumCellDimension else {
            throw GridSlicerError.cellTooSmall
        }

        let originX = Int(sliceBounds.origin.x)
        let originY = Int(sliceBounds.origin.y)
        var grid = [[CellRegion]]()
        for row in 0..<gridSpec.rows {
            var rowRegions = [CellRegion]()
            for column in 0..<gridSpec.columns {
                let x = originX + (column * cellWidth)
                let y = originY + (row * cellHeight)
                let w = (column == gridSpec.columns - 1) ? (originX + boundsWidth - x) : cellWidth
                let h = (row == gridSpec.rows - 1) ? (originY + boundsHeight - y) : cellHeight

                let pixelRect = CGRect(x: x, y: y, width: w, height: h)
                let cellIndex = GridCellIndex(row: row, column: column)

                rowRegions.append(CellRegion(
                    cellIndex: cellIndex,
                    pixelRect: pixelRect,
                    sliceROINormalized: nil
                ))
            }
            grid.append(rowRegions)
        }

        return grid
    }

    static func detectGridContentROI(in grayscale: GrayscaleImage) -> CGRect? {
        let intensityStats = grayscale.meanAndStandardDeviation()
        guard intensityStats.standardDeviation >= 1 else {
            return nil
        }

        let threshold = otsuThresholdValue(grayscale)
        let brightCandidate = detectInteriorContentROI(in: grayscale, threshold: threshold, foregroundIsBright: true)
        let darkCandidate = detectInteriorContentROI(in: grayscale, threshold: threshold, foregroundIsBright: false)

        switch (brightCandidate, darkCandidate) {
        case let (bright?, dark?):
            return bright.foregroundArea >= dark.foregroundArea ? bright.roi : dark.roi
        case let (bright?, nil):
            return bright.roi
        case let (nil, dark?):
            return dark.roi
        case (nil, nil):
            return nil
        }
    }

    /// The slice's brightest connected component: the padded, normalized ROI the crust
    /// trim works from, plus the component's own pixels.
    ///
    /// Both are returned because the ROI box alone overstates the slice — it carries
    /// `max(2, min(w, h)/50)` pixels of search padding on every side, and for a shape
    /// that is not a rectangle it encloses bench or tray at the corners. The mask is what
    /// lets the crust gate measure the band over bread only.
    static func detectSlice(in grayscale: GrayscaleImage) -> DetectedSlice? {
        let intensityStats = grayscale.meanAndStandardDeviation()
        guard intensityStats.standardDeviation >= 1 else {
            return nil
        }

        let threshold = otsuThresholdValue(grayscale)
        let width = grayscale.width
        let height = grayscale.height

        var maskPixels = [UInt8](repeating: 0, count: grayscale.pixelCount)
        for i in 0..<grayscale.pixelCount {
            maskPixels[i] = Int(grayscale.pixels[i]) > threshold ? UInt8(1) : UInt8(0)
        }

        let mask = BinaryMask(width: width, height: height, pixels: maskPixels)

        let minArea = max(1, grayscale.pixelCount / 20)
        var visited = [UInt8](repeating: 0, count: grayscale.pixelCount)
        var queue = [Int]()
        var componentPixels = [Int]()
        queue.reserveCapacity(1024)
        componentPixels.reserveCapacity(1024)

        let neighborOffsets = [
            (-1, -1), (0, -1), (1, -1),
            (-1, 0),           (1, 0),
            (-1, 1),  (0, 1),  (1, 1)
        ]

        var bestComponent = [Int]()

        for startIndex in 0..<grayscale.pixelCount {
            guard mask.pixels[startIndex] == 1, visited[startIndex] == 0 else {
                continue
            }

            visited[startIndex] = 1
            queue.removeAll(keepingCapacity: true)
            componentPixels.removeAll(keepingCapacity: true)
            queue.append(startIndex)
            componentPixels.append(startIndex)

            var queueHead = 0
            while queueHead < queue.count {
                let currentIndex = queue[queueHead]
                queueHead += 1

                let x = currentIndex % width
                let y = currentIndex / width

                for (offsetX, offsetY) in neighborOffsets {
                    let nextX = x + offsetX
                    let nextY = y + offsetY

                    guard nextX >= 0, nextX < width, nextY >= 0, nextY < height else {
                        continue
                    }

                    let nextIndex = (nextY * width) + nextX
                    guard mask.pixels[nextIndex] == 1, visited[nextIndex] == 0 else {
                        continue
                    }

                    visited[nextIndex] = 1
                    queue.append(nextIndex)
                    componentPixels.append(nextIndex)
                }
            }

            if componentPixels.count > bestComponent.count {
                bestComponent = componentPixels
            }
        }

        guard bestComponent.count >= minArea else {
            return nil
        }

        var minX = width
        var minY = height
        var maxX = 0
        var maxY = 0

        for index in bestComponent {
            let x = index % width
            let y = index / width
            minX = min(minX, x)
            minY = min(minY, y)
            maxX = max(maxX, x)
            maxY = max(maxY, y)
        }

        let padding = max(2, min(width, height) / 50)
        minX = max(0, minX - padding)
        minY = max(0, minY - padding)
        maxX = min(width - 1, maxX + padding)
        maxY = min(height - 1, maxY + padding)

        var componentMask = [UInt8](repeating: 0, count: grayscale.pixelCount)
        for index in bestComponent {
            componentMask[index] = 1
        }

        let roiX = CGFloat(minX) / CGFloat(width)
        let roiY = CGFloat(minY) / CGFloat(height)
        let roiW = CGFloat(maxX - minX + 1) / CGFloat(width)
        let roiH = CGFloat(maxY - minY + 1) / CGFloat(height)

        return DetectedSlice(
            roi: CGRect(x: roiX, y: roiY, width: roiW, height: roiH),
            mask: BinaryMask(width: width, height: height, pixels: componentMask)
        )
    }

    static func detectSliceROI(in grayscale: GrayscaleImage) -> CGRect? {
        detectSlice(in: grayscale)?.roi
    }

    /// The crumb ROI: the detected slice inset to remove its crust ring, or the slice's
    /// own ROI when there is no ring to remove.
    ///
    /// With a `sourceImage` the inset is decided by what the band measures — see
    /// `measureCrustBand` — and `sliceMask`, the mask `detectSlice` returned alongside
    /// the ROI, keeps that measurement on the slice's own pixels. Without an image there
    /// is nothing to judge from, and the historical unconditional trim is kept.
    static func crustTrimmedROI(
        from sliceROINormalized: CGRect?,
        sliceMask: BinaryMask? = nil,
        imageWidth: Int,
        imageHeight: Int,
        trimFraction: CGFloat = 0.11,
        minimumTrimPixels: Int = 6,
        sourceImage: GrayscaleImage? = nil
    ) -> CGRect {
        guard imageWidth > 0, imageHeight > 0 else {
            return CGRect(x: 0, y: 0, width: 1, height: 1)
        }

        let imageBounds = CGRect(x: 0, y: 0, width: CGFloat(imageWidth), height: CGFloat(imageHeight))
        let sourceROI = (sliceROINormalized ?? CGRect(x: 0, y: 0, width: 1, height: 1))
            .clampedToUnit(minSize: 0.05)
            .denormalized(in: imageBounds)
            .integral
            .intersection(imageBounds)

        guard sourceROI.width > 0, sourceROI.height > 0 else {
            return CGRect(x: 0, y: 0, width: 1, height: 1)
        }

        let (insetX, insetY) = trimInsets(
            for: sourceROI,
            trimFraction: trimFraction,
            minimumTrimPixels: minimumTrimPixels
        )

        // Trim only when there is a crust ring to remove. Without an image to judge that
        // from, keep the historical unconditional trim.
        if let sourceImage,
           sourceImage.width == imageWidth,
           sourceImage.height == imageHeight,
           !hasDarkerSurroundingBand(sourceImage, sliceMask: sliceMask, roi: sourceROI, insetX: insetX, insetY: insetY) {
            return normalizedROI(sourceROI, in: imageBounds)
        }

        let trimmedROI = sourceROI.insetBy(dx: CGFloat(insetX), dy: CGFloat(insetY))
        return normalizedROI(trimmedROI, in: imageBounds)
    }

    private static func normalizedROI(_ rect: CGRect, in bounds: CGRect) -> CGRect {
        CGRect(
            x: rect.minX / bounds.width,
            y: rect.minY / bounds.height,
            width: rect.width / bounds.width,
            height: rect.height / bounds.height
        ).clampedToUnit(minSize: 0.05)
    }

    /// The gate's own numbers for a detected slice, for the benchmark report: the same
    /// measure the trim decides on, so a report cannot describe a different decision
    /// than the app makes.
    static func crustBandMeasurement(
        for slice: DetectedSlice,
        in image: GrayscaleImage,
        trimFraction: CGFloat = 0.11,
        minimumTrimPixels: Int = 6
    ) -> CrustBandMeasurement? {
        let imageBounds = CGRect(x: 0, y: 0, width: CGFloat(image.width), height: CGFloat(image.height))
        let sourceROI = slice.roi
            .clampedToUnit(minSize: 0.05)
            .denormalized(in: imageBounds)
            .integral
            .intersection(imageBounds)
        guard sourceROI.width > 0, sourceROI.height > 0 else { return nil }
        let (insetX, insetY) = trimInsets(
            for: sourceROI,
            trimFraction: trimFraction,
            minimumTrimPixels: minimumTrimPixels
        )
        return measureCrustBand(in: image, sliceMask: slice.mask, roi: sourceROI, insetX: insetX, insetY: insetY)
    }

    /// Is the band the trim would remove a *step* darker than the interior it keeps?
    ///
    /// No measurement to compare — no band, no interior — is not evidence of a ring.
    private static func hasDarkerSurroundingBand(
        _ image: GrayscaleImage,
        sliceMask: BinaryMask?,
        roi: CGRect,
        insetX: Int,
        insetY: Int
    ) -> Bool {
        measureCrustBand(in: image, sliceMask: sliceMask, roi: roi, insetX: insetX, insetY: insetY)?
            .holdsCrustRing ?? false
    }

    private static func trimInsets(
        for sourceROI: CGRect,
        trimFraction: CGFloat,
        minimumTrimPixels: Int
    ) -> (x: Int, y: Int) {
        let targetTrimFraction = max(0, trimFraction)
        let requestedInsetX = max(minimumTrimPixels, Int(sourceROI.width * targetTrimFraction))
        let requestedInsetY = max(minimumTrimPixels, Int(sourceROI.height * targetTrimFraction))
        let maximumInsetX = max(0, (Int(sourceROI.width) - minimumTrimmedROIDimension) / 2)
        let maximumInsetY = max(0, (Int(sourceROI.height) - minimumTrimmedROIDimension) / 2)
        return (min(requestedInsetX, maximumInsetX), min(requestedInsetY, maximumInsetY))
    }

    /// Measures the band the trim would remove against the interior it would keep, with
    /// the smooth part of the illumination taken out of the comparison.
    ///
    /// Illumination is not uniform — cameras vignette, benches shade — and a smooth
    /// falloff alone makes any frame's outer band darker than its centre, crust or no
    /// crust: on the phantom's 0.18 falloff the raw difference reaches the old absolute
    /// margin at crumb level 200. The gate is looking for the *step* a crust ring puts
    /// there, so a quadratic surface is fitted to the interior — a smooth field is
    /// locally quadratic, and a vignette is quadratic to begin with — and evaluated over
    /// the band; only the deviation from it counts. What the band then holds is the same
    /// at any exposure, while a crust ring stays below the surface by the ring's own
    /// contrast.
    ///
    /// With a slice mask both regions are sampled over the slice's own pixels, so the
    /// detector's search padding and a bounding box's corners cannot vote. A mask too
    /// thin to fit or to measure is dropped, falling back to whole-ROI sampling — the
    /// behaviour the gate had before masks existed.
    private static func measureCrustBand(
        in image: GrayscaleImage,
        sliceMask: BinaryMask?,
        roi: CGRect,
        insetX: Int,
        insetY: Int
    ) -> CrustBandMeasurement? {
        let mask = sliceMask.flatMap {
            $0.width == image.width && $0.height == image.height ? $0 : nil
        }
        if let mask,
           let measured = sampleCrustBand(in: image, mask: mask, roi: roi, insetX: insetX, insetY: insetY),
           measured.interiorPixelCount >= minimumFitPixels {
            return measured
        }
        return sampleCrustBand(in: image, mask: nil, roi: roi, insetX: insetX, insetY: insetY)
    }

    private static func sampleCrustBand(
        in image: GrayscaleImage,
        mask: BinaryMask?,
        roi: CGRect,
        insetX: Int,
        insetY: Int
    ) -> CrustBandMeasurement? {
        let minX = max(0, Int(roi.minX))
        let maxX = min(image.width, Int(roi.maxX))
        let minY = max(0, Int(roi.minY))
        let maxY = min(image.height, Int(roi.maxY))
        guard minX < maxX, minY < maxY else { return nil }

        let interior = roi.insetBy(dx: CGFloat(insetX), dy: CGFloat(insetY))
        let halfWidth = max(0.5, Double(roi.width) / 2)
        let halfHeight = max(0.5, Double(roi.height) / 2)
        let centerX = Double(roi.midX)
        let centerY = Double(roi.midY)

        // Normal equations of the least-squares quadratic, with coordinates normalized
        // to the ROI so the six basis terms stay comparable at any aspect ratio.
        var normal = [[Double]](repeating: [Double](repeating: 0, count: 6), count: 6)
        var rightHandSide = [Double](repeating: 0, count: 6)
        var terms = [Double](repeating: 0, count: 6)
        var interiorSum = 0.0
        var interiorCount = 0
        var bandSum = 0.0
        var bandIndices = [Int]()

        for y in minY..<maxY {
            for x in minX..<maxX {
                if let mask, mask[x, y] == 0 { continue }
                let value = Double(image[x, y])
                let isInterior = CGFloat(x) >= interior.minX && CGFloat(x) < interior.maxX
                    && CGFloat(y) >= interior.minY && CGFloat(y) < interior.maxY
                guard isInterior else {
                    bandSum += value
                    bandIndices.append((y * image.width) + x)
                    continue
                }
                interiorSum += value
                interiorCount += 1

                let normalizedX = (Double(x) + 0.5 - centerX) / halfWidth
                let normalizedY = (Double(y) + 0.5 - centerY) / halfHeight
                terms[0] = 1
                terms[1] = normalizedX
                terms[2] = normalizedY
                terms[3] = normalizedX * normalizedX
                terms[4] = normalizedX * normalizedY
                terms[5] = normalizedY * normalizedY
                for i in 0..<6 {
                    rightHandSide[i] += terms[i] * value
                    for j in i..<6 {
                        normal[i][j] += terms[i] * terms[j]
                    }
                }
            }
        }

        guard interiorCount > 0, !bandIndices.isEmpty else { return nil }
        for i in 0..<6 {
            for j in 0..<i {
                normal[i][j] = normal[j][i]
            }
        }

        var predictedSum = 0.0
        if interiorCount >= minimumFitPixels, let surface = solve(normal, rightHandSide) {
            for index in bandIndices {
                let x = index % image.width
                let y = index / image.width
                let normalizedX = (Double(x) + 0.5 - centerX) / halfWidth
                let normalizedY = (Double(y) + 0.5 - centerY) / halfHeight
                predictedSum += surface[0]
                    + (surface[1] * normalizedX)
                    + (surface[2] * normalizedY)
                    + (surface[3] * normalizedX * normalizedX)
                    + (surface[4] * normalizedX * normalizedY)
                    + (surface[5] * normalizedY * normalizedY)
            }
        } else {
            // Too few interior pixels, or a degenerate layout to fit: the flat model,
            // which is the comparison the gate made before it knew about illumination.
            predictedSum = (interiorSum / Double(interiorCount)) * Double(bandIndices.count)
        }

        let interiorMean = interiorSum / Double(interiorCount)
        let bandMean = bandSum / Double(bandIndices.count)
        let predictedBandMean = predictedSum / Double(bandIndices.count)
        return CrustBandMeasurement(
            interiorMean: interiorMean,
            bandMean: bandMean,
            bandPredictedFromInterior: predictedBandMean,
            interiorPixelCount: interiorCount,
            bandPixelCount: bandIndices.count,
            holdsCrustRing: predictedBandMean - bandMean >= crustRingContrastThreshold
        )
    }

    /// Gaussian elimination with partial pivoting, for the 6x6 least-squares normal
    /// equations. Returns nil when the system is singular, which is the signal to fall
    /// back to the flat model rather than extrapolate a meaningless surface.
    private static func solve(_ matrix: [[Double]], _ vector: [Double]) -> [Double]? {
        let dimension = vector.count
        var a = matrix
        var b = vector
        for column in 0..<dimension {
            var pivotRow = column
            for row in (column + 1)..<dimension where abs(a[row][column]) > abs(a[pivotRow][column]) {
                pivotRow = row
            }
            guard abs(a[pivotRow][column]) > 1e-9 else { return nil }
            if pivotRow != column {
                a.swapAt(pivotRow, column)
                b.swapAt(pivotRow, column)
            }
            for row in (column + 1)..<dimension {
                let factor = a[row][column] / a[column][column]
                guard factor != 0 else { continue }
                for k in column..<dimension {
                    a[row][k] -= factor * a[column][k]
                }
                b[row] -= factor * b[column]
            }
        }

        var solution = [Double](repeating: 0, count: dimension)
        for row in stride(from: dimension - 1, through: 0, by: -1) {
            var sum = b[row]
            for k in (row + 1)..<dimension {
                sum -= a[row][k] * solution[k]
            }
            solution[row] = sum / a[row][row]
        }
        return solution
    }

    private static func otsuThresholdValue(_ image: GrayscaleImage) -> Int {
        let histogram = image.histogram()
        let totalPixels = Double(image.pixelCount)
        let totalIntensity = histogram.enumerated().reduce(0.0) { partial, entry in
            partial + (Double(entry.offset) * Double(entry.element))
        }

        var threshold = 0
        var backgroundWeight = 0.0
        var backgroundIntensity = 0.0
        var maximumVariance = -Double.infinity

        for intensity in 0..<histogram.count {
            backgroundWeight += Double(histogram[intensity])
            guard backgroundWeight > 0 else {
                continue
            }

            let foregroundWeight = totalPixels - backgroundWeight
            guard foregroundWeight > 0 else {
                break
            }

            backgroundIntensity += Double(intensity * histogram[intensity])
            let backgroundMean = backgroundIntensity / backgroundWeight
            let foregroundMean = (totalIntensity - backgroundIntensity) / foregroundWeight
            let meanDelta = backgroundMean - foregroundMean
            let betweenClassVariance = backgroundWeight * foregroundWeight * meanDelta * meanDelta

            if betweenClassVariance > maximumVariance {
                maximumVariance = betweenClassVariance
                threshold = intensity
            }
        }

        return threshold
    }

    private struct ContentCandidate {
        let roi: CGRect
        let foregroundArea: Int
    }

    private static func detectInteriorContentROI(
        in grayscale: GrayscaleImage,
        threshold: Int,
        foregroundIsBright: Bool
    ) -> ContentCandidate? {
        let width = grayscale.width
        let height = grayscale.height
        let minimumComponentArea = max(64, grayscale.pixelCount / 200)
        var visited = [UInt8](repeating: 0, count: grayscale.pixelCount)
        var queue = [Int]()
        queue.reserveCapacity(1024)

        let neighborOffsets = [
            (-1, -1), (0, -1), (1, -1),
            (-1, 0),           (1, 0),
            (-1, 1),  (0, 1),  (1, 1)
        ]

        var unionMinX = width
        var unionMinY = height
        var unionMaxX = 0
        var unionMaxY = 0
        var foregroundArea = 0

        for startIndex in 0..<grayscale.pixelCount {
            guard visited[startIndex] == 0, isForeground(grayscale.pixels[startIndex], threshold: threshold, foregroundIsBright: foregroundIsBright) else {
                continue
            }

            visited[startIndex] = 1
            queue.removeAll(keepingCapacity: true)
            queue.append(startIndex)

            var queueHead = 0
            var componentArea = 0
            var minX = width
            var minY = height
            var maxX = 0
            var maxY = 0
            var touchesImageEdge = false

            while queueHead < queue.count {
                let currentIndex = queue[queueHead]
                queueHead += 1

                let x = currentIndex % width
                let y = currentIndex / width
                componentArea += 1
                minX = min(minX, x)
                minY = min(minY, y)
                maxX = max(maxX, x)
                maxY = max(maxY, y)
                if x == 0 || y == 0 || x == width - 1 || y == height - 1 {
                    touchesImageEdge = true
                }

                for (offsetX, offsetY) in neighborOffsets {
                    let nextX = x + offsetX
                    let nextY = y + offsetY

                    guard nextX >= 0, nextX < width, nextY >= 0, nextY < height else {
                        continue
                    }

                    let nextIndex = (nextY * width) + nextX
                    guard visited[nextIndex] == 0,
                          isForeground(grayscale.pixels[nextIndex], threshold: threshold, foregroundIsBright: foregroundIsBright)
                    else {
                        continue
                    }

                    visited[nextIndex] = 1
                    queue.append(nextIndex)
                }
            }

            guard componentArea >= minimumComponentArea else {
                continue
            }

            guard !touchesImageEdge else {
                return nil
            }

            foregroundArea += componentArea
            unionMinX = min(unionMinX, minX)
            unionMinY = min(unionMinY, minY)
            unionMaxX = max(unionMaxX, maxX)
            unionMaxY = max(unionMaxY, maxY)
        }

        guard foregroundArea >= max(128, grayscale.pixelCount / 50) else {
            return nil
        }

        let padding = max(2, min(width, height) / 50)
        unionMinX = max(0, unionMinX - padding)
        unionMinY = max(0, unionMinY - padding)
        unionMaxX = min(width - 1, unionMaxX + padding)
        unionMaxY = min(height - 1, unionMaxY + padding)

        let boundsArea = (unionMaxX - unionMinX + 1) * (unionMaxY - unionMinY + 1)
        guard Double(boundsArea) / Double(grayscale.pixelCount) < 0.99 else {
            return nil
        }

        let roi = CGRect(
            x: CGFloat(unionMinX) / CGFloat(width),
            y: CGFloat(unionMinY) / CGFloat(height),
            width: CGFloat(unionMaxX - unionMinX + 1) / CGFloat(width),
            height: CGFloat(unionMaxY - unionMinY + 1) / CGFloat(height)
        )
        return ContentCandidate(roi: roi, foregroundArea: foregroundArea)
    }

    private static func isForeground(_ pixel: UInt8, threshold: Int, foregroundIsBright: Bool) -> Bool {
        foregroundIsBright ? Int(pixel) > threshold : Int(pixel) <= threshold
    }
}
