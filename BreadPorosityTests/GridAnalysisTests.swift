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
                    let poreX = x + cellSize / 3
                    let poreY = y + cellSize / 3
                    let poreSize = cellSize / 4
                    context.cgContext.fillEllipse(in: CGRect(x: poreX, y: poreY, width: poreSize, height: poreSize))
                }
            }
        }
    }
}
