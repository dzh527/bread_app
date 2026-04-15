import UIKit
import XCTest
@testable import BreadPorosity

final class AnalysisImageFactoryTests: XCTestCase {
    func testMakeInputAppliesROICrop() throws {
        let image = makeHalfToneImage(width: 120, height: 80)

        let input = try AnalysisImageFactory.makeInput(
            from: image,
            maxDimension: 120,
            roiRectNormalized: CGRect(x: 0, y: 0, width: 0.5, height: 1)
        )

        XCTAssertEqual(input.grayscale.width, 60)
        XCTAssertEqual(input.grayscale.height, 80)
        XCTAssertLessThan(Int(input.grayscale[5, 5]), 80)
        XCTAssertLessThan(Int(input.grayscale[30, 40]), 80)
    }

    func testMakeInputClampsOutOfBoundsROIToImageBounds() throws {
        let image = makeHalfToneImage(width: 120, height: 80)

        let input = try AnalysisImageFactory.makeInput(
            from: image,
            maxDimension: 120,
            roiRectNormalized: CGRect(x: 0.9, y: -0.2, width: 0.25, height: 1.4)
        )

        XCTAssertEqual(input.grayscale.width, 30)
        XCTAssertEqual(input.grayscale.height, 80)
        XCTAssertGreaterThan(Int(input.grayscale[5, 5]), 180)
        XCTAssertGreaterThan(Int(input.grayscale[20, 40]), 180)
    }

    func testMakeInputRejectsTooSmallROI() {
        let image = makeHalfToneImage(width: 120, height: 80)

        XCTAssertThrowsError(
            try AnalysisImageFactory.makeInput(
                from: image,
                maxDimension: 120,
                roiRectNormalized: CGRect(x: 0, y: 0, width: 0.1, height: 0.1)
            )
        ) { error in
            guard case AnalysisImageFactoryError.roiTooSmall = error else {
                return XCTFail("Expected roiTooSmall, got \(error)")
            }
        }
    }

    func testMakeInputScalesLongestDimensionBeforeCropping() throws {
        let image = makeHalfToneImage(width: 240, height: 120)

        let input = try AnalysisImageFactory.makeInput(from: image, maxDimension: 120)

        XCTAssertEqual(input.grayscale.width, 120)
        XCTAssertEqual(input.grayscale.height, 60)
    }

    private func makeHalfToneImage(width: Int, height: Int) -> UIImage {
        let size = CGSize(width: width, height: height)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1

        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor(white: 0.08, alpha: 1).setFill()
            context.fill(CGRect(x: 0, y: 0, width: size.width / 2, height: size.height))

            UIColor(white: 0.9, alpha: 1).setFill()
            context.fill(CGRect(x: size.width / 2, y: 0, width: size.width / 2, height: size.height))
        }
    }
}
