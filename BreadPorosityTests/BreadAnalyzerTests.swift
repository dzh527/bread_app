import UIKit
import XCTest
@testable import BreadPorosity

final class BreadAnalyzerTests: XCTestCase {
    func testAnalyzeDetectsLargeDarkPoreCluster() async throws {
        let image = makeSyntheticBreadImage(width: 180, height: 180)
        let analyzer = BreadAnalyzer()
        let parameters = AnalysisParameters(
            thresholdMode: .otsu,
            thresholdBias: 0,
            minPoreArea: 80,
            morphologyKernelSize: 3,
            roiMode: .fullImage,
            roiRectNormalized: nil
        )

        let result = try await analyzer.analyze(image: image, parameters: parameters)

        XCTAssertGreaterThan(result.porosity, 0.02)
        XCTAssertLessThan(result.porosity, 0.2)
        XCTAssertEqual(result.poreCount, 1)
        XCTAssertGreaterThan(result.averagePoreArea, 500)
        XCTAssertEqual(result.maskImage.size.width, result.overlayImage.size.width, accuracy: 0.001)
        XCTAssertEqual(result.maskImage.size.height, result.overlayImage.size.height, accuracy: 0.001)
    }

    func testAnalyzeManualROIReducesPorosityWhenPoreIsOutsideCrop() async throws {
        let image = makeSyntheticBreadImage(width: 180, height: 180)
        let analyzer = BreadAnalyzer()

        let fullResult = try await analyzer.analyze(
            image: image,
            parameters: AnalysisParameters(
                thresholdMode: .otsu,
                thresholdBias: 0,
                minPoreArea: 80,
                morphologyKernelSize: 3,
                roiMode: .fullImage,
                roiRectNormalized: nil
            )
        )

        let croppedResult = try await analyzer.analyze(
            image: image,
            parameters: AnalysisParameters(
                thresholdMode: .otsu,
                thresholdBias: 0,
                minPoreArea: 80,
                morphologyKernelSize: 3,
                roiMode: .manualCrop,
                roiRectNormalized: CGRect(x: 0, y: 0, width: 0.25, height: 0.25)
            )
        )

        XCTAssertGreaterThan(fullResult.porosity, 0.02)
        XCTAssertEqual(croppedResult.poreCount, 0)
        XCTAssertEqual(croppedResult.porosity, 0, accuracy: 0.0001)
    }

    private func makeSyntheticBreadImage(width: Int, height: Int) -> UIImage {
        let size = CGSize(width: width, height: height)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1

        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor(white: 0.82, alpha: 1).setFill()
            context.fill(CGRect(origin: .zero, size: size))

            UIColor(white: 0.14, alpha: 1).setFill()
            context.cgContext.fillEllipse(in: CGRect(x: 55, y: 60, width: 70, height: 52))
        }
    }
}
