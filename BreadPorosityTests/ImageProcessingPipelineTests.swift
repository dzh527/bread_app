import XCTest
@testable import BreadPorosity

final class ImageProcessingPipelineTests: XCTestCase {
    func testOtsuThresholdSegmentsDarkCluster() {
        let image = GrayscaleImage(
            width: 4,
            height: 2,
            pixels: [
                18, 22, 225, 230,
                20, 25, 220, 228,
            ]
        )

        let mask = Thresholding.segment(
            image,
            parameters: AnalysisParameters(thresholdMode: .otsu, thresholdBias: 0, minPoreArea: 1, morphologyKernelSize: 1)
        )

        XCTAssertEqual(
            mask.pixels,
            [
                1, 1, 0, 0,
                1, 1, 0, 0,
            ]
        )
    }

    func testOtsuThresholdBiasChangesClassificationBoundary() {
        let image = GrayscaleImage(
            width: 4,
            height: 1,
            pixels: [20, 100, 180, 220]
        )
        let baseline = Thresholding.segment(
            image,
            parameters: AnalysisParameters(thresholdMode: .otsu, thresholdBias: 0, minPoreArea: 1, morphologyKernelSize: 1)
        )
        let biased = Thresholding.segment(
            image,
            parameters: AnalysisParameters(thresholdMode: .otsu, thresholdBias: 80, minPoreArea: 1, morphologyKernelSize: 1)
        )

        XCTAssertGreaterThanOrEqual(biased.porePixelCount, baseline.porePixelCount)
        XCTAssertEqual(baseline[0, 0], 1)
        XCTAssertEqual(biased[0, 0], 1)
        XCTAssertEqual(biased[3, 0], 0)
    }

    func testMorphologyCleanRemovesSinglePixelNoise() {
        let noisyMask = BinaryMask(
            width: 5,
            height: 5,
            pixels: [
                0, 0, 0, 0, 0,
                0, 0, 0, 0, 0,
                0, 0, 1, 0, 0,
                0, 0, 0, 0, 0,
                0, 0, 0, 0, 0,
            ]
        )

        let cleaned = BinaryMorphology.clean(noisyMask, kernelSize: 3)

        XCTAssertEqual(cleaned.porePixelCount, 0)
    }

    func testMorphologyCleanTreatsEvenKernelSizeAsNextOddKernel() {
        let mask = BinaryMask(
            width: 5,
            height: 5,
            pixels: [
                0, 0, 0, 0, 0,
                0, 1, 1, 1, 0,
                0, 1, 1, 1, 0,
                0, 1, 1, 1, 0,
                0, 0, 0, 0, 0,
            ]
        )

        let evenKernel = BinaryMorphology.clean(mask, kernelSize: 2)
        let oddKernel = BinaryMorphology.clean(mask, kernelSize: 3)

        XCTAssertEqual(evenKernel.pixels, oddKernel.pixels)
    }

    func testConnectedComponentsFiltersSmallRegionsAndComputesMetrics() {
        let mask = BinaryMask(
            width: 6,
            height: 6,
            pixels: [
                1, 1, 0, 0, 0, 0,
                1, 1, 0, 0, 0, 0,
                0, 0, 0, 1, 1, 1,
                0, 0, 0, 1, 1, 1,
                0, 0, 0, 1, 1, 1,
                0, 0, 0, 0, 0, 1,
            ]
        )

        let summary = ConnectedComponents.filter(mask: mask, minimumArea: 5)

        XCTAssertEqual(summary.poreCount, 1)
        XCTAssertEqual(summary.averageArea, 10, accuracy: 0.001)
        XCTAssertEqual(summary.filteredMask.porePixelCount, 10)
        XCTAssertEqual(summary.filteredMask[0, 0], 0)
        XCTAssertEqual(summary.filteredMask[3, 2], 1)
        XCTAssertEqual(summary.filteredMask[5, 5], 1)
    }

    func testConnectedComponentsTreatsMinimumAreaBelowOneAsOne() {
        let mask = BinaryMask(
            width: 3,
            height: 3,
            pixels: [
                1, 0, 0,
                0, 1, 0,
                0, 0, 0,
            ]
        )

        let summary = ConnectedComponents.filter(mask: mask, minimumArea: 0)

        XCTAssertEqual(summary.poreCount, 1)
        XCTAssertEqual(summary.averageArea, 2, accuracy: 0.001)
        XCTAssertEqual(summary.filteredMask.porePixelCount, 2)
    }
}
