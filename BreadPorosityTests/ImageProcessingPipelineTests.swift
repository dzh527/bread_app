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
}
