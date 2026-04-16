import XCTest
@testable import BreadPorosity

final class GridSlicerTests: XCTestCase {
    func testSliceCellsDividesImageCorrectly() throws {
        let gridSpec = GridSpec(rows: 2, columns: 3)
        let regions = try GridSlicer.sliceCells(imageWidth: 300, imageHeight: 200, gridSpec: gridSpec)

        XCTAssertEqual(regions.count, 2)
        XCTAssertEqual(regions[0].count, 3)

        let topLeft = regions[0][0]
        XCTAssertEqual(topLeft.cellIndex.row, 0)
        XCTAssertEqual(topLeft.cellIndex.column, 0)
        XCTAssertEqual(topLeft.pixelRect, CGRect(x: 0, y: 0, width: 100, height: 100))

        let bottomRight = regions[1][2]
        XCTAssertEqual(bottomRight.cellIndex.row, 1)
        XCTAssertEqual(bottomRight.cellIndex.column, 2)
        XCTAssertEqual(bottomRight.pixelRect, CGRect(x: 200, y: 100, width: 100, height: 100))
    }

    func testSliceCellsRejectsImageTooSmall() {
        let gridSpec = GridSpec(rows: 2, columns: 2)

        XCTAssertThrowsError(
            try GridSlicer.sliceCells(imageWidth: 20, imageHeight: 20, gridSpec: gridSpec)
        ) { error in
            XCTAssertTrue(error is GridSlicerError)
        }
    }

    func testSliceCellsRejectsCellTooSmall() {
        let gridSpec = GridSpec(rows: 8, columns: 8)

        XCTAssertThrowsError(
            try GridSlicer.sliceCells(imageWidth: 200, imageHeight: 200, gridSpec: gridSpec)
        ) { error in
            XCTAssertTrue(error is GridSlicerError)
        }
    }

    func testSliceCellsHandlesUnevenDivision() throws {
        let gridSpec = GridSpec(rows: 2, columns: 2)
        let regions = try GridSlicer.sliceCells(imageWidth: 101, imageHeight: 101, gridSpec: gridSpec)

        let bottomRight = regions[1][1]
        XCTAssertEqual(Int(bottomRight.pixelRect.maxX), 101)
        XCTAssertEqual(Int(bottomRight.pixelRect.maxY), 101)
    }

    func testDetectSliceROIFindsBrightRegion() {
        var pixels = [UInt8](repeating: 30, count: 100 * 100)

        for y in 20..<80 {
            for x in 20..<80 {
                pixels[(y * 100) + x] = 200
            }
        }

        let image = GrayscaleImage(width: 100, height: 100, pixels: pixels)
        let roi = GridSlicer.detectSliceROI(in: image)

        XCTAssertNotNil(roi)
        if let roi {
            XCTAssertGreaterThan(roi.width, 0.5)
            XCTAssertGreaterThan(roi.height, 0.5)
            XCTAssertLessThan(roi.width, 0.9)
            XCTAssertLessThan(roi.height, 0.9)
        }
    }

    func testDetectSliceROIReturnsNilForUniformImage() {
        let pixels = [UInt8](repeating: 128, count: 100 * 100)
        let image = GrayscaleImage(width: 100, height: 100, pixels: pixels)
        let roi = GridSlicer.detectSliceROI(in: image)

        XCTAssertNil(roi)
    }

    func testDetectSliceROIPrefersLargestBrightComponent() throws {
        var pixels = [UInt8](repeating: 25, count: 120 * 120)

        for y in 10..<35 {
            for x in 10..<35 {
                pixels[(y * 120) + x] = 210
            }
        }

        for y in 45..<110 {
            for x in 50..<105 {
                pixels[(y * 120) + x] = 210
            }
        }

        let image = GrayscaleImage(width: 120, height: 120, pixels: pixels)
        let roi = try XCTUnwrap(GridSlicer.detectSliceROI(in: image))

        XCTAssertGreaterThan(roi.origin.x, 0.35)
        XCTAssertGreaterThan(roi.origin.y, 0.3)
        XCTAssertGreaterThan(roi.width, 0.4)
        XCTAssertGreaterThan(roi.height, 0.5)
    }

    func testColumnSummaryComputation() {
        let gridSpec = GridSpec(rows: 3, columns: 2)

        let dummyImage = UIImage()
        let dummyMask = UIImage()

        func makeResult(porosity: Double) -> BreadAnalysisResult {
            BreadAnalysisResult(
                porosity: porosity,
                poreCount: 10,
                averagePoreArea: 50,
                poreAreaCV: 0,
                maskImage: dummyMask,
                overlayImage: dummyMask
            )
        }

        let cellResults: [[GridCellResult?]] = [
            [
                GridCellResult(cellIndex: GridCellIndex(row: 0, column: 0), cellImage: dummyImage, analysisResult: makeResult(porosity: 0.1)),
                GridCellResult(cellIndex: GridCellIndex(row: 0, column: 1), cellImage: dummyImage, analysisResult: makeResult(porosity: 0.3)),
            ],
            [
                GridCellResult(cellIndex: GridCellIndex(row: 1, column: 0), cellImage: dummyImage, analysisResult: makeResult(porosity: 0.2)),
                GridCellResult(cellIndex: GridCellIndex(row: 1, column: 1), cellImage: dummyImage, analysisResult: makeResult(porosity: 0.4)),
            ],
            [
                GridCellResult(cellIndex: GridCellIndex(row: 2, column: 0), cellImage: dummyImage, analysisResult: makeResult(porosity: 0.3)),
                nil,
            ],
        ]

        let summaries = GridAnalysisResult.computeColumnSummaries(gridSpec: gridSpec, cellResults: cellResults)

        XCTAssertEqual(summaries.count, 2)

        XCTAssertEqual(summaries[0].sampleCount, 3)
        XCTAssertEqual(summaries[0].meanPorosity, 0.2, accuracy: 0.001)

        XCTAssertEqual(summaries[1].sampleCount, 2)
        XCTAssertEqual(summaries[1].meanPorosity, 0.35, accuracy: 0.001)
    }

    func testColumnSummaryReturnsZeroesForEmptyColumn() {
        let gridSpec = GridSpec(rows: 2, columns: 2)
        let dummyImage = UIImage()
        let dummyMask = UIImage()

        let result = BreadAnalysisResult(
            porosity: 0.25,
            poreCount: 4,
            averagePoreArea: 10,
            poreAreaCV: 0,
            maskImage: dummyMask,
            overlayImage: dummyMask
        )

        let cellResults: [[GridCellResult?]] = [
            [GridCellResult(cellIndex: GridCellIndex(row: 0, column: 0), cellImage: dummyImage, analysisResult: result), nil],
            [nil, nil],
        ]

        let summaries = GridAnalysisResult.computeColumnSummaries(gridSpec: gridSpec, cellResults: cellResults)

        XCTAssertEqual(summaries[0].sampleCount, 1)
        XCTAssertEqual(summaries[0].meanPorosity, 0.25, accuracy: 0.001)
        XCTAssertEqual(summaries[1].sampleCount, 0)
        XCTAssertEqual(summaries[1].meanPorosity, 0)
        XCTAssertEqual(summaries[1].stdPorosity, 0)
    }
}
