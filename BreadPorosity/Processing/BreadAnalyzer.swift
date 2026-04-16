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
    func analyzeGrid(image: UIImage, gridSpec: GridSpec) async throws -> GridAnalysisResult
}

struct BreadAnalyzer: BreadAnalyzing {
    private let maxProcessingDimension = 1400

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

    func analyzeGrid(image: UIImage, gridSpec: GridSpec) async throws -> GridAnalysisResult {
        let normalizedImage = image.normalizedOrientationForAnalysis()
        let maxDim = maxProcessingDimension

        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let result = try self.analyzeGridSynchronously(
                        image: normalizedImage,
                        gridSpec: gridSpec,
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
        maxDimension: Int
    ) throws -> GridAnalysisResult {
        let fullInput = try AnalysisImageFactory.makeInput(from: image, maxDimension: maxDimension)
        let cellRegions = try GridSlicer.sliceCells(
            imageWidth: fullInput.grayscale.width,
            imageHeight: fullInput.grayscale.height,
            gridSpec: gridSpec
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

                let sliceROI = GridSlicer.detectSliceROI(in: cellGrayscale)
                let cellImage = cropUIImage(fullInput.displayImage, to: cellRect)

                let autoMinPoreArea = max(8, cellGrayscale.pixelCount / 8000)
                var parameters = AnalysisParameters()
                parameters.thresholdMode = .adaptive
                parameters.thresholdBias = 0
                parameters.minPoreArea = autoMinPoreArea
                parameters.morphologyKernelSize = 3

                if let roi = sliceROI {
                    parameters.roiMode = .manualCrop
                    parameters.roiRectNormalized = roi
                } else {
                    parameters.roiMode = .fullImage
                }

                let cellAnalysis = try analyzeSynchronously(image: cellImage, parameters: parameters)
                results[row][column] = GridCellResult(
                    cellIndex: region.cellIndex,
                    cellImage: cellImage,
                    analysisResult: cellAnalysis
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
            columnSummaries: columnSummaries
        )
    }

    private func cropUIImage(_ image: UIImage, to rect: CGRect) -> UIImage {
        let renderer = UIGraphicsImageRenderer(size: rect.size)
        return renderer.image { _ in
            image.draw(at: CGPoint(x: -rect.origin.x, y: -rect.origin.y))
        }
    }

    private func analyzeSynchronously(image: UIImage, parameters: AnalysisParameters) throws -> BreadAnalysisResult {
        let analysisInput = try AnalysisImageFactory.makeInput(
            from: image,
            maxDimension: maxProcessingDimension,
            roiRectNormalized: parameters.roiRectNormalized
        )
        let backgroundRemoved = BackgroundRemover.removeBackground(analysisInput.grayscale)
        let normalized = ImagePreprocessor.normalize(backgroundRemoved)
        let segmentedMask = Thresholding.segment(normalized, parameters: parameters)
        let cleanedMask = BinaryMorphology.clean(segmentedMask, kernelSize: parameters.morphologyKernelSize)
        let components = ConnectedComponents.filter(mask: cleanedMask, minimumArea: parameters.minPoreArea)
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
