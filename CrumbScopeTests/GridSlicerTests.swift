import XCTest
@testable import CrumbScope

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

    func testSliceCellsUsesDetectedContentBounds() throws {
        let gridSpec = GridSpec(rows: 4, columns: 6)
        let regions = try GridSlicer.sliceCells(
            imageWidth: 600,
            imageHeight: 400,
            gridSpec: gridSpec,
            boundsNormalized: CGRect(x: 0.1, y: 0.125, width: 0.8, height: 0.75)
        )

        XCTAssertEqual(regions[0][0].pixelRect, CGRect(x: 60, y: 50, width: 80, height: 75))
        XCTAssertEqual(regions[3][5].pixelRect, CGRect(x: 460, y: 275, width: 80, height: 75))
    }

    func testDetectGridContentROIFindsUnionOfInteriorSlices() throws {
        var pixels = [UInt8](repeating: 25, count: 300 * 220)

        for row in 0..<2 {
            for column in 0..<3 {
                let originX = 45 + column * 75
                let originY = 35 + row * 75
                for y in originY..<(originY + 55) {
                    for x in originX..<(originX + 55) {
                        pixels[(y * 300) + x] = 210
                    }
                }
            }
        }

        let image = GrayscaleImage(width: 300, height: 220, pixels: pixels)
        let roi = try XCTUnwrap(GridSlicer.detectGridContentROI(in: image))

        XCTAssertGreaterThan(roi.origin.x, 0.1)
        XCTAssertGreaterThan(roi.origin.y, 0.1)
        XCTAssertLessThan(roi.maxX, 0.9)
        XCTAssertLessThan(roi.maxY, 0.9)
        XCTAssertGreaterThan(roi.width, 0.6)
        XCTAssertGreaterThan(roi.height, 0.55)
    }

    func testDetectGridContentROIReturnsNilWhenLargeComponentTouchesEdge() {
        var pixels = [UInt8](repeating: 25, count: 160 * 120)

        for y in 0..<55 {
            for x in 0..<55 {
                pixels[(y * 160) + x] = 210
            }
        }

        for y in 45..<100 {
            for x in 80..<135 {
                pixels[(y * 160) + x] = 210
            }
        }

        let image = GrayscaleImage(width: 160, height: 120, pixels: pixels)

        XCTAssertNil(GridSlicer.detectGridContentROI(in: image))
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

    func testCrustTrimmedROIRemovesSliceEdges() {
        let roi = GridSlicer.crustTrimmedROI(
            from: CGRect(x: 0.1, y: 0.2, width: 0.8, height: 0.6),
            imageWidth: 200,
            imageHeight: 100
        )

        XCTAssertEqual(roi.origin.x, 0.185, accuracy: 0.001)
        XCTAssertEqual(roi.origin.y, 0.26, accuracy: 0.001)
        XCTAssertEqual(roi.width, 0.63, accuracy: 0.001)
        XCTAssertEqual(roi.height, 0.48, accuracy: 0.001)
    }

    func testCrustTrimmedROIFallsBackToFullCellWhenDetectionFails() {
        let roi = GridSlicer.crustTrimmedROI(
            from: nil,
            imageWidth: 100,
            imageHeight: 80
        )

        XCTAssertEqual(roi.origin.x, 0.11, accuracy: 0.001)
        XCTAssertEqual(roi.origin.y, 0.1, accuracy: 0.001)
        XCTAssertEqual(roi.width, 0.78, accuracy: 0.001)
        XCTAssertEqual(roi.height, 0.8, accuracy: 0.001)
    }

    /// A macro close-up is crumb edge to edge: the region a crust trim would remove is
    /// crumb, so it is no darker than the interior and nothing should be trimmed.
    ///
    /// Note the coverage is *identical* to the whole-slice case below (both fill the
    /// frame), which is why the decision is made on intensity rather than coverage.
    func testCrustTrimmedROILeavesCrustFreeFramesUntrimmed() {
        let side = 400
        let uniformCrumb = GrayscaleImage(
            width: side, height: side,
            pixels: [UInt8](repeating: 200, count: side * side)
        )

        let roi = GridSlicer.crustTrimmedROI(
            from: CGRect(x: 0, y: 0, width: 1, height: 1),
            imageWidth: side,
            imageHeight: side,
            sourceImage: uniformCrumb
        )

        XCTAssertEqual(roi.origin.x, 0, accuracy: 0.001)
        XCTAssertEqual(roi.origin.y, 0, accuracy: 0.001)
        XCTAssertEqual(roi.width, 1, accuracy: 0.001)
        XCTAssertEqual(roi.height, 1, accuracy: 0.001)
    }

    /// A slice that fills its cell still has a crust ring, and the ring is darker than
    /// the crumb. That is the R3C3 case: coverage alone says "fills the frame, nothing to
    /// trim", which silently swallowed its crust and halved its reported porosity.
    func testCrustTrimmedROITrimsWhenTheBandIsDarker() {
        let side = 400
        var pixels = [UInt8](repeating: 210, count: side * side)
        for y in 0..<side {
            for x in 0..<side {
                let edgeDistance = min(min(x, y), min(side - 1 - x, side - 1 - y))
                if edgeDistance < 40 {
                    pixels[(y * side) + x] = 150
                }
            }
        }
        let crusted = GrayscaleImage(width: side, height: side, pixels: pixels)

        let roi = GridSlicer.crustTrimmedROI(
            from: CGRect(x: 0, y: 0, width: 1, height: 1),
            imageWidth: side,
            imageHeight: side,
            sourceImage: crusted
        )

        XCTAssertLessThan(roi.width, 1.0)
        XCTAssertLessThan(roi.height, 1.0)
        XCTAssertGreaterThan(roi.origin.x, 0)
        XCTAssertGreaterThan(roi.origin.y, 0)
        XCTAssertEqual(roi.midX, 0.5, accuracy: 0.01)
        XCTAssertEqual(roi.midY, 0.5, accuracy: 0.01)
    }

    /// Without an image there is no way to judge a ring, so the historical unconditional
    /// trim is kept. This is what the pure-geometry callers rely on.
    func testCrustTrimmedROIWithoutAnImageKeepsTrimming() {
        let roi = GridSlicer.crustTrimmedROI(
            from: CGRect(x: 0, y: 0, width: 1, height: 1),
            imageWidth: 100,
            imageHeight: 80
        )

        XCTAssertLessThan(roi.width, 1.0)
        XCTAssertLessThan(roi.height, 1.0)
    }

    /// Illumination falloff alone darkens a frame's outer band, and by an amount that
    /// scales with the exposure: against the old absolute margin this crumb scored 7.2 at
    /// level 120 and was kept, exactly 12.0 at 200 and 16.8 at 280 — the last two
    /// trimmed. The smooth field is now extrapolated from the interior and taken out of
    /// the comparison, so a falloff cannot spend the margin at any level.
    ///
    /// This is the macro close-up of a vignetted frame: crumb edge to edge, no crust,
    /// and it must come back untrimmed at every exposure.
    func testCrustTrimmedROISkipsTrimUnderCameraFalloff() {
        let side = 400
        let center = Double(side) / 2
        let maximumDistance = (center * center * 2).squareRoot()

        for crumbLevel in [120, 200, 280] {
            var pixels = [UInt8](repeating: 0, count: side * side)
            for y in 0..<side {
                for x in 0..<side {
                    let dx = Double(x) + 0.5 - center
                    let dy = Double(y) + 0.5 - center
                    let normalizedDistance = (dx * dx + dy * dy).squareRoot() / maximumDistance
                    let value = Double(crumbLevel) * (1 - 0.18 * normalizedDistance * normalizedDistance)
                    pixels[(y * side) + x] = UInt8(clamping: Int(value.rounded()))
                }
            }
            let vignetted = GrayscaleImage(width: side, height: side, pixels: pixels)

            let roi = GridSlicer.crustTrimmedROI(
                from: CGRect(x: 0, y: 0, width: 1, height: 1),
                imageWidth: side,
                imageHeight: side,
                sourceImage: vignetted
            )

            XCTAssertEqual(roi.width, 1, accuracy: 0.001, "crumb level \(crumbLevel)")
            XCTAssertEqual(roi.height, 1, accuracy: 0.001, "crumb level \(crumbLevel)")
        }
    }

    /// The mirror image of the falloff test: a real crust ring is a step, and it must be
    /// trimmed at every exposure, not just the bright ones. Crust is set at 70% of the
    /// crumb level so the step's *relative* size is constant while its absolute size
    /// moves with the level.
    func testCrustTrimmedROITrimsCrustAtEveryExposure() {
        let side = 400

        for crumbLevel in [150, 210, 280] {
            let crustLevel = UInt8(clamping: Int(Double(crumbLevel) * 0.7))
            var pixels = [UInt8](repeating: UInt8(clamping: crumbLevel), count: side * side)
            for y in 0..<side {
                for x in 0..<side {
                    let edgeDistance = min(min(x, y), min(side - 1 - x, side - 1 - y))
                    if edgeDistance < 40 {
                        pixels[(y * side) + x] = crustLevel
                    }
                }
            }
            let crusted = GrayscaleImage(width: side, height: side, pixels: pixels)

            let roi = GridSlicer.crustTrimmedROI(
                from: CGRect(x: 0, y: 0, width: 1, height: 1),
                imageWidth: side,
                imageHeight: side,
                sourceImage: crusted
            )

            XCTAssertLessThan(roi.width, 1.0, "crumb level \(crumbLevel)")
            XCTAssertLessThan(roi.height, 1.0, "crumb level \(crumbLevel)")
        }
    }

    /// The detector's search padding is not bread. A crust-free slice on a dark bench
    /// comes with a padding ring that is ~20% of the band, dragging the band's mean far
    /// enough below the interior to be read as crust — and trimming 11% per side of a
    /// slice that has none. With the mask the band is measured over the slice itself.
    func testCrustTrimmedROIIgnoresTheDetectorsPaddingRing() throws {
        let side = 233
        let sliceSide = 200
        var pixels = [UInt8](repeating: 30, count: side * side)
        for y in 16..<(16 + sliceSide) {
            for x in 16..<(16 + sliceSide) {
                pixels[(y * side) + x] = 200
            }
        }
        let cell = GrayscaleImage(width: side, height: side, pixels: pixels)

        let slice = try XCTUnwrap(GridSlicer.detectSlice(in: cell))
        XCTAssertGreaterThan(slice.roi.width, CGFloat(sliceSide) / CGFloat(side), "ROI should carry padding")

        let crumbROI = GridSlicer.crustTrimmedROI(
            from: slice.roi,
            sliceMask: slice.mask,
            imageWidth: side,
            imageHeight: side,
            sourceImage: cell
        )

        XCTAssertEqual(crumbROI.width, slice.roi.width, accuracy: 0.001)
        XCTAssertEqual(crumbROI.height, slice.roi.height, accuracy: 0.001)
    }

    /// A round slice does not fill its bounding box, so the box corners — bench, or a
    /// pale tray — sit in the band without being crust. Judged over the box they can
    /// outvote a real crust ring (brighter corners push the band mean *up*, and the trim
    /// is skipped, which is the R3C3 failure from the other side); judged over the slice
    /// they cannot vote at all.
    func testCrustTrimmedROIJudgesARoundSliceOnItsCrustNotItsCorners() throws {
        let side = 400
        let radius = 170.0
        let center = Double(side) / 2

        func disc(crustDepth: Double) -> GrayscaleImage {
            var pixels = [UInt8](repeating: 30, count: side * side)
            for y in 0..<side {
                for x in 0..<side {
                    let dx = Double(x) + 0.5 - center
                    let dy = Double(y) + 0.5 - center
                    let distance = (dx * dx + dy * dy).squareRoot()
                    if distance < radius {
                        pixels[(y * side) + x] = distance >= radius - crustDepth ? 130 : 200
                    }
                }
            }
            return GrayscaleImage(width: side, height: side, pixels: pixels)
        }

        let crusted = disc(crustDepth: 20)
        let crustedSlice = try XCTUnwrap(GridSlicer.detectSlice(in: crusted))
        let crustedROI = GridSlicer.crustTrimmedROI(
            from: crustedSlice.roi,
            sliceMask: crustedSlice.mask,
            imageWidth: side,
            imageHeight: side,
            sourceImage: crusted
        )
        XCTAssertLessThan(crustedROI.width, crustedSlice.roi.width, "round slice with a crust ring must trim")

        let bare = disc(crustDepth: 0)
        let bareSlice = try XCTUnwrap(GridSlicer.detectSlice(in: bare))
        let bareROI = GridSlicer.crustTrimmedROI(
            from: bareSlice.roi,
            sliceMask: bareSlice.mask,
            imageWidth: side,
            imageHeight: side,
            sourceImage: bare
        )
        XCTAssertEqual(bareROI.width, bareSlice.roi.width, accuracy: 0.001)
        XCTAssertEqual(bareROI.height, bareSlice.roi.height, accuracy: 0.001)
    }

    /// A slice ROI too thin to inset in Y used to skip the gate altogether (the old
    /// condition required both insets to be non-zero) and trim the surviving axis with
    /// no evidence — exactly the crust-free input the gate exists to protect. The band
    /// is well defined as long as one axis has one: the strips the trim would remove.
    func testCrustTrimmedROIJudgesTheBandAlongTheOnlyTrimmedAxis() throws {
        let width = 233
        let height = 242
        var pixels = [UInt8](repeating: 30, count: width * height)
        for y in 114..<128 {
            for x in 2..<230 {
                pixels[(y * width) + x] = 200
            }
        }
        let cell = GrayscaleImage(width: width, height: height, pixels: pixels)

        let slice = try XCTUnwrap(GridSlicer.detectSlice(in: cell))
        let crumbROI = GridSlicer.crustTrimmedROI(
            from: slice.roi,
            sliceMask: slice.mask,
            imageWidth: width,
            imageHeight: height,
            sourceImage: cell
        )

        XCTAssertEqual(crumbROI.width, slice.roi.width, accuracy: 0.001)
        XCTAssertEqual(crumbROI.height, slice.roi.height, accuracy: 0.001)
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
