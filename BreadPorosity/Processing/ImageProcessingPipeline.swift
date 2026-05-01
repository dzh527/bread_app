import Foundation

struct ConnectedComponentSummary {
    let filteredMask: BinaryMask
    let poreCount: Int
    let averageArea: Double
    let poreAreaCV: Double
}

enum BackgroundRemover {
    static func removeBackground(_ image: GrayscaleImage) -> GrayscaleImage {
        let backgroundMask = detectBackground(image)
        let meanBreadIntensity = computeForegroundMean(image, backgroundMask: backgroundMask)
        let fillValue = UInt8(clamping: max(Int(meanBreadIntensity), 200))

        var result = image
        for i in 0..<image.pixelCount {
            if backgroundMask[i] == 1 {
                result.pixels[i] = fillValue
            }
        }
        return result
    }

    private static func detectBackground(_ image: GrayscaleImage) -> [UInt8] {
        let threshold = otsuThreshold(image)
        let isBreadDarkerThanBackground = estimateBreadIsDarker(image, threshold: threshold)

        var foreground = [UInt8](repeating: 0, count: image.pixelCount)
        for i in 0..<image.pixelCount {
            if isBreadDarkerThanBackground {
                foreground[i] = image.pixels[i] <= threshold ? 1 : 0
            } else {
                foreground[i] = image.pixels[i] > threshold ? 1 : 0
            }
        }

        let closingRadius = max(3, min(image.width, image.height) / 40)
        let closed = morphologicalClose(foreground, width: image.width, height: image.height, radius: closingRadius)

        var background = floodFillFromEdges(closed, width: image.width, height: image.height)
        let erosionRadius = max(2, min(image.width, image.height) / 100)
        background = dilateBackground(background, width: image.width, height: image.height, radius: erosionRadius)

        return background
    }

    private static func otsuThreshold(_ image: GrayscaleImage) -> Int {
        let histogram = image.histogram()
        let totalPixels = Double(image.pixelCount)
        var totalIntensity = 0.0
        for (i, count) in histogram.enumerated() {
            totalIntensity += Double(i) * Double(count)
        }

        var threshold = 0
        var bgWeight = 0.0
        var bgIntensity = 0.0
        var maxVariance = -Double.infinity

        for i in 0..<256 {
            bgWeight += Double(histogram[i])
            guard bgWeight > 0 else { continue }
            let fgWeight = totalPixels - bgWeight
            guard fgWeight > 0 else { break }

            bgIntensity += Double(i * histogram[i])
            let bgMean = bgIntensity / bgWeight
            let fgMean = (totalIntensity - bgIntensity) / fgWeight
            let delta = bgMean - fgMean
            let variance = bgWeight * fgWeight * delta * delta

            if variance > maxVariance {
                maxVariance = variance
                threshold = i
            }
        }
        return threshold
    }

    private static func estimateBreadIsDarker(_ image: GrayscaleImage, threshold: Int) -> Bool {
        let w = image.width
        let h = image.height
        let edgeMargin = max(2, min(w, h) / 20)
        var edgeSum = 0
        var edgeCount = 0

        for y in 0..<h {
            for x in 0..<w {
                if x < edgeMargin || x >= w - edgeMargin || y < edgeMargin || y >= h - edgeMargin {
                    edgeSum += Int(image[x, y])
                    edgeCount += 1
                }
            }
        }

        guard edgeCount > 0 else { return true }
        let edgeMean = Double(edgeSum) / Double(edgeCount)
        return edgeMean > Double(threshold)
    }

    private static func morphologicalClose(_ mask: [UInt8], width: Int, height: Int, radius: Int) -> [UInt8] {
        let dilated = dilateRaw(mask, width: width, height: height, radius: radius)
        return erodeRaw(dilated, width: width, height: height, radius: radius)
    }

    private static func dilateRaw(_ mask: [UInt8], width: Int, height: Int, radius: Int) -> [UInt8] {
        var output = [UInt8](repeating: 0, count: mask.count)
        for y in 0..<height {
            for x in 0..<width {
                var found = false
                let yStart = max(0, y - radius)
                let yEnd = min(height - 1, y + radius)
                let xStart = max(0, x - radius)
                let xEnd = min(width - 1, x + radius)
                for ky in yStart...yEnd {
                    for kx in xStart...xEnd {
                        if mask[ky * width + kx] == 1 {
                            found = true
                            break
                        }
                    }
                    if found { break }
                }
                output[y * width + x] = found ? 1 : 0
            }
        }
        return output
    }

    private static func erodeRaw(_ mask: [UInt8], width: Int, height: Int, radius: Int) -> [UInt8] {
        var output = [UInt8](repeating: 0, count: mask.count)
        for y in 0..<height {
            for x in 0..<width {
                var allSet = true
                let yStart = max(0, y - radius)
                let yEnd = min(height - 1, y + radius)
                let xStart = max(0, x - radius)
                let xEnd = min(width - 1, x + radius)
                for ky in yStart...yEnd {
                    for kx in xStart...xEnd {
                        if mask[ky * width + kx] == 0 {
                            allSet = false
                            break
                        }
                    }
                    if !allSet { break }
                }
                output[y * width + x] = allSet ? 1 : 0
            }
        }
        return output
    }

    private static func floodFillFromEdges(_ foreground: [UInt8], width: Int, height: Int) -> [UInt8] {
        var background = [UInt8](repeating: 0, count: foreground.count)
        var queue = [Int]()
        queue.reserveCapacity(width * 2 + height * 2)

        func enqueue(_ x: Int, _ y: Int) {
            let idx = y * width + x
            guard foreground[idx] == 0, background[idx] == 0 else { return }
            background[idx] = 1
            queue.append(idx)
        }

        for x in 0..<width {
            enqueue(x, 0)
            enqueue(x, height - 1)
        }
        for y in 0..<height {
            enqueue(0, y)
            enqueue(width - 1, y)
        }

        var head = 0
        let offsets = [(-1, 0), (1, 0), (0, -1), (0, 1)]
        while head < queue.count {
            let idx = queue[head]
            head += 1
            let x = idx % width
            let y = idx / width

            for (dx, dy) in offsets {
                let nx = x + dx
                let ny = y + dy
                guard nx >= 0, nx < width, ny >= 0, ny < height else { continue }
                enqueue(nx, ny)
            }
        }

        return background
    }

    private static func dilateBackground(_ background: [UInt8], width: Int, height: Int, radius: Int) -> [UInt8] {
        dilateRaw(background, width: width, height: height, radius: radius)
    }

    private static func computeForegroundMean(_ image: GrayscaleImage, backgroundMask: [UInt8]) -> Double {
        var sum = 0
        var count = 0
        for i in 0..<image.pixelCount {
            if backgroundMask[i] == 0 {
                sum += Int(image.pixels[i])
                count += 1
            }
        }
        return count > 0 ? Double(sum) / Double(count) : 200
    }
}

enum ImagePreprocessor {
    static func normalize(_ image: GrayscaleImage) -> GrayscaleImage {
        let backgroundRadius = max(10, min(image.width, image.height) / 72)
        let integral = image.integralImage()
        var correctedPixels = [UInt8](repeating: 0, count: image.pixelCount)

        for y in 0..<image.height {
            for x in 0..<image.width {
                let regionSum = integral.sum(
                    x0: x - backgroundRadius,
                    y0: y - backgroundRadius,
                    x1: x + backgroundRadius + 1,
                    y1: y + backgroundRadius + 1
                )
                let clippedLeft = max(0, x - backgroundRadius)
                let clippedTop = max(0, y - backgroundRadius)
                let clippedRight = min(image.width, x + backgroundRadius + 1)
                let clippedBottom = min(image.height, y + backgroundRadius + 1)
                let area = max(1, (clippedRight - clippedLeft) * (clippedBottom - clippedTop))
                let localMean = regionSum / area
                let correctedValue = Int(image[x, y]) - localMean + 128
                correctedPixels[(y * image.width) + x] = UInt8(clamping: correctedValue)
            }
        }

        return stretchContrast(GrayscaleImage(width: image.width, height: image.height, pixels: correctedPixels))
    }

    private static func stretchContrast(_ image: GrayscaleImage) -> GrayscaleImage {
        let histogram = image.histogram()
        let totalPixels = image.pixelCount
        guard totalPixels > 0 else {
            return image
        }

        let lowCutoff = max(1, Int(Double(totalPixels) * 0.01))
        let highTailCount = max(1, Int(Double(totalPixels) * 0.01))

        var lowValue = 0
        var lowAccumulator = 0
        for intensity in 0..<histogram.count {
            lowAccumulator += histogram[intensity]
            if lowAccumulator >= lowCutoff {
                lowValue = intensity
                break
            }
        }

        var highValue = 255
        var highAccumulator = 0
        for intensity in (0..<histogram.count).reversed() {
            highAccumulator += histogram[intensity]
            if highAccumulator >= highTailCount {
                highValue = intensity
                break
            }
        }

        guard highValue > lowValue else {
            return image
        }

        let scale = 255.0 / Double(highValue - lowValue)
        let stretchedPixels = image.pixels.map { pixel in
            let clamped = min(max(Int(pixel), lowValue), highValue)
            return UInt8(clamping: Int((Double(clamped - lowValue) * scale).rounded()))
        }

        return GrayscaleImage(width: image.width, height: image.height, pixels: stretchedPixels)
    }
}

enum Thresholding {
    static func segment(_ image: GrayscaleImage, parameters: AnalysisParameters) -> BinaryMask {
        switch parameters.thresholdMode {
        case .adaptive:
            return adaptiveThreshold(image, bias: parameters.thresholdBias)
        case .otsu:
            return otsuThreshold(image, bias: parameters.thresholdBias)
        }
    }

    private static func adaptiveThreshold(_ image: GrayscaleImage, bias: Int) -> BinaryMask {
        let localRadius = max(6, min(image.width, image.height) / 96)
        let integral = image.integralImage()
        let standardDeviation = image.meanAndStandardDeviation().standardDeviation
        let baseOffset = max(6, min(18, Int((standardDeviation * 0.18).rounded())))
        let adjustedOffset = max(0, min(48, baseOffset - bias))
        var maskPixels = [UInt8](repeating: 0, count: image.pixelCount)

        for y in 0..<image.height {
            for x in 0..<image.width {
                let regionSum = integral.sum(
                    x0: x - localRadius,
                    y0: y - localRadius,
                    x1: x + localRadius + 1,
                    y1: y + localRadius + 1
                )
                let clippedLeft = max(0, x - localRadius)
                let clippedTop = max(0, y - localRadius)
                let clippedRight = min(image.width, x + localRadius + 1)
                let clippedBottom = min(image.height, y + localRadius + 1)
                let area = max(1, (clippedRight - clippedLeft) * (clippedBottom - clippedTop))
                let localMean = regionSum / area
                maskPixels[(y * image.width) + x] = Int(image[x, y]) < (localMean - adjustedOffset) ? 1 : 0
            }
        }

        return BinaryMask(width: image.width, height: image.height, pixels: maskPixels)
    }

    private static func otsuThreshold(_ image: GrayscaleImage, bias: Int) -> BinaryMask {
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

        let adjustedThreshold = max(0, min(255, threshold + bias))
        let maskPixels = image.pixels.map { pixel in
            Int(pixel) <= adjustedThreshold ? UInt8(1) : UInt8(0)
        }

        return BinaryMask(width: image.width, height: image.height, pixels: maskPixels)
    }
}

enum BinaryMorphology {
    static func clean(_ mask: BinaryMask, kernelSize: Int) -> BinaryMask {
        let sanitizedKernel = sanitizeKernelSize(kernelSize)
        guard sanitizedKernel > 1 else {
            return mask
        }

        let opened = dilate(erode(mask, kernelSize: sanitizedKernel), kernelSize: sanitizedKernel)
        return erode(dilate(opened, kernelSize: sanitizedKernel), kernelSize: sanitizedKernel)
    }

    private static func sanitizeKernelSize(_ kernelSize: Int) -> Int {
        let minimumKernel = max(1, kernelSize)
        return minimumKernel.isMultiple(of: 2) ? (minimumKernel + 1) : minimumKernel
    }

    private static func erode(_ mask: BinaryMask, kernelSize: Int) -> BinaryMask {
        let radius = kernelSize / 2
        var outputPixels = [UInt8](repeating: 0, count: mask.pixelCount)

        for y in 0..<mask.height {
            for x in 0..<mask.width {
                var keepPixel = true

                for kernelY in -radius...radius {
                    for kernelX in -radius...radius {
                        let sampleX = x + kernelX
                        let sampleY = y + kernelY

                        if sampleX < 0 || sampleX >= mask.width || sampleY < 0 || sampleY >= mask.height {
                            keepPixel = false
                            break
                        }

                        if mask[sampleX, sampleY] == 0 {
                            keepPixel = false
                            break
                        }
                    }

                    if !keepPixel {
                        break
                    }
                }

                outputPixels[(y * mask.width) + x] = keepPixel ? 1 : 0
            }
        }

        return BinaryMask(width: mask.width, height: mask.height, pixels: outputPixels)
    }

    private static func dilate(_ mask: BinaryMask, kernelSize: Int) -> BinaryMask {
        let radius = kernelSize / 2
        var outputPixels = [UInt8](repeating: 0, count: mask.pixelCount)

        for y in 0..<mask.height {
            for x in 0..<mask.width {
                var keepPixel = false

                for kernelY in -radius...radius {
                    for kernelX in -radius...radius {
                        let sampleX = x + kernelX
                        let sampleY = y + kernelY

                        guard sampleX >= 0, sampleX < mask.width, sampleY >= 0, sampleY < mask.height else {
                            continue
                        }

                        if mask[sampleX, sampleY] == 1 {
                            keepPixel = true
                            break
                        }
                    }

                    if keepPixel {
                        break
                    }
                }

                outputPixels[(y * mask.width) + x] = keepPixel ? 1 : 0
            }
        }

        return BinaryMask(width: mask.width, height: mask.height, pixels: outputPixels)
    }
}

enum PoreRegionRefiner {
    static func growAndFill(seedMask: BinaryMask, sourceImage: GrayscaleImage, kernelSize: Int) -> BinaryMask {
        guard seedMask.width == sourceImage.width, seedMask.height == sourceImage.height else {
            return seedMask
        }

        let width = seedMask.width
        let height = seedMask.height
        let pixelCount = seedMask.pixelCount
        let padding = max(2, sanitizeKernelSize(kernelSize) + 1)
        var visited = [UInt8](repeating: 0, count: pixelCount)
        var outputPixels = seedMask.pixels
        var queue = [Int]()
        var componentPixels = [Int]()
        queue.reserveCapacity(2048)
        componentPixels.reserveCapacity(2048)

        for startIndex in 0..<pixelCount {
            guard seedMask.pixels[startIndex] == 1, visited[startIndex] == 0 else {
                continue
            }

            let component = collectComponent(
                from: startIndex,
                mask: seedMask,
                visited: &visited,
                queue: &queue,
                componentPixels: &componentPixels
            )
            let bounds = paddedBounds(for: component, width: width, height: height, padding: padding)
            let threshold = growthThreshold(
                component: component,
                bounds: bounds,
                sourceImage: sourceImage
            )
            let grownPixels = grow(
                from: component,
                within: bounds,
                threshold: threshold,
                sourceImage: sourceImage
            )
            let filledPixels = fillInternalHoles(
                in: grownPixels,
                bounds: bounds,
                width: width,
                height: height
            )

            for pixelIndex in filledPixels {
                outputPixels[pixelIndex] = 1
            }
        }

        return BinaryMask(width: width, height: height, pixels: outputPixels)
    }

    private static func sanitizeKernelSize(_ kernelSize: Int) -> Int {
        let minimumKernel = max(1, kernelSize)
        return minimumKernel.isMultiple(of: 2) ? (minimumKernel + 1) : minimumKernel
    }

    private static func collectComponent(
        from startIndex: Int,
        mask: BinaryMask,
        visited: inout [UInt8],
        queue: inout [Int],
        componentPixels: inout [Int]
    ) -> [Int] {
        let width = mask.width
        let height = mask.height
        let neighborOffsets = [
            (-1, -1), (0, -1), (1, -1),
            (-1, 0),           (1, 0),
            (-1, 1),  (0, 1),  (1, 1)
        ]

        queue.removeAll(keepingCapacity: true)
        componentPixels.removeAll(keepingCapacity: true)
        visited[startIndex] = 1
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

        return componentPixels
    }

    private static func paddedBounds(
        for component: [Int],
        width: Int,
        height: Int,
        padding: Int
    ) -> (left: Int, top: Int, right: Int, bottom: Int) {
        var minX = width - 1
        var minY = height - 1
        var maxX = 0
        var maxY = 0

        for pixelIndex in component {
            let x = pixelIndex % width
            let y = pixelIndex / width
            minX = min(minX, x)
            minY = min(minY, y)
            maxX = max(maxX, x)
            maxY = max(maxY, y)
        }

        return (
            left: max(0, minX - padding),
            top: max(0, minY - padding),
            right: min(width - 1, maxX + padding),
            bottom: min(height - 1, maxY + padding)
        )
    }

    private static func growthThreshold(
        component: [Int],
        bounds: (left: Int, top: Int, right: Int, bottom: Int),
        sourceImage: GrayscaleImage
    ) -> Int {
        let componentMean = Double(component.reduce(0) { $0 + Int(sourceImage.pixels[$1]) }) / Double(component.count)
        var surroundingSum = 0
        var surroundingCount = 0

        for y in bounds.top...bounds.bottom {
            for x in bounds.left...bounds.right {
                if x == bounds.left || x == bounds.right || y == bounds.top || y == bounds.bottom {
                    surroundingSum += Int(sourceImage[x, y])
                    surroundingCount += 1
                }
            }
        }

        guard surroundingCount > 0 else {
            return Int(componentMean.rounded())
        }

        let surroundingMean = Double(surroundingSum) / Double(surroundingCount)
        let contrast = max(0, surroundingMean - componentMean)
        let allowance = max(10, min(42, contrast * 0.65))
        return min(255, Int((componentMean + allowance).rounded()))
    }

    private static func grow(
        from seedPixels: [Int],
        within bounds: (left: Int, top: Int, right: Int, bottom: Int),
        threshold: Int,
        sourceImage: GrayscaleImage
    ) -> Set<Int> {
        let width = sourceImage.width
        let height = sourceImage.height
        let neighborOffsets = [
            (-1, -1), (0, -1), (1, -1),
            (-1, 0),           (1, 0),
            (-1, 1),  (0, 1),  (1, 1)
        ]
        var grown = Set(seedPixels)
        var queue = seedPixels
        var queueHead = 0

        while queueHead < queue.count {
            let currentIndex = queue[queueHead]
            queueHead += 1
            let x = currentIndex % width
            let y = currentIndex / width

            for (offsetX, offsetY) in neighborOffsets {
                let nextX = x + offsetX
                let nextY = y + offsetY

                guard nextX >= bounds.left, nextX <= bounds.right, nextY >= bounds.top, nextY <= bounds.bottom else {
                    continue
                }
                guard nextX >= 0, nextX < width, nextY >= 0, nextY < height else {
                    continue
                }

                let nextIndex = (nextY * width) + nextX
                guard !grown.contains(nextIndex), Int(sourceImage.pixels[nextIndex]) <= threshold else {
                    continue
                }

                grown.insert(nextIndex)
                queue.append(nextIndex)
            }
        }

        return grown
    }

    private static func fillInternalHoles(
        in porePixels: Set<Int>,
        bounds: (left: Int, top: Int, right: Int, bottom: Int),
        width: Int,
        height: Int
    ) -> Set<Int> {
        let neighborOffsets = [(-1, 0), (1, 0), (0, -1), (0, 1)]
        var exterior = Set<Int>()
        var queue = [Int]()

        func enqueueBackground(_ x: Int, _ y: Int) {
            guard x >= bounds.left, x <= bounds.right, y >= bounds.top, y <= bounds.bottom else {
                return
            }
            let index = (y * width) + x
            guard !porePixels.contains(index), !exterior.contains(index) else {
                return
            }
            exterior.insert(index)
            queue.append(index)
        }

        for x in bounds.left...bounds.right {
            enqueueBackground(x, bounds.top)
            enqueueBackground(x, bounds.bottom)
        }
        for y in bounds.top...bounds.bottom {
            enqueueBackground(bounds.left, y)
            enqueueBackground(bounds.right, y)
        }

        var queueHead = 0
        while queueHead < queue.count {
            let currentIndex = queue[queueHead]
            queueHead += 1
            let x = currentIndex % width
            let y = currentIndex / width

            for (offsetX, offsetY) in neighborOffsets {
                enqueueBackground(x + offsetX, y + offsetY)
            }
        }

        var filled = porePixels
        for y in bounds.top...bounds.bottom {
            for x in bounds.left...bounds.right {
                let index = (y * width) + x
                if !porePixels.contains(index), !exterior.contains(index) {
                    filled.insert(index)
                }
            }
        }

        return filled
    }
}

enum ConnectedComponents {
    static func filter(
        mask: BinaryMask,
        minimumArea: Int,
        maximumArea: Int? = nil,
        sourceImage: GrayscaleImage? = nil,
        minimumLocalContrast: Int = 0
    ) -> ConnectedComponentSummary {
        let minArea = max(1, minimumArea)
        let width = mask.width
        let height = mask.height
        let pixelCount = mask.pixelCount
        let maxArea = maximumArea.map { max(minArea, $0) }
        let contrastImage = sourceImage?.width == width && sourceImage?.height == height
            ? sourceImage
            : nil
        let minContrast = max(0, minimumLocalContrast)

        var visited = [UInt8](repeating: 0, count: pixelCount)
        var retainedPixels = [UInt8](repeating: 0, count: pixelCount)
        var queue = [Int]()
        var componentPixels = [Int]()
        var retainedAreas = [Int]()
        queue.reserveCapacity(2048)
        componentPixels.reserveCapacity(2048)

        let neighborOffsets = [
            (-1, -1), (0, -1), (1, -1),
            (-1, 0),           (1, 0),
            (-1, 1),  (0, 1),  (1, 1)
        ]

        for startIndex in 0..<pixelCount {
            guard mask.pixels[startIndex] == 1, visited[startIndex] == 0 else {
                continue
            }

            visited[startIndex] = 1
            queue.removeAll(keepingCapacity: true)
            componentPixels.removeAll(keepingCapacity: true)
            queue.append(startIndex)
            componentPixels.append(startIndex)
            var componentIntensitySum = contrastImage.map { Int($0.pixels[startIndex]) } ?? 0
            var minX = startIndex % width
            var maxX = minX
            var minY = startIndex / width
            var maxY = minY

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
                    if let contrastImage {
                        componentIntensitySum += Int(contrastImage.pixels[nextIndex])
                    }
                    minX = min(minX, nextX)
                    maxX = max(maxX, nextX)
                    minY = min(minY, nextY)
                    maxY = max(maxY, nextY)
                }
            }

            guard componentPixels.count >= minArea else {
                continue
            }
            if let maxArea, componentPixels.count > maxArea {
                continue
            }
            if let contrastImage, minContrast > 0 {
                guard hasLocalContrast(
                    componentIntensitySum: componentIntensitySum,
                    componentArea: componentPixels.count,
                    boundingBox: (minX: minX, minY: minY, maxX: maxX, maxY: maxY),
                    sourceImage: contrastImage,
                    minimumLocalContrast: minContrast
                ) else {
                    continue
                }
            }

            retainedAreas.append(componentPixels.count)
            for pixelIndex in componentPixels {
                retainedPixels[pixelIndex] = 1
            }
        }

        let averageArea: Double
        let poreAreaCV: Double
        if retainedAreas.isEmpty {
            averageArea = 0
            poreAreaCV = 0
        } else {
            let count = Double(retainedAreas.count)
            averageArea = Double(retainedAreas.reduce(0, +)) / count
            if retainedAreas.count < 2 || averageArea < .ulpOfOne {
                poreAreaCV = 0
            } else {
                var variance = 0.0
                for area in retainedAreas {
                    let delta = Double(area) - averageArea
                    variance += delta * delta
                }
                poreAreaCV = sqrt(variance / count) / averageArea
            }
        }

        return ConnectedComponentSummary(
            filteredMask: BinaryMask(width: width, height: height, pixels: retainedPixels),
            poreCount: retainedAreas.count,
            averageArea: averageArea,
            poreAreaCV: poreAreaCV
        )
    }

    private static func hasLocalContrast(
        componentIntensitySum: Int,
        componentArea: Int,
        boundingBox: (minX: Int, minY: Int, maxX: Int, maxY: Int),
        sourceImage: GrayscaleImage,
        minimumLocalContrast: Int
    ) -> Bool {
        let width = sourceImage.width
        let height = sourceImage.height
        let margin = max(2, min(width, height) / 48)
        let left = max(0, boundingBox.minX - margin)
        let top = max(0, boundingBox.minY - margin)
        let right = min(width - 1, boundingBox.maxX + margin)
        let bottom = min(height - 1, boundingBox.maxY + margin)

        var surroundingSum = 0
        var surroundingCount = 0
        for y in top...bottom {
            for x in left...right {
                guard x < boundingBox.minX || x > boundingBox.maxX || y < boundingBox.minY || y > boundingBox.maxY else {
                    continue
                }
                surroundingSum += Int(sourceImage[x, y])
                surroundingCount += 1
            }
        }

        guard surroundingCount > 0 else {
            return true
        }

        let componentMean = Double(componentIntensitySum) / Double(componentArea)
        let surroundingMean = Double(surroundingSum) / Double(surroundingCount)
        return surroundingMean - componentMean >= Double(minimumLocalContrast)
    }
}
