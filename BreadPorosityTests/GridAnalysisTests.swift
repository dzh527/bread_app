import UIKit
import XCTest
@testable import BreadPorosity

final class GridAnalysisTests: XCTestCase {
    func testAnalyzeGridProducesCorrectDimensions() async throws {
        let image = makeSyntheticGridImage(rows: 2, columns: 2, cellSize: 120)
        let analyzer = BreadAnalyzer()
        let gridSpec = GridSpec(rows: 2, columns: 2)

        let result = try await analyzer.analyzeGrid(image: image, gridSpec: gridSpec)

        XCTAssertEqual(result.gridSpec, gridSpec)
        XCTAssertEqual(result.cellResults.count, 2)
        XCTAssertEqual(result.cellResults[0].count, 2)
        XCTAssertEqual(result.columnSummaries.count, 2)
    }

    func testAnalyzeGridUsesDetectedBreadRegionInsteadOfFullBackground() async throws {
        let image = makeSyntheticGridImage(rows: 4, columns: 6, cellSize: 70)
        let analyzer = BreadAnalyzer()
        let gridSpec = GridSpec(rows: 4, columns: 6)

        let result = try await analyzer.analyzeGrid(image: image, gridSpec: gridSpec)

        XCTAssertGreaterThan(result.gridRegionNormalized.origin.x, 0)
        XCTAssertGreaterThan(result.gridRegionNormalized.origin.y, 0)
        XCTAssertLessThan(result.gridRegionNormalized.width, 1)
        XCTAssertLessThan(result.gridRegionNormalized.height, 1)
        XCTAssertEqual(result.allResults.count, gridSpec.cellCount)
    }

    func testAnalyzeGridUsesProvidedGridRegion() async throws {
        let image = makeSyntheticGridImage(rows: 2, columns: 2, cellSize: 120)
        let analyzer = BreadAnalyzer()
        let gridSpec = GridSpec(rows: 2, columns: 2)
        let selectedROI = CGRect(x: 0.05, y: 0.05, width: 0.9, height: 0.9)

        let result = try await analyzer.analyzeGrid(
            image: image,
            gridSpec: gridSpec,
            gridRegionNormalized: selectedROI
        )

        XCTAssertEqual(result.gridRegionNormalized, selectedROI)
        XCTAssertEqual(result.allResults.count, gridSpec.cellCount)
    }

    func testAnalyzeGridCellsHaveNonZeroPorosity() async throws {
        let image = makeSyntheticGridImage(rows: 2, columns: 2, cellSize: 120)
        let analyzer = BreadAnalyzer()
        let gridSpec = GridSpec(rows: 2, columns: 2)

        let result = try await analyzer.analyzeGrid(image: image, gridSpec: gridSpec)

        for row in result.cellResults {
            for cell in row {
                if let cell {
                    XCTAssertGreaterThan(cell.analysisResult.porosity, 0)
                    XCTAssertLessThan(cell.analysisResult.porosity, 1)
                }
            }
        }
    }

    func testAnalyzeGridStoresDetectedCrumbROIForEachCell() async throws {
        let image = makeSyntheticGridImage(rows: 2, columns: 2, cellSize: 120)
        let analyzer = BreadAnalyzer()
        let gridSpec = GridSpec(rows: 2, columns: 2)

        let result = try await analyzer.analyzeGrid(image: image, gridSpec: gridSpec)

        for cell in result.allResults {
            XCTAssertGreaterThan(cell.crumbROINormalized.origin.x, 0)
            XCTAssertGreaterThan(cell.crumbROINormalized.origin.y, 0)
            XCTAssertLessThan(cell.crumbROINormalized.width, 1)
            XCTAssertLessThan(cell.crumbROINormalized.height, 1)
            XCTAssertGreaterThan(cell.crumbROIArea, 0)
        }
    }

    func testAnalyzeGridColumnSummariesArePopulated() async throws {
        let image = makeSyntheticGridImage(rows: 2, columns: 2, cellSize: 120)
        let analyzer = BreadAnalyzer()
        let gridSpec = GridSpec(rows: 2, columns: 2)

        let result = try await analyzer.analyzeGrid(image: image, gridSpec: gridSpec)

        for summary in result.columnSummaries {
            XCTAssertGreaterThan(summary.sampleCount, 0)
            XCTAssertGreaterThan(summary.meanPorosity, 0)
        }
    }

    private func makeSyntheticGridImage(rows: Int, columns: Int, cellSize: Int) -> UIImage {
        let gap = 10
        let totalWidth = columns * cellSize + (columns + 1) * gap
        let totalHeight = rows * cellSize + (rows + 1) * gap
        let size = CGSize(width: totalWidth, height: totalHeight)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1

        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor(white: 0.15, alpha: 1).setFill()
            context.fill(CGRect(origin: .zero, size: size))

            for row in 0..<rows {
                for column in 0..<columns {
                    let x = gap + column * (cellSize + gap)
                    let y = gap + row * (cellSize + gap)

                    UIColor(white: 0.82, alpha: 1).setFill()
                    context.cgContext.fill(CGRect(x: x, y: y, width: cellSize, height: cellSize))

                    UIColor(white: 0.14, alpha: 1).setFill()
                    let poreSize = max(12, cellSize / 10)
                    let poreX = x + (cellSize - poreSize) / 2
                    let poreY = y + (cellSize - poreSize) / 2
                    context.cgContext.fillEllipse(in: CGRect(x: poreX, y: poreY, width: poreSize, height: poreSize))
                }
            }
        }
    }
}
