import Foundation
import UIKit

protocol BreadAnalyzing {
    func analyze(image: UIImage, parameters: AnalysisParameters) async throws -> BreadAnalysisResult
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

    private func analyzeSynchronously(image: UIImage, parameters: AnalysisParameters) throws -> BreadAnalysisResult {
        let analysisInput = try AnalysisImageFactory.makeInput(
            from: image,
            maxDimension: maxProcessingDimension,
            roiRectNormalized: parameters.roiRectNormalized
        )
        let normalized = ImagePreprocessor.normalize(analysisInput.grayscale)
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
            maskImage: maskImage,
            overlayImage: overlayImage
        )
    }
}
