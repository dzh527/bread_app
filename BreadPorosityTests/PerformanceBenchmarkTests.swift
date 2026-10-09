import UIKit
import XCTest
@testable import BreadPorosity

/// Performance benchmarks for the porosity pipeline.
///
/// These are measurements, not correctness tests, and they are slow. Keep them out
/// of routine runs:
///
///     xcodebuild test ... -skip-testing:BreadPorosityTests/PerformanceBenchmarkTests
///
/// Run only these:
///
///     xcodebuild test ... -only-testing:BreadPorosityTests/PerformanceBenchmarkTests
///
/// Coverage instrumentation (`-profile-coverage-mapping`) is on by default in this
/// project's test action and adds measurable overhead to every basic block, so
/// measure with `-enableCodeCoverage NO`.
///
/// xcodebuild does not surface the test process's stdout and Xcode 26 records no
/// activities for unit tests, so results are written to `/tmp/bread_perf_report.txt`
/// on the host (simulator absolute paths resolve against the macOS filesystem).
final class PerformanceBenchmarkTests: XCTestCase {
    /// The longest edge `BreadAnalyzer` downsamples to before processing.
    private static let processingDimension = 1400
    /// 4:3, the aspect ratio of a downsampled iPhone photo.
    private static let photoWidth = 1400
    private static let photoHeight = 1050

    private static let reportPath = "/tmp/bread_perf_report.txt"
    private static var reportLines: [String] = []

    override func tearDown() {
        super.tearDown()
        Self.flushReport()
    }

    // MARK: - What the cost scales with

    /// `BackgroundRemover.detectBackground` runs a morphological close whose radius
    /// is `min(width, height) / 40`, and the close is a naive per-pixel scan of the
    /// full `(2r+1)²` window. Cost should therefore track `area × r²` — i.e. grow
    /// far faster than pixel count. This sweep is what distinguishes that from
    /// ordinary linear cost.
    func testBackgroundRemoverScaling() throws {
        Self.emit("")
        Self.emit("=== BackgroundRemover.removeBackground vs image size (square crumb) ===")

        for side in [250, 500, 1000, 1400] {
            let image = Self.makePhoto(
                rows: 1, columns: 1,
                width: side, height: side,
                margin: side / 10, poreDensity: 1.0,
                seed: 0x5EED
            )
            let input = try AnalysisImageFactory.makeInput(from: image, maxDimension: Self.processingDimension)
            let grayscale = input.grayscale
            let radius = max(3, min(grayscale.width, grayscale.height) / 40)
            let kernelSamples = (2 * radius + 1) * (2 * radius + 1)

            var samples: [Double] = []
            for _ in 0..<2 {
                let start = CFAbsoluteTimeGetCurrent()
                _ = BackgroundRemover.removeBackground(grayscale)
                samples.append(CFAbsoluteTimeGetCurrent() - start)
            }

            let best = samples.min() ?? 0
            Self.emit(String(
                format: "  %4dx%-4d  %6d px  closeRadius %2d (%3d samples/px, %.2fG ops)  best %6.3fs  %8.1f ns/px",
                grayscale.width, grayscale.height, grayscale.pixelCount,
                radius, kernelSamples,
                Double(grayscale.pixelCount) * Double(kernelSamples) * 2 / 1e9,
                best,
                best / Double(grayscale.pixelCount) * 1e9
            ))
        }
    }

    // MARK: - Whole-pipeline scaling

    /// Same 4×6 photo of slices, analyzed at several grid specs, to see how the cost
    /// tracks cell size (which drives the morphology radius) rather than cell count.
    func testGridScaling() async throws {
        Self.emit("")
        Self.emit("=== analyzeGrid scaling (4x6 slice photo, \(Self.photoWidth)x\(Self.photoHeight)) ===")

        let photo = Self.makePhoto(
            rows: 4, columns: 6,
            width: Self.photoWidth, height: Self.photoHeight,
            margin: 16, poreDensity: 1.0, seed: 0xB0A2D
        )
        let analyzer = BreadAnalyzer()

        let specs = [
            GridSpec(rows: 1, columns: 1),
            GridSpec(rows: 2, columns: 2),
            GridSpec(rows: 4, columns: 6),
            GridSpec(rows: 8, columns: 8)
        ]

        for spec in specs {
            let warmup = try await analyzer.analyzeGrid(image: photo, gridSpec: spec)
            let cellCount = warmup.allResults.count
            let meanPorosity = warmup.allResults.map(\.analysisResult.porosity).reduce(0, +)
                / Double(max(1, warmup.allResults.count))

            var samples: [Double] = []
            for _ in 0..<2 {
                let start = CFAbsoluteTimeGetCurrent()
                _ = try await analyzer.analyzeGrid(image: photo, gridSpec: spec)
                samples.append(CFAbsoluteTimeGetCurrent() - start)
            }

            let best = samples.min() ?? 0
            Self.emit(String(
                format: "  %d x %d  (%2d cells)  best %7.3fs  %7.1f ms/cell  |  %2d cells analyzed, mean porosity %.1f%%",
                spec.rows, spec.columns, spec.cellCount,
                best, best / Double(max(1, cellCount)) * 1000,
                cellCount, meanPorosity * 100
            ))
        }
    }

    /// The same 4×6 grid with no pores at all. Comparing against `testGridScaling`
    /// separates the fixed per-cell cost from the per-pore cost.
    func testGridScalingWithoutPores() async throws {
        Self.emit("")
        Self.emit("=== analyzeGrid, identical 4x6 photo but zero pores ===")

        let photo = Self.makePhoto(
            rows: 4, columns: 6,
            width: Self.photoWidth, height: Self.photoHeight,
            margin: 16, poreDensity: 0, seed: 0xB0A2D
        )
        let analyzer = BreadAnalyzer()
        let spec = GridSpec(rows: 4, columns: 6)

        let warmup = try await analyzer.analyzeGrid(image: photo, gridSpec: spec)
        var samples: [Double] = []
        for _ in 0..<2 {
            let start = CFAbsoluteTimeGetCurrent()
            _ = try await analyzer.analyzeGrid(image: photo, gridSpec: spec)
            samples.append(CFAbsoluteTimeGetCurrent() - start)
        }

        let totalPores = warmup.allResults.reduce(0) { $0 + $1.analysisResult.poreCount }
        Self.emit(String(
            format: "  4 x 6  (%2d cells)  best %7.3fs  %7.1f ms/cell  |  %d pores found",
            spec.cellCount, samples.min() ?? 0,
            (samples.min() ?? 0) / Double(spec.cellCount) * 1000,
            totalPores
        ))
    }

    // MARK: - Per-stage breakdown on the real input

    /// Mirrors what the app actually feeds the stages: grid mode crops each cell to
    /// the detected slice, trims the crust, and only then runs the pipeline. Timing
    /// the stages on an uncropped frame would measure a path the UI never takes.
    func testStageBreakdownOnCrumbCrop() throws {
        let photo = Self.makePhoto(
            rows: 1, columns: 1,
            width: Self.photoWidth, height: Self.photoHeight,
            margin: 120, poreDensity: 1.0, seed: 0xB0A2D
        )

        var input: AnalysisImageInput!
        try Self.report("AnalysisImageFactory.makeInput") {
            input = try AnalysisImageFactory.makeInput(from: photo, maxDimension: Self.processingDimension)
        }

        // The cell crop and crust trim that `analyzeGridSynchronously` performs.
        let wholeCell = input.grayscale
        let detectedSlice = GridSlicer.detectSlice(in: wholeCell)
        let sliceROI = detectedSlice?.roi
        let crumbROI = GridSlicer.crustTrimmedROI(
            from: sliceROI,
            sliceMask: detectedSlice?.mask,
            imageWidth: wholeCell.width,
            imageHeight: wholeCell.height,
            sourceImage: wholeCell
        )
        let crumbRect = crumbROI
            .clampedToUnit(minSize: 0.05)
            .denormalized(in: CGRect(x: 0, y: 0, width: wholeCell.width, height: wholeCell.height))
            .integral
        let grayscale = wholeCell.cropped(to: crumbRect)

        Self.emit("")
        Self.emit("=== Stage breakdown on the crust-trimmed crumb crop ===")
        let sliceROIText = sliceROI.map {
            String(format: "%.0f%% x %.0f%% of frame", $0.width * 100, $0.height * 100)
        } ?? "not detected"
        Self.emit("  frame \(wholeCell.width)x\(wholeCell.height) -> slice ROI \(sliceROIText)"
            + " -> crumb crop \(grayscale.width)x\(grayscale.height) = \(grayscale.pixelCount) px")
        let radius = max(3, min(grayscale.width, grayscale.height) / 40)
        Self.emit("  [morphology close radius here = \(radius)]")

        var parameters = AnalysisParameters()
        parameters.thresholdMode = .adaptive
        parameters.morphologyKernelSize = 5
        parameters.minPoreArea = max(24, grayscale.pixelCount / 2500)

        var backgroundRemoved: GrayscaleImage!
        Self.report("BackgroundRemover.removeBackground") {
            backgroundRemoved = BackgroundRemover.removeBackground(grayscale)
        }

        var normalized: GrayscaleImage!
        Self.report("ImagePreprocessor.normalize") {
            normalized = ImagePreprocessor.normalize(backgroundRemoved)
        }

        var segmented: BinaryMask!
        Self.report("Thresholding.segment (adaptive)") {
            segmented = Thresholding.segment(normalized, parameters: parameters)
        }

        var cleaned: BinaryMask!
        Self.report("BinaryMorphology.clean") {
            cleaned = BinaryMorphology.clean(segmented, kernelSize: parameters.morphologyKernelSize)
        }

        var refined: BinaryMask!
        Self.report("PoreRegionRefiner.growAndFill") {
            refined = PoreRegionRefiner.growAndFill(
                seedMask: cleaned,
                sourceImage: normalized,
                kernelSize: parameters.morphologyKernelSize
            )
        }

        var components: ConnectedComponentSummary!
        Self.report("ConnectedComponents.filter") {
            components = ConnectedComponents.filter(
                mask: refined,
                minimumArea: parameters.minPoreArea,
                maximumArea: parameters.maxPoreArea,
                sourceImage: normalized,
                minimumLocalContrast: parameters.minimumPoreContrast
            )
        }

        try Self.report("MaskRenderer (mask + overlay)") {
            _ = try MaskRenderer.makeMaskImage(from: components.filteredMask)
            _ = try MaskRenderer.makeOverlayImage(
                baseImage: input.displayImage,
                mask: components.filteredMask
            )
        }

        Self.emit(String(
            format: "  --- sanity: %d pores retained, porosity %.1f%% (was %.1f%% before area filtering)",
            components.poreCount,
            Double(components.filteredMask.porePixelCount) / Double(components.filteredMask.pixelCount) * 100,
            Double(refined.porePixelCount) / Double(refined.pixelCount) * 100
        ))
    }

    // MARK: - Real photo

    /// Runs the real 4×6 photo of slices end to end, to check whether the synthetic
    /// imagery told the truth about both timing and pore counts.
    func testRealPhotoGrid() async throws {
        guard let image = Self.loadRealPhoto() else { return }
        let analyzer = BreadAnalyzer()
        let spec = GridSpec(rows: 4, columns: 6)

        Self.emit("")
        Self.emit("=== Real photo, grid \(spec.rows)x\(spec.columns) ===")

        let result = try await analyzer.analyzeGrid(image: image, gridSpec: spec)

        var samples: [Double] = []
        for _ in 0..<2 {
            let start = CFAbsoluteTimeGetCurrent()
            _ = try await analyzer.analyzeGrid(image: image, gridSpec: spec)
            samples.append(CFAbsoluteTimeGetCurrent() - start)
        }
        let best = samples.min() ?? 0
        Self.emit(String(
            format: "  total best %.3fs  mean %.3fs  |  %.0f ms/cell  |  detected grid region %.0f%% x %.0f%% of frame",
            best, samples.reduce(0, +) / Double(samples.count),
            best / Double(spec.cellCount) * 1000,
            result.gridRegionNormalized.width * 100,
            result.gridRegionNormalized.height * 100
        ))

        Self.emit("  cell    porosity     pores   avgArea    areaCV   crumbROI px")
        for cell in result.allResults {
            let paddedLabel = cell.cellIndex.label.padding(toLength: 6, withPad: " ", startingAt: 0)
            Self.emit(String(
                format: "  %@ %8.1f%%  %7d   %7.1f   %6.2f   %10d",
                paddedLabel,
                cell.analysisResult.porosity * 100,
                cell.analysisResult.poreCount,
                cell.analysisResult.averagePoreArea,
                cell.analysisResult.poreAreaCV,
                cell.crumbROIArea
            ))
        }

        let porosities = result.allResults.map(\.analysisResult.porosity)
        let pores = result.allResults.map(\.analysisResult.poreCount)
        if !porosities.isEmpty {
            let mean = porosities.reduce(0, +) / Double(porosities.count)
            let variance = porosities.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(porosities.count)
            Self.emit(String(
                format: "  summary: porosity mean %.1f%% sd %.1f%%  |  pores total %ld, per cell mean %ld (min %ld, max %ld)",
                mean * 100, variance.squareRoot() * 100,
                pores.reduce(0, +), pores.reduce(0, +) / pores.count,
                pores.min() ?? 0, pores.max() ?? 0
            ))
        }
    }

    /// How the pore count collapses as the minimum-area threshold rises. If a large
    /// share of "pores" are only a handful of pixels, the threshold is picking up
    /// grain rather than crumb structure. This is the check that tells us whether
    /// the synthetic run's spurious-component result was an artefact of the
    /// generator's noise or a real property of the pipeline.
    func testRealPhotoComponentSurvival() throws {
        guard let image = Self.loadRealPhoto() else { return }
        let input = try AnalysisImageFactory.makeInput(from: image, maxDimension: Self.processingDimension)
        let wholeFrame = input.grayscale
        let spec = GridSpec(rows: 4, columns: 6)
        let gridRegion = (GridSlicer.detectGridContentROI(in: wholeFrame)
            ?? CGRect(x: 0, y: 0, width: 1, height: 1)).clampedToUnit(minSize: 0.05)
        let regions = try GridSlicer.sliceCells(
            imageWidth: wholeFrame.width,
            imageHeight: wholeFrame.height,
            gridSpec: spec,
            boundsNormalized: gridRegion
        )

        // A middle cell, so it is a whole slice rather than a partial one.
        let region = regions[spec.rows / 2][spec.columns / 2]
        let cell = wholeFrame.cropped(to: region.pixelRect)
        let detectedSlice = GridSlicer.detectSlice(in: cell)
        let crumbROI = GridSlicer.crustTrimmedROI(
            from: detectedSlice?.roi,
            sliceMask: detectedSlice?.mask,
            imageWidth: cell.width,
            imageHeight: cell.height,
            sourceImage: cell
        )
        let crumbRect = crumbROI
            .clampedToUnit(minSize: 0.05)
            .denormalized(in: CGRect(x: 0, y: 0, width: cell.width, height: cell.height))
            .integral
        let crumb = cell.cropped(to: crumbRect)

        var parameters = AnalysisParameters()
        parameters.thresholdMode = .adaptive
        parameters.morphologyKernelSize = 5

        let backgroundRemoved = BackgroundRemover.removeBackground(crumb)
        let normalized = ImagePreprocessor.normalize(backgroundRemoved)
        let segmented = Thresholding.segment(normalized, parameters: parameters)
        let cleaned = BinaryMorphology.clean(segmented, kernelSize: parameters.morphologyKernelSize)
        let refined = PoreRegionRefiner.growAndFill(
            seedMask: cleaned, sourceImage: normalized, kernelSize: parameters.morphologyKernelSize
        )

        Self.emit("")
        Self.emit("=== Component survival curve, real photo, cell \(region.cellIndex.label) ===")
        Self.emit("  crumb crop \(crumb.width)x\(crumb.height) = \(crumb.pixelCount) px")
        Self.emit(String(
            format: "  raw threshold density %.2f%%, after morphology %.2f%%, after region refine %.2f%%",
            Double(segmented.porePixelCount) / Double(segmented.pixelCount) * 100,
            Double(cleaned.porePixelCount) / Double(cleaned.pixelCount) * 100,
            Double(refined.porePixelCount) / Double(refined.pixelCount) * 100
        ))
        Self.emit("  minArea    pores   porosity   avgArea")

        for minimumArea in [1, 2, 4, 8, 16, 24, 32, 64, 128, 256, 512, 1024] {
            let summary = ConnectedComponents.filter(
                mask: refined,
                minimumArea: minimumArea,
                maximumArea: nil,
                sourceImage: normalized,
                minimumLocalContrast: 0
            )
            let porosity = Double(summary.filteredMask.porePixelCount)
                / Double(summary.filteredMask.pixelCount) * 100
            Self.emit(String(
                format: "  %7d %8d    %6.2f%%   %7.1f",
                minimumArea, summary.poreCount, porosity, summary.averageArea
            ))
        }
    }

    /// The grid path builds each cell image with `UIGraphicsImageRenderer(size:)`,
    /// which defaults to the *screen* scale. On a @3x device that rasterises the cell
    /// at 3× the pixels the source actually has. `analyzeSynchronously` then measures
    /// `minPoreArea` from the un-upscaled cell while applying it to the upscaled one.
    /// This reports both, so the mismatch is visible rather than inferred.
    func testCellCropResolution() throws {
        guard let image = Self.loadRealPhoto() else { return }
        let input = try AnalysisImageFactory.makeInput(from: image, maxDimension: Self.processingDimension)
        let fullFrame = input.grayscale
        let spec = GridSpec(rows: 4, columns: 6)
        let gridRegion = (GridSlicer.detectGridContentROI(in: fullFrame)
            ?? CGRect(x: 0, y: 0, width: 1, height: 1)).clampedToUnit(minSize: 0.05)
        let regions = try GridSlicer.sliceCells(
            imageWidth: fullFrame.width,
            imageHeight: fullFrame.height,
            gridSpec: spec,
            boundsNormalized: gridRegion
        )
        let region = regions[spec.rows / 2][spec.columns / 2]
        let cellRect = region.pixelRect

        // Exactly what BreadAnalyzer does to build the cell image it analyses —
        // including the pinned raster scale, so this reports production behaviour
        // rather than the device's screen scale.
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = AnalysisImageFactory.analysisRasterScale
        let renderer = UIGraphicsImageRenderer(size: cellRect.size, format: format)
        let cellImage = renderer.image { _ in
            input.displayImage.draw(at: CGPoint(x: -cellRect.origin.x, y: -cellRect.origin.y))
        }

        let cellGrayscale = fullFrame.cropped(to: cellRect)
        let detectedSlice = GridSlicer.detectSlice(in: cellGrayscale)
        let crumbROI = GridSlicer.crustTrimmedROI(
            from: detectedSlice?.roi,
            sliceMask: detectedSlice?.mask,
            imageWidth: cellGrayscale.width,
            imageHeight: cellGrayscale.height,
            sourceImage: cellGrayscale
        )

        // Exactly what analyzeSynchronously then processes.
        let processed = try AnalysisImageFactory.makeInput(
            from: cellImage,
            maxDimension: Self.processingDimension,
            roiRectNormalized: crumbROI
        )

        Self.emit("")
        Self.emit("=== Cell crop resolution, cell \(region.cellIndex.label) ===")
        Self.emit("  cell rect in processed frame      \(Int(cellRect.width))x\(Int(cellRect.height)) pt")
        Self.emit("  cellGrayscale (slice ROI only)    "
            + "\(cellGrayscale.width)x\(cellGrayscale.height) = \(cellGrayscale.pixelCount) px")
        Self.emit("  cellImage UIGraphicsImageRenderer scale = \(cellImage.scale)")
        if let cellCG = cellImage.cgImage {
            Self.emit("  cellImage actual pixels           \(cellCG.width)x\(cellCG.height)")
        }
        Self.emit("  grayscale actually analysed       "
            + "\(processed.grayscale.width)x\(processed.grayscale.height) = \(processed.grayscale.pixelCount) px")
        // The minimum pore area is now derived by analyzeSynchronously from the region it
        // actually analyses, so this reports the same expression rather than a
        // pre-raster pixel count that would be calibrated on the wrong image.
        let floor = 24
        let ratio = 1.0 / 10_000
        let effective = max(floor, Int(Double(processed.grayscale.pixelCount) * ratio))
        Self.emit(String(
            format: "  minPoreArea = max(%d, %d px x 1/10000) = %d px  (%.1fx the pre-raster cell)",
            floor, processed.grayscale.pixelCount, effective,
            Double(processed.grayscale.pixelCount) / Double(cellGrayscale.pixelCount)
        ))
    }

    /// The resolution mismatch changes the *answer*, not just the speed. This runs
    /// the identical stage chain over the same cell rendered at the current @3x
    /// scale and at scale 1, holding `minPoreArea` fixed so only the raster differs.
    func testCellUpscaleImpact() throws {
        guard let image = Self.loadRealPhoto() else { return }
        let input = try AnalysisImageFactory.makeInput(from: image, maxDimension: Self.processingDimension)
        let fullFrame = input.grayscale
        let spec = GridSpec(rows: 4, columns: 6)
        let gridRegion = (GridSlicer.detectGridContentROI(in: fullFrame)
            ?? CGRect(x: 0, y: 0, width: 1, height: 1)).clampedToUnit(minSize: 0.05)
        let regions = try GridSlicer.sliceCells(
            imageWidth: fullFrame.width,
            imageHeight: fullFrame.height,
            gridSpec: spec,
            boundsNormalized: gridRegion
        )

        Self.emit("")
        Self.emit("=== Effect of the @3x cell raster, same cell, same minPoreArea ===")
        Self.emit("  scale      analysed px    pores   porosity   avgArea")

        for scale in [3.0, 2.0, 1.0] {
            // Sampled across cells so this is not one unrepresentative slice.
            var porosityTotal = 0.0
            var poreTotal = 0
            var analysedPixels = 0
            var sampleCount = 0

            for row in stride(from: 0, to: spec.rows, by: 2) {
                for column in stride(from: 0, to: spec.columns, by: 2) {
                    let region = regions[row][column]
                    let cellRect = region.pixelRect
                    let format = UIGraphicsImageRendererFormat.default()
                    format.scale = CGFloat(scale)
                    let cellImage = UIGraphicsImageRenderer(size: cellRect.size, format: format).image { _ in
                        input.displayImage.draw(at: CGPoint(x: -cellRect.origin.x, y: -cellRect.origin.y))
                    }

                    let cellGrayscale = fullFrame.cropped(to: cellRect)
                    let detectedSlice = GridSlicer.detectSlice(in: cellGrayscale)
                    let crumbROI = GridSlicer.crustTrimmedROI(
                        from: detectedSlice?.roi,
                        sliceMask: detectedSlice?.mask,
                        imageWidth: cellGrayscale.width,
                        imageHeight: cellGrayscale.height,
                        sourceImage: cellGrayscale
                    )
                    // Held constant across scales, exactly as BreadAnalyzer computes it.
                    let minPoreArea = max(24, cellGrayscale.pixelCount / 2500)

                    let analysed = try Self.runStageChain(
                        image: cellImage, crumbROI: crumbROI, minPoreArea: minPoreArea
                    )
                    porosityTotal += analysed.porosity
                    poreTotal += analysed.poreCount
                    analysedPixels += analysed.pixelCount
                    sampleCount += 1
                }
            }

            let divisor = Double(max(1, sampleCount))
            Self.emit(String(
                format: "  %.0fx   %12d   %6d     %6.1f%%   (mean over %d cells)",
                scale, analysedPixels / max(1, sampleCount), poreTotal / max(1, sampleCount),
                porosityTotal / divisor * 100, sampleCount
            ))
        }
    }

    private struct StageChainResult {
        let porosity: Double
        let poreCount: Int
        let pixelCount: Int
    }

    /// `BreadAnalyzer.analyzeSynchronously`, reproduced so benchmarks can vary one
    /// input at a time (that method is private).
    private static func runStageChain(
        image: UIImage,
        crumbROI: CGRect,
        minPoreArea: Int
    ) throws -> StageChainResult {
        let analysisInput = try AnalysisImageFactory.makeInput(
            from: image,
            maxDimension: processingDimension,
            roiRectNormalized: crumbROI
        )
        let backgroundRemoved = BackgroundRemover.removeBackground(analysisInput.grayscale)
        let normalized = ImagePreprocessor.normalize(backgroundRemoved)

        var parameters = AnalysisParameters()
        parameters.thresholdMode = .adaptive
        parameters.morphologyKernelSize = 5
        parameters.minPoreArea = minPoreArea

        let segmented = Thresholding.segment(normalized, parameters: parameters)
        let cleaned = BinaryMorphology.clean(segmented, kernelSize: parameters.morphologyKernelSize)
        let refined = PoreRegionRefiner.growAndFill(
            seedMask: cleaned,
            sourceImage: normalized,
            kernelSize: parameters.morphologyKernelSize
        )
        let components = ConnectedComponents.filter(
            mask: refined,
            minimumArea: minPoreArea,
            maximumArea: nil,
            sourceImage: normalized,
            minimumLocalContrast: 0
        )

        return StageChainResult(
            porosity: Double(components.filteredMask.porePixelCount)
                / Double(components.filteredMask.pixelCount),
            poreCount: components.poreCount,
            pixelCount: components.filteredMask.pixelCount
        )
    }

    // MARK: - Visual comparison

    private struct OverlayPanel {
        let caption: String
        let overlay: UIImage
    }

    /// Renders the app's own pore overlay for one slice across raster scales and
    /// threshold biases, and writes a labelled montage so the "is the fine crumb
    /// texture a pore?" judgement can be made by eye rather than by number.
    func testVisualScaleAndBiasComparison() throws {
        guard let slice = UIImage(contentsOfFile: Self.slicePath) else {
            Self.emit("  !! could not read \(Self.slicePath)")
            XCTFail("slice image missing")
            return
        }

        let input = try AnalysisImageFactory.makeInput(from: slice, maxDimension: Self.processingDimension)
        let wholeFrame = input.grayscale
        let detectedSlice = GridSlicer.detectSlice(in: wholeFrame)
        let sliceROI = detectedSlice?.roi
        let crumbROI = GridSlicer.crustTrimmedROI(
            from: sliceROI,
            sliceMask: detectedSlice?.mask,
            imageWidth: wholeFrame.width,
            imageHeight: wholeFrame.height,
            sourceImage: wholeFrame
        )
        Self.emit("")
        Self.emit("=== Visual comparison on the single slice ===")
        Self.emit("  frame \(wholeFrame.width)x\(wholeFrame.height), "
            + "slice ROI \(sliceROI.map { String(format: "%.0f%% x %.0f%%", $0.width * 100, $0.height * 100) } ?? "none"), "
            + "crumb ROI \(String(format: "%.0f%% x %.0f%%", crumbROI.width * 100, crumbROI.height * 100))")

        var panels: [OverlayPanel] = []

        // Row 1 — raster scale, everything else fixed.
        for scale in [3.0, 2.0, 1.0] {
            let format = UIGraphicsImageRendererFormat.default()
            format.scale = CGFloat(scale)
            let cell = UIGraphicsImageRenderer(size: input.displayImage.size, format: format).image { _ in
                input.displayImage.draw(at: .zero)
            }
            let rendered = try Self.stageChainWithOverlay(image: cell, crumbROI: crumbROI, bias: 0, sauvolaK: 0.34, minPoreArea: 24)
            Self.emit(String(
                format: "  scale %.0fx  ->  analysed %dx%d px, %d pores, %.1f%% porosity",
                scale, rendered.analysedWidth, rendered.analysedHeight,
                rendered.poreCount, rendered.porosity * 100
            ))
            panels.append(OverlayPanel(
                caption: String(format: "raster %.0fx  |  %.1f%%  |  %d pores  |  %dx%d",
                                scale, rendered.porosity * 100, rendered.poreCount,
                                rendered.analysedWidth, rendered.analysedHeight),
                overlay: rendered.overlay
            ))
        }

        // Row 2 — Sauvola k at the scale the app actually uses (@3x).
        for sauvolaK in [0.2, 0.35, 0.5] {
            let format = UIGraphicsImageRendererFormat.default()
            format.scale = 3.0
            let cell = UIGraphicsImageRenderer(size: input.displayImage.size, format: format).image { _ in
                input.displayImage.draw(at: .zero)
            }
            let rendered = try Self.stageChainWithOverlay(
                image: cell, crumbROI: crumbROI, bias: 0, sauvolaK: sauvolaK, minPoreArea: 24
            )
            Self.emit(String(
                format: "  k %.2f      ->  analysed %dx%d px, %d pores, %.1f%% porosity",
                sauvolaK, rendered.analysedWidth, rendered.analysedHeight,
                rendered.poreCount, rendered.porosity * 100
            ))
            panels.append(OverlayPanel(
                caption: String(format: "sauvola k=%.2f  |  %.1f%%  |  %d pores", sauvolaK,
                                rendered.porosity * 100, rendered.poreCount),
                overlay: rendered.overlay
            ))
        }

        Self.emit("  montage -> \(Self.montagePath)")

        let montage = Self.composeMontage(panels: panels, columns: 3)
        if let png = montage.pngData() {
            try png.write(to: URL(fileURLWithPath: Self.montagePath))
        } else {
            XCTFail("could not encode montage")
        }
    }

    private static func stageChainWithOverlay(
        image: UIImage,
        crumbROI: CGRect,
        bias: Int,
        sauvolaK: Double,
        minPoreArea: Int
    ) throws -> (overlay: UIImage, porosity: Double, poreCount: Int, analysedWidth: Int, analysedHeight: Int) {
        let analysisInput = try AnalysisImageFactory.makeInput(
            from: image, maxDimension: processingDimension, roiRectNormalized: crumbROI
        )
        let backgroundRemoved = BackgroundRemover.removeBackground(analysisInput.grayscale)
        let normalized = ImagePreprocessor.normalize(backgroundRemoved)

        var parameters = AnalysisParameters()
        parameters.thresholdMode = .adaptive
        parameters.thresholdBias = bias
        parameters.sauvolaK = sauvolaK
        parameters.morphologyKernelSize = 5
        parameters.minPoreArea = minPoreArea

        let segmented = Thresholding.segment(normalized, parameters: parameters)
        let cleaned = BinaryMorphology.clean(segmented, kernelSize: parameters.morphologyKernelSize)
        let refined = PoreRegionRefiner.growAndFill(
            seedMask: cleaned, sourceImage: normalized, kernelSize: parameters.morphologyKernelSize
        )
        let components = ConnectedComponents.filter(
            mask: refined, minimumArea: minPoreArea, maximumArea: nil,
            sourceImage: normalized, minimumLocalContrast: 0
        )

        return (
            try MaskRenderer.makeOverlayImage(
                baseImage: analysisInput.displayImage, mask: components.filteredMask
            ),
            Double(components.filteredMask.porePixelCount) / Double(components.filteredMask.pixelCount),
            components.poreCount,
            components.filteredMask.width,
            components.filteredMask.height
        )
    }

    /// Fixed-width panels with a caption strip, laid out in a grid.
    private static func composeMontage(panels: [OverlayPanel], columns: Int) -> UIImage {
        let panelWidth: CGFloat = 420
        let captionHeight: CGFloat = 26
        let gap: CGFloat = 14
        let rowCount = Int(ceil(Double(panels.count) / Double(columns)))
        let panelHeight = panelWidth
        let canvasWidth = CGFloat(columns) * panelWidth + CGFloat(columns + 1) * gap
        let canvasHeight = CGFloat(rowCount) * (panelHeight + captionHeight) + CGFloat(rowCount + 1) * gap

        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: canvasWidth, height: canvasHeight), format: format).image { context in
            UIColor(white: 0.09, alpha: 1).setFill()
            context.fill(CGRect(x: 0, y: 0, width: canvasWidth, height: canvasHeight))

            for (index, panel) in panels.enumerated() {
                let row = index / columns
                let column = index % columns
                let originX = gap + CGFloat(column) * (panelWidth + gap)
                let originY = gap + CGFloat(row) * (panelHeight + captionHeight + gap)

                let captionRect = CGRect(x: originX, y: originY, width: panelWidth, height: captionHeight)
                (panel.caption as NSString).draw(
                    in: captionRect,
                    withAttributes: [
                        .font: UIFont.monospacedSystemFont(ofSize: 13, weight: .semibold),
                        .foregroundColor: UIColor.white
                    ]
                )

                let imageRect = CGRect(
                    x: originX, y: originY + captionHeight,
                    width: panelWidth, height: panelHeight
                )
                panel.overlay.draw(in: imageRect)
            }
        }
    }

    private static let slicePath = "/tmp/bread_slice.png"
    private static let montagePath = "/tmp/bread_comparison.png"

    /// Every cell of the real grid as the app renders it, labelled, so the outlier cells
    /// can be compared against their neighbours rather than reasoned about from numbers.
    func testRealPhotoCellMontage() async throws {
        guard let image = UIImage(contentsOfFile: Self.realPhotoPath) else {
            Self.emit("  !! could not read \(Self.realPhotoPath)")
            XCTFail("missing real photo")
            return
        }

        let result = try await BreadAnalyzer().analyzeGrid(
            image: image, gridSpec: GridSpec(rows: 4, columns: 6)
        )

        let mean = result.allResults.map(\.analysisResult.porosity).reduce(0, +)
            / Double(max(1, result.allResults.count))
        let region = result.gridRegionNormalized

        Self.emit("")
        Self.emit("=== Cell montage (real 4x6 photo) ===")
        Self.emit(String(
            format: "  grid region origin (%.3f, %.3f)  size %.3f x %.3f   mean porosity %.1f%%",
            region.origin.x, region.origin.y, region.width, region.height, mean * 100
        ))
        Self.emit("  cell    porosity    pores   avgArea    areaCV   crumbROI   crumbROI x,y,w,h")

        var panels: [OverlayPanel] = []
        for cell in result.allResults {
            let roi = cell.crumbROINormalized
            let marker = abs(cell.analysisResult.porosity - mean) > 0.03 ? "  <-- outlier" : ""
            Self.emit(String(
                format: "  %@    %8.1f%%  %6d   %7.1f   %6.2f   %8d   %.2f,%.2f,%.2f,%.2f%@",
                cell.cellIndex.label, cell.analysisResult.porosity * 100,
                cell.analysisResult.poreCount, cell.analysisResult.averagePoreArea,
                cell.analysisResult.poreAreaCV, cell.crumbROIArea,
                roi.origin.x, roi.origin.y, roi.width, roi.height, marker
            ))
            panels.append(OverlayPanel(
                caption: String(
                    format: "%@  %.1f%%  %dp  cv%.2f",
                    cell.cellIndex.label, cell.analysisResult.porosity * 100,
                    cell.analysisResult.poreCount, cell.analysisResult.poreAreaCV
                ),
                overlay: cell.analysisResult.overlayImage
            ))
        }

        let montage = Self.composeMontage(panels: panels, columns: 6)
        if let png = montage.pngData() {
            try png.write(to: URL(fileURLWithPath: "/tmp/bread_cells.png"))
            Self.emit("  montage -> /tmp/bread_cells.png")
        }
    }

    /// What does the crust gate itself measure, cell by cell?
    ///
    /// ROI coverage cannot separate "there is a crust ring" from "there is not": a macro
    /// close-up and a whole-slice-fills-its-cell both report ~100%, and they need
    /// opposite treatment. The ring the trim removes is crust, which is *darker* than
    /// crumb — but the raw band-versus-interior difference also carries the frame's
    /// smooth illumination and whatever the band crosses besides bread. This reports what
    /// the gate actually reports: the illumination the interior predicts for the band,
    /// and the step left over after subtracting it, for every cell of a real grid and
    /// for the two close-ups. It is the gate's own measure, so it cannot describe a
    /// different decision than the app makes.
    func testCrustBandContrast() async throws {
        Self.emit("")
        Self.emit("=== Crust band step vs its predicted illumination (grey levels) ===")
        Self.emit("  step = predicted - band; positive = the band is a step darker, i.e. a crust ring")

        func report(_ grayscale: GrayscaleImage, label: String) {
            guard let slice = GridSlicer.detectSlice(in: grayscale) else {
                Self.emit(String(format: "  %-34@  no slice detected", label as NSString))
                return
            }
            guard let measured = GridSlicer.crustBandMeasurement(for: slice, in: grayscale) else {
                Self.emit(String(format: "  %-34@  nothing to measure", label as NSString))
                return
            }
            Self.emit(String(
                format: "  %-34@  roi %.2f x %.2f  interior %5.1f  band %5.1f  predicted %5.1f  step %+6.1f  -> %@",
                label as NSString,
                slice.roi.width, slice.roi.height,
                measured.interiorMean, measured.bandMean, measured.bandPredictedFromInterior,
                measured.crustStep, measured.holdsCrustRing ? "trim" : "keep"
            ))
        }

        if let photo = UIImage(contentsOfFile: Self.realPhotoPath) {
            let input = try AnalysisImageFactory.makeInput(from: photo, maxDimension: Self.processingDimension)
            let frame = input.grayscale
            let region = (GridSlicer.detectGridContentROI(in: frame)
                ?? CGRect(x: 0, y: 0, width: 1, height: 1)).clampedToUnit(minSize: 0.05)
            let cells = try GridSlicer.sliceCells(
                imageWidth: frame.width, imageHeight: frame.height,
                gridSpec: GridSpec(rows: 4, columns: 6), boundsNormalized: region
            )
            for row in 0..<4 {
                for column in 0..<6 {
                    let cell = cells[row][column]
                    report(
                        frame.cropped(to: cell.pixelRect),
                        label: "grid cell \(cell.cellIndex.label)\(cell.cellIndex.label == "R3C3" ? " (broke)" : "")"
                    )
                }
            }
        }

        for (label, path) in [("close-up A", "/tmp/bread_closeup_a.png"),
                              ("close-up B", "/tmp/bread_closeup_b.jpg")] {
            guard let image = UIImage(contentsOfFile: path) else { continue }
            let input = try AnalysisImageFactory.makeInput(from: image, maxDimension: Self.processingDimension)
            report(input.grayscale, label: label)
        }
    }

    /// Is an outlier the bread, or the detector?
    ///
    /// For each cell this compares the app's porosity against a deliberately independent
    /// estimate: the fraction of crumb-ROI pixels more than one standard deviation below
    /// the local mean, computed straight from the pixels with none of the pipeline's
    /// machinery. If the two agree across all 24 cells the outliers are real crumb
    /// variation; if a cell disagrees, the pipeline is misreading it.
    func testOutlierCrossCheck() async throws {
        guard let image = UIImage(contentsOfFile: Self.realPhotoPath) else {
            XCTFail("missing real photo")
            return
        }

        let input = try AnalysisImageFactory.makeInput(from: image, maxDimension: Self.processingDimension)
        let frame = input.grayscale
        let region = (GridSlicer.detectGridContentROI(in: frame)
            ?? CGRect(x: 0, y: 0, width: 1, height: 1)).clampedToUnit(minSize: 0.05)
        let cells = try GridSlicer.sliceCells(
            imageWidth: frame.width, imageHeight: frame.height,
            gridSpec: GridSpec(rows: 4, columns: 6), boundsNormalized: region
        )

        let result = try await BreadAnalyzer().analyzeGrid(
            image: image, gridSpec: GridSpec(rows: 4, columns: 6)
        )

        Self.emit("")
        Self.emit("=== Outlier cross-check: app porosity vs an independent dark-fraction ===")
        Self.emit("  cell    app %    dark-frac %    delta")

        var pairs: [(app: Double, independent: Double)] = []
        for cell in result.allResults {
            let region = cells[cell.cellIndex.row][cell.cellIndex.column]
            let cellGrayscale = frame.cropped(to: region.pixelRect)
            let roi = cell.crumbROINormalized
                .denormalized(in: CGRect(x: 0, y: 0, width: cellGrayscale.width, height: cellGrayscale.height))
                .integral
                .intersection(CGRect(x: 0, y: 0, width: cellGrayscale.width, height: cellGrayscale.height))
            guard roi.width > 4, roi.height > 4 else { continue }

            var values: [UInt8] = []
            var sum = 0.0
            for y in Int(roi.minY)..<Int(roi.maxY) {
                for x in Int(roi.minX)..<Int(roi.maxX) {
                    let value = cellGrayscale[x, y]
                    values.append(value)
                    sum += Double(value)
                }
            }
            let mean = sum / Double(values.count)
            let variance = values.reduce(0.0) { $0 + (Double($1) - mean) * (Double($1) - mean) }
                / Double(values.count)
            let standardDeviation = variance.squareRoot()
            let darkCount = values.filter { Double($0) < mean - standardDeviation }.count
            let darkFraction = Double(darkCount) / Double(values.count)

            let app = cell.analysisResult.porosity
            pairs.append((app, darkFraction))
            let marker = abs(app - darkFraction) > 0.05 ? "  <-- disagreement" : ""
            Self.emit(String(
                format: "  %@    %6.1f      %6.1f       %+6.1f%@",
                cell.cellIndex.label, app * 100, darkFraction * 100,
                (app - darkFraction) * 100, marker
            ))
        }

        // Rank agreement: do the two orderings of the 24 cells match?
        let appRanks = Self.ranks(pairs.map(\.app))
        let independentRanks = Self.ranks(pairs.map(\.independent))
        let n = Double(pairs.count)
        let meanRank = (n + 1) / 2
        var covariance = 0.0, appVariance = 0.0, independentVariance = 0.0
        for index in pairs.indices {
            let a = appRanks[index] - meanRank
            let b = independentRanks[index] - meanRank
            covariance += a * b
            appVariance += a * a
            independentVariance += b * b
        }
        let correlation = covariance / max(.ulpOfOne, (appVariance * independentVariance).squareRoot())
        Self.emit(String(format: "  rank correlation over %d cells: %.3f", pairs.count, correlation))
    }

    private static func ranks(_ values: [Double]) -> [Double] {
        let order = values.indices.sorted { values[$0] < values[$1] }
        var ranks = [Double](repeating: 0, count: values.count)
        for (position, index) in order.enumerated() {
            ranks[index] = Double(position + 1)
        }
        return ranks
    }

    /// R1C5's overlay shows a straight full-height band along its ROI's right edge — not
    /// something bread can produce. This walks that cell's stages and writes each one out,
    /// so the stage the band appears in is visible rather than inferred.
    func testOutlierCellStageTrace() async throws {
        guard let image = UIImage(contentsOfFile: Self.realPhotoPath) else { return }
        let input = try AnalysisImageFactory.makeInput(from: image, maxDimension: Self.processingDimension)
        let frame = input.grayscale
        let region = (GridSlicer.detectGridContentROI(in: frame)
            ?? CGRect(x: 0, y: 0, width: 1, height: 1)).clampedToUnit(minSize: 0.05)
        let cells = try GridSlicer.sliceCells(
            imageWidth: frame.width, imageHeight: frame.height,
            gridSpec: GridSpec(rows: 4, columns: 6), boundsNormalized: region
        )
        let result = try await BreadAnalyzer().analyzeGrid(
            image: image, gridSpec: GridSpec(rows: 4, columns: 6)
        )

        Self.emit("")
        Self.emit("=== Stage trace per cell (density at each stage) ===")
        Self.emit("  cell   bgCover   afterThreshold   afterMorph   afterRefine   final   app%")

        var panels: [OverlayPanel] = []
        for cell in result.allResults {
            let region = cells[cell.cellIndex.row][cell.cellIndex.column]
            let cellGrayscale = frame.cropped(to: region.pixelRect)
            let cellBounds = CGRect(x: 0, y: 0, width: cellGrayscale.width, height: cellGrayscale.height)
            let crumbRect = cell.crumbROINormalized.denormalized(in: cellBounds).integral.intersection(cellBounds)
            guard crumbRect.width > 8, crumbRect.height > 8 else { continue }
            let crumb = cellGrayscale.cropped(to: crumbRect)

            func density(_ mask: BinaryMask) -> Double {
                Double(mask.porePixelCount) / Double(mask.pixelCount) * 100
            }

            let backgroundMask = BackgroundRemover.detectBackground(crumb)
            let bgCoverage = Double(backgroundMask.reduce(0) { $0 + Int($1) }) / Double(crumb.pixelCount) * 100

            let backgroundRemoved = BackgroundRemover.removeBackground(crumb)
            let normalized = ImagePreprocessor.normalize(backgroundRemoved)

            var parameters = AnalysisParameters()
            parameters.thresholdMode = .adaptive
            parameters.morphologyKernelSize = 5
            parameters.minPoreArea = 24

            let segmented = Thresholding.segment(normalized, parameters: parameters)
            let cleaned = BinaryMorphology.clean(segmented, kernelSize: parameters.morphologyKernelSize)
            let refined = PoreRegionRefiner.growAndFill(
                seedMask: cleaned, sourceImage: normalized, kernelSize: parameters.morphologyKernelSize
            )
            let components = ConnectedComponents.filter(
                mask: refined, minimumArea: parameters.minPoreArea, maximumArea: nil,
                sourceImage: normalized, minimumLocalContrast: 0
            )

            let appPorosity = cell.analysisResult.porosity * 100
            let marker = abs(appPorosity - 8.0) > 2.0 ? "  <-- outlier" : ""
            Self.emit(String(
                format: "  %@   %6.1f%%   %6.1f%%   %6.1f%%   %6.1f%%   %6.1f%%   %5.1f%%%@",
                cell.cellIndex.label, bgCoverage,
                density(segmented), density(cleaned), density(refined),
                density(components.filteredMask), appPorosity, marker
            ))

            if cell.cellIndex.label == "R1C5" || cell.cellIndex.label == "R3C4" {
                for (name, mask) in [("threshold", segmented), ("final", components.filteredMask)] {
                    if let rendered = try? MaskRenderer.makeMaskImage(from: mask) {
                        panels.append(OverlayPanel(
                            caption: "\(cell.cellIndex.label) \(name)  \(String(format: "%.1f%%", density(mask)))",
                            overlay: rendered
                        ))
                    }
                }
            }
        }

        if !panels.isEmpty {
            let montage = Self.composeMontage(panels: panels, columns: 2)
            if let png = montage.pngData() {
                try png.write(to: URL(fileURLWithPath: "/tmp/bread_outlier_trace.png"))
                Self.emit("  montage -> /tmp/bread_outlier_trace.png")
            }
        }
    }

    private static let realPhotoPath = "/tmp/bread_real_photo.jpg"

    private static func loadRealPhoto() -> UIImage? {
        guard let image = UIImage(contentsOfFile: realPhotoPath) else {
            emit("  !! could not read \(realPhotoPath)")
            XCTFail("Real photo not readable at \(realPhotoPath)")
            return nil
        }
        return image
    }

    // MARK: - Reporting helpers

    private static func emit(_ line: String) {
        reportLines.append(line)
    }

    private static func flushReport() {
        let text = reportLines.joined(separator: "\n") + "\n"
        try? text.write(toFile: reportPath, atomically: true, encoding: .utf8)
    }

    /// Warm-up run, then `iterations` timed runs. Reports the best (least disturbed
    /// by external interference) alongside the mean.
    private static func report(
        _ label: String,
        iterations: Int = 3,
        _ block: () throws -> Void
    ) rethrows {
        try block()

        var samples: [Double] = []
        for _ in 0..<iterations {
            let start = CFAbsoluteTimeGetCurrent()
            try block()
            samples.append(CFAbsoluteTimeGetCurrent() - start)
        }

        let best = samples.min() ?? 0
        let mean = samples.reduce(0, +) / Double(samples.count)
        let padded = label.padding(toLength: 38, withPad: " ", startingAt: 0)
        emit(String(format: "  %@ best %7.3fs  mean %7.3fs", padded, best, mean))
    }
}

// MARK: - Deterministic synthetic imagery

extension PerformanceBenchmarkTests {
    /// Builds a photo of `rows × columns` bread slices on a dark background, with a
    /// `margin` of background around the slices. Passing 1×1 yields a single slice.
    ///
    /// The texture matters: the existing tests use flat colour plus one ellipse,
    /// which yields a single connected component and therefore times none of the
    /// per-component work that dominates a real crumb.
    fileprivate static func makePhoto(
        rows: Int,
        columns: Int,
        width: Int,
        height: Int,
        margin: Int,
        poreDensity: Double,
        seed: UInt64
    ) -> UIImage {
        let gap = max(16, margin / columns)
        let usableWidth = width - 2 * margin - (columns - 1) * gap
        let usableHeight = height - 2 * margin - (rows - 1) * gap
        let sliceWidth = max(8, usableWidth / columns)
        let sliceHeight = max(8, usableHeight / rows)

        var rng = SeededGenerator(seed: seed)
        var pixels = [UInt8](repeating: 0, count: width * height * 4)

        // Dark background (a bench/tray).
        for index in 0..<(width * height) {
            let value = UInt8(30 + Int(rng.next() % 12))
            let base = index * 4
            pixels[base] = value
            pixels[base + 1] = value
            pixels[base + 2] = value
            pixels[base + 3] = 255
        }

        // Crumb: bright base with per-pixel grain.
        var sliceRects: [CGRect] = []
        for row in 0..<rows {
            for column in 0..<columns {
                let x = margin + column * (sliceWidth + gap)
                let y = margin + row * (sliceHeight + gap)
                guard x + sliceWidth <= width, y + sliceHeight <= height else { continue }
                sliceRects.append(CGRect(x: x, y: y, width: sliceWidth, height: sliceHeight))

                for py in y..<(y + sliceHeight) {
                    for px in x..<(x + sliceWidth) {
                        let base = ((py * width) + px) * 4
                        let grain = Int(rng.next() % 22) - 11
                        let value = UInt8(clamping: 208 + grain)
                        pixels[base] = value
                        pixels[base + 1] = value
                        pixels[base + 2] = value
                        pixels[base + 3] = 255
                    }
                }
            }
        }

        // Pores: dark ellipses. A real crumb has dozens to low hundreds per slice;
        // the density here is roughly 1 per 900 px at poreDensity 1.0.
        for rect in sliceRects {
            let poreCount = Int(Double(Int(rect.width * rect.height) / 900) * poreDensity)
            for _ in 0..<poreCount {
                let radiusX = 2.0 + Double(rng.next() % 9)
                let radiusY = 2.0 + Double(rng.next() % 9)
                let spanX = UInt64(max(1, Int(rect.width - 2 * radiusX)))
                let spanY = UInt64(max(1, Int(rect.height - 2 * radiusY)))
                let centerX = rect.minX + radiusX + Double(rng.next() % spanX)
                let centerY = rect.minY + radiusY + Double(rng.next() % spanY)
                let depth = 90.0 + Double(rng.next() % 80)

                let minX = max(0, Int(centerX - radiusX))
                let maxX = min(width - 1, Int(centerX + radiusX))
                let minY = max(0, Int(centerY - radiusY))
                let maxY = min(height - 1, Int(centerY + radiusY))
                guard minX <= maxX, minY <= maxY else { continue }

                for py in minY...maxY {
                    for px in minX...maxX {
                        let dx = (Double(px) - centerX) / radiusX
                        let dy = (Double(py) - centerY) / radiusY
                        let distance = dx * dx + dy * dy
                        guard distance <= 1 else { continue }

                        // Soft edge so thresholding sees a gradient, not a hard step.
                        let darkening = depth * min(1, (1 - distance) * 2.2)
                        let base = ((py * width) + px) * 4
                        let value = UInt8(clamping: max(0, Int(Double(pixels[base]) - darkening)))
                        pixels[base] = value
                        pixels[base + 1] = value
                        pixels[base + 2] = value
                    }
                }
            }
        }

        // Uneven lighting: smooth radial falloff, so `ImagePreprocessor.normalize`
        // has genuine low-frequency structure to correct.
        let centerX = Double(width) / 2
        let centerY = Double(height) / 2
        let maxDistance = (centerX * centerX + centerY * centerY).squareRoot()
        for py in 0..<height {
            for px in 0..<width {
                let dx = Double(px) - centerX
                let dy = Double(py) - centerY
                let normalizedDistance = (dx * dx + dy * dy).squareRoot() / maxDistance
                let gain = 1.0 - (0.30 * normalizedDistance * normalizedDistance)
                let base = ((py * width) + px) * 4
                for channel in 0..<3 {
                    pixels[base + channel] = UInt8(clamping: Int(Double(pixels[base + channel]) * gain))
                }
            }
        }

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        let provider = CGDataProvider(data: Data(pixels) as CFData)!
        let cgImage = CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGBitmapInfo(rawValue: bitmapInfo),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )!

        return UIImage(cgImage: cgImage, scale: 1, orientation: .up)
    }
}

// SeededGenerator now lives in PhantomFactory.swift, shared with MeasurementQualityTests.
