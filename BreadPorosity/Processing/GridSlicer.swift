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

enum GridSlicer {
    private static let minimumCellDimension = 48

    static func sliceCells(
        imageWidth: Int,
        imageHeight: Int,
        gridSpec: GridSpec
    ) throws -> [[CellRegion]] {
        guard imageWidth >= minimumCellDimension, imageHeight >= minimumCellDimension else {
            throw GridSlicerError.imageTooSmall
        }

        let cellWidth = imageWidth / gridSpec.columns
        let cellHeight = imageHeight / gridSpec.rows

        guard cellWidth >= minimumCellDimension, cellHeight >= minimumCellDimension else {
            throw GridSlicerError.cellTooSmall
        }

        var grid = [[CellRegion]]()
        for row in 0..<gridSpec.rows {
            var rowRegions = [CellRegion]()
            for column in 0..<gridSpec.columns {
                let x = column * cellWidth
                let y = row * cellHeight
                let w = (column == gridSpec.columns - 1) ? (imageWidth - x) : cellWidth
                let h = (row == gridSpec.rows - 1) ? (imageHeight - y) : cellHeight

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

    static func detectSliceROI(in grayscale: GrayscaleImage) -> CGRect? {
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

        let roiX = CGFloat(minX) / CGFloat(width)
        let roiY = CGFloat(minY) / CGFloat(height)
        let roiW = CGFloat(maxX - minX + 1) / CGFloat(width)
        let roiH = CGFloat(maxY - minY + 1) / CGFloat(height)

        return CGRect(x: roiX, y: roiY, width: roiW, height: roiH)
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
}
