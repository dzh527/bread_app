import Foundation
import UIKit

extension UIImage {
    func normalizedOrientationForAnalysis() -> UIImage {
        guard imageOrientation != .up else {
            return self
        }
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { _ in
            draw(in: CGRect(origin: .zero, size: size))
        }
    }
}

protocol BreadAnalyzing {
    func analyze(image: UIImage, parameters: AnalysisParameters) async throws -> BreadAnalysisResult
    func analyzeGrid(image: UIImage, gridSpec: GridSpec, gridRegionNormalized: CGRect?) async throws -> GridAnalysisResult
}

extension BreadAnalyzing {
    func analyzeGrid(image: UIImage, gridSpec: GridSpec) async throws -> GridAnalysisResult {
        try await analyzeGrid(image: image, gridSpec: gridSpec, gridRegionNormalized: nil)
    }
}

struct BreadAnalyzer: BreadAnalyzing {
    private let maxProcessingDimension = 1400

    /// Minimum pore area as a fraction of the analysed region, and the absolute noise
    /// floor it is combined with.
    ///
    /// Measured on phantoms of identical true porosity imaged at two resolutions: the
    /// `minArea` at which pores start being discarded scales with *area*, not with
    /// resolution — signal stayed intact through 24 px at 160,000 px of region and
    /// through 96 px at 640,000 px, a 4x ratio for a 4x area. So the quantity is a
    /// fraction. 1/10,000 sits comfortably inside the safe range at both sizes and
    /// leaves the effective value on a real 4x6 cell (27 px) close to what the previous
    /// floor-dominated formula produced (24 px), so this corrects the derivation without
    /// moving the validated numbers.
    private static let minimumPoreAreaRatio = 1.0 / 10_000
    private static let minimumPoreAreaFloor = 24

    func analyze(image: UIImage, parameters: AnalysisParameters) async throws -> BreadAnalysisResult {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let result = try analyzeSynchronously(image: image, parameters: parameters)
                    continuation.resume(returning: result)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func analyzeGrid(image: UIImage, gridSpec: GridSpec, gridRegionNormalized: CGRect? = nil) async throws -> GridAnalysisResult {
        let normalizedImage = image.normalizedOrientationForAnalysis()
        let maxDim = maxProcessingDimension

        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let result = try self.analyzeGridSynchronously(
                        image: normalizedImage,
                        gridSpec: gridSpec,
                        gridRegionNormalized: gridRegionNormalized,
                        maxDimension: maxDim
                    )
                    continuation.resume(returning: result)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func analyzeGridSynchronously(
        image: UIImage,
        gridSpec: GridSpec,
        gridRegionNormalized selectedGridRegionNormalized: CGRect?,
        maxDimension: Int
    ) throws -> GridAnalysisResult {
        let fullInput = try AnalysisImageFactory.makeInput(from: image, maxDimension: maxDimension)
        let gridRegionNormalized = selectedGridRegionNormalized?
            .clampedToUnit(minSize: 0.05)
            ?? GridSlicer.detectGridContentROI(in: fullInput.grayscale)
            ?? CGRect(x: 0, y: 0, width: 1, height: 1)
        let cellRegions = try GridSlicer.sliceCells(
            imageWidth: fullInput.grayscale.width,
            imageHeight: fullInput.grayscale.height,
            gridSpec: gridSpec,
            boundsNormalized: gridRegionNormalized
        )

        var results = [[GridCellResult?]](
            repeating: [GridCellResult?](repeating: nil, count: gridSpec.columns),
            count: gridSpec.rows
        )

        for row in 0..<gridSpec.rows {
            for column in 0..<gridSpec.columns {
                let region = cellRegions[row][column]
                let cellRect = region.pixelRect

                let cellGrayscale = fullInput.grayscale.cropped(to: cellRect)
                guard cellGrayscale.pixelCount >= 48 * 48 else {
                    continue
                }

                let detectedSliceROI = GridSlicer.detectSliceROI(in: cellGrayscale)
                let crumbROI = GridSlicer.crustTrimmedROI(
                    from: detectedSliceROI,
                    imageWidth: cellGrayscale.width,
                    imageHeight: cellGrayscale.height,
                    sourceImage: cellGrayscale
                )
                let cellImage = cropUIImage(fullInput.displayImage, to: cellRect)

                let crumbArea = crumbROIAreaPixels(
                    crumbROI,
                    imageWidth: cellGrayscale.width,
                    imageHeight: cellGrayscale.height
                )
                var parameters = AnalysisParameters()
                parameters.thresholdMode = .adaptive
                parameters.thresholdBias = 0
                // Derived from the region actually analysed, not from this pre-raster
                // cell — those differ by ~5x in area. `analyzeSynchronously` applies the
                // ratio once it knows the real size.
                parameters.minPoreAreaRatio = Self.minimumPoreAreaRatio
                parameters.minPoreArea = Self.minimumPoreAreaFloor
                parameters.maxPoreArea = nil
                parameters.minimumPoreContrast = 0
                parameters.morphologyKernelSize = 5
                parameters.roiMode = .manualCrop
                parameters.roiRectNormalized = crumbROI

                let cellAnalysis = try analyzeSynchronously(image: cellImage, parameters: parameters)
                results[row][column] = GridCellResult(
                    cellIndex: region.cellIndex,
                    cellImage: cellImage,
                    analysisResult: cellAnalysis,
                    crumbROINormalized: crumbROI,
                    crumbROIArea: crumbArea
                )
            }
        }

        let columnSummaries = GridAnalysisResult.computeColumnSummaries(
            gridSpec: gridSpec,
            cellResults: results
        )

        return GridAnalysisResult(
            gridSpec: gridSpec,
            cellResults: results,
            columnSummaries: columnSummaries,
            gridRegionNormalized: gridRegionNormalized
        )
    }

    private func cropUIImage(_ image: UIImage, to rect: CGRect) -> UIImage {
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = AnalysisImageFactory.analysisRasterScale
        let renderer = UIGraphicsImageRenderer(size: rect.size, format: format)
        return renderer.image { _ in
            image.draw(at: CGPoint(x: -rect.origin.x, y: -rect.origin.y))
        }
    }

    private func crumbROIAreaPixels(_ roi: CGRect, imageWidth: Int, imageHeight: Int) -> Int {
        let imageBounds = CGRect(x: 0, y: 0, width: imageWidth, height: imageHeight)
        let pixelRect = roi
            .clampedToUnit(minSize: 0.05)
            .denormalized(in: imageBounds)
            .integral
            .intersection(imageBounds)

        return max(0, Int(pixelRect.width) * Int(pixelRect.height))
    }

    private func analyzeSynchronously(image: UIImage, parameters: AnalysisParameters) throws -> BreadAnalysisResult {
        let analysisInput = try AnalysisImageFactory.makeInput(
            from: image,
            maxDimension: maxProcessingDimension,
            roiRectNormalized: parameters.roiRectNormalized
        )

        // Only here is the analysed region's true pixel count known, so a ratio-based
        // minimum area can only be resolved now. Resolving it earlier — from the
        // caller's image — is what made the value depend on the raster scale.
        var parameters = parameters
        if let ratio = parameters.minPoreAreaRatio {
            let regionPixels = analysisInput.grayscale.pixelCount
            parameters.minPoreArea = max(parameters.minPoreArea, Int(Double(regionPixels) * ratio))
        }

        let backgroundRemoved = BackgroundRemover.removeBackground(analysisInput.grayscale)
        let normalized = ImagePreprocessor.normalize(backgroundRemoved)
        let segmentedMask = Thresholding.segment(normalized, parameters: parameters)
        let cleanedMask = BinaryMorphology.clean(segmentedMask, kernelSize: parameters.morphologyKernelSize)
        let refinedMask = PoreRegionRefiner.growAndFill(
            seedMask: cleanedMask,
            sourceImage: normalized,
            kernelSize: parameters.morphologyKernelSize
        )
        let components = ConnectedComponents.filter(
            mask: refinedMask,
            minimumArea: parameters.minPoreArea,
            maximumArea: parameters.maxPoreArea,
            sourceImage: normalized,
            minimumLocalContrast: parameters.minimumPoreContrast
        )
        let porosity = Double(components.filteredMask.porePixelCount) / Double(components.filteredMask.pixelCount)
        let maskImage = try MaskRenderer.makeMaskImage(from: components.filteredMask)
        let overlayImage = try MaskRenderer.makeOverlayImage(baseImage: analysisInput.displayImage, mask: components.filteredMask)

        return BreadAnalysisResult(
            porosity: porosity,
            poreCount: components.poreCount,
            averagePoreArea: components.averageArea,
            poreAreaCV: components.poreAreaCV,
            maskImage: maskImage,
            overlayImage: overlayImage
        )
    }
}
