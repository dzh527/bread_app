import UIKit
import XCTest
@testable import BreadPorosity

/// Controls that decide whether the porosity number is a measurement at all.
///
/// These answer questions the existing suite cannot: the 36 existing tests all exercise
/// `.otsu`, so the `.adaptive` path — the default, and what grid analysis actually runs —
/// has no coverage whatsoever. Passing them is not evidence about this.
///
/// Run with:
///
///     xcodebuild test ... -only-testing:BreadPorosityTests/MeasurementQualityTests
///
/// The report lands at `/tmp/bread_quality_report.txt`.
final class MeasurementQualityTests: XCTestCase {
    private let report = QualityReport()
    private let reportPath = "/tmp/bread_quality_report.txt"
    /// Small enough to stay under `maxProcessingDimension`, so nothing is resampled.
    private let phantomSide = 600

    override func tearDown() {
        super.tearDown()
        report.flush(to: reportPath)
    }

    // MARK: - Control 1: can it separate clearly different breads?

    /// Phantoms whose true porosity differs by a lot, with the *same* pore-size
    /// distribution. If these do not come back clearly ordered and separated, the
    /// instrument cannot measure bread and nothing downstream is worth fixing.
    func testDynamicRangeControl() async throws {
        report.emit("")
        report.emit("=== Control 1: dynamic range (same pore-size distribution) ===")
        report.emit("  true %    measured %    error (pp)    pores")

        for target in [0.05, 0.10, 0.20] {
            let phantom = PhantomFactory.make(
                width: phantomSide, height: phantomSide,
                targetPorosity: target,
                poreRadius: 4...14,
                seed: 0xD1CE
            )
            let measured = try await measure(phantom, sauvolaK: 0.34)
            report.emit(String(
                format: "  %6.2f    %9.2f    %+9.2f    %6d",
                phantom.truePorosity * 100,
                measured.porosity * 100,
                (measured.porosity - phantom.truePorosity) * 100,
                measured.poreCount
            ))
        }
    }

    // MARK: - Control 2: is the answer pinned by the parameter?

    /// One phantom, fixed truth, swept over `k`. A well-posed segmentation has a window
    /// of `k` where the answer does not move; that window is where you operate, and its
    /// width is the acceptance tolerance for every change made afterwards.
    ///
    /// A smoothly-sliding answer with no plateau means the threshold is cutting through
    /// image noise rather than crumb structure, and the reported number is a function of
    /// the parameter rather than of the bread.
    func testSauvolaKPlateau() async throws {
        let truth = 0.10
        let phantom = PhantomFactory.make(
            width: phantomSide, height: phantomSide,
            targetPorosity: truth,
            poreRadius: 4...14,
            seed: 0x9A7E
        )
        report.emit("")
        report.emit("=== Control 2: k-plateau (true porosity \(String(format: "%.2f", phantom.truePorosity * 100))%) ===")
        report.emit("  \(phantom.note)")
        report.emit("     k      measured %    vs truth (pp)")

        var sweep: [(k: Double, porosity: Double)] = []
        for step in 0...17 {
            let k = 0.05 + Double(step) * 0.05
            let measured = try await measure(phantom, sauvolaK: k)
            sweep.append((k, measured.porosity))
            report.emit(String(
                format: "  %5.2f    %9.2f    %+11.2f",
                k, measured.porosity * 100, (measured.porosity - phantom.truePorosity) * 100
            ))
        }

        // Plateau width: the widest contiguous run of k whose readings stay within
        // one percentage point of each other.
        let tolerance = 0.01
        var bestRun = 0
        var bestStart = 0
        var start = 0
        for index in sweep.indices {
            if index == 0 { start = 0; continue }
            let span = abs(sweep[index].porosity - sweep[start].porosity)
            if span > tolerance {
                if index - start > bestRun {
                    bestRun = index - start
                    bestStart = start
                }
                start = index
            }
        }
        if sweep.count - start > bestRun {
            bestRun = sweep.count - start
            bestStart = start
        }

        let lo = sweep[bestStart].k
        let hi = sweep[min(sweep.count - 1, bestStart + bestRun - 1)].k
        report.emit(String(
            format: "  -> widest plateau within 1pp: k %.2f…%.2f  (width %.2f, %d points)",
            lo, hi, hi - lo, bestRun
        ))
        report.emit(String(
            format: "  -> full sweep spans %.1fpp of reported porosity",
            ((sweep.map(\.porosity).max() ?? 0) - (sweep.map(\.porosity).min() ?? 0)) * 100
        ))
    }

    // MARK: - Control 3: does the bias move with crumb structure?

    /// Equal *true* pore area, realised as many small holes versus few large ones.
    ///
    /// This is the control that matters most for this application: an improver's job is
    /// to change crumb structure, so any bias that tracks pore size is confounded with
    /// the treatment effect, and — unlike lighting or camera effects — it does not
    /// cancel when comparing columns within one photo.
    func testStructureBiasControl() async throws {
        let truth = 0.10
        report.emit("")
        report.emit("=== Control 3: structure bias (equal true area, different pore sizes) ===")
        report.emit("  pore radius    true %    measured %    error (pp)    pores")

        for radius in [3.0...6.0, 6.0...10.0, 10.0...18.0] {
            let phantom = PhantomFactory.make(
                width: phantomSide, height: phantomSide,
                targetPorosity: truth,
                poreRadius: radius,
                seed: 0x571C
            )
            let measured = try await measure(phantom, sauvolaK: 0.34)
            report.emit(String(
                format: "  %4.0f-%-4.0f    %6.2f    %9.2f    %+9.2f    %6d",
                radius.lowerBound, radius.upperBound,
                phantom.truePorosity * 100,
                measured.porosity * 100,
                (measured.porosity - phantom.truePorosity) * 100,
                measured.poreCount
            ))
        }
    }

    // MARK: - Running a phantom through the production pipeline

    private struct Measurement {
        let porosity: Double
        let poreCount: Int
    }

    /// Drives a phantom through the real `BreadAnalyzer.analyze` stage chain with
    /// `roiMode: .fullImage`, so the analysed region is exactly the phantom and the
    /// ground truth is exact. (The grid path adds slice-ROI detection and crust
    /// trimming on top; those are out of scope here and would only blur the answer
    /// key, since the pipeline does not report which rect it settled on.)
    /// Same phantoms, threshold mode varied and everything else held. The pipeline
    /// flat-fields the illumination *and* applies a local threshold; if flat-fielding has
    /// already removed the low-frequency lighting, the local threshold has nothing left
    /// to correct and can only hurt.
    func testThresholdModeComparison() async throws {
        report.emit("")
        report.emit("=== Control 4: global (Otsu) vs adaptive, same phantoms ===")
        report.emit("  phantom                     truth %   otsu %   adaptive %")

        let cases: [(String, Double, ClosedRange<Double>)] = [
            ("porosity  5%, r 4-14", 0.05, 4...14),
            ("porosity 10%, r 4-14", 0.10, 4...14),
            ("porosity 20%, r 4-14", 0.20, 4...14),
            ("porosity 10%, r  3-6", 0.10, 3...6),
            ("porosity 10%, r  6-10", 0.10, 6...10),
            ("porosity 10%, r 10-18", 0.10, 10...18)
        ]

        for (label, target, radius) in cases {
            let phantom = PhantomFactory.make(
                width: phantomSide, height: phantomSide,
                targetPorosity: target, poreRadius: radius, seed: 0x0E51
            )
            let otsu = try await measure(phantom, sauvolaK: 0.34, mode: .otsu)
            let adaptive = try await measure(phantom, sauvolaK: 0.34, mode: .adaptive)
            report.emit(String(
                format: "  %-24@  %6.2f    %6.2f     %6.2f",
                label as NSString, phantom.truePorosity * 100,
                otsu.porosity * 100, adaptive.porosity * 100
            ))
        }
    }

    /// Macro close-ups of crumb: no crust, no background, the slice fills the frame.
    /// That is the opposite input from a grid photo, and it exercises different paths —
    /// slice-ROI detection and the crust trim have nothing to find, and the frame is
    /// small enough that the working resolution matters.
    func testCloseUpCrumbImages() async throws {
        report.emit("")
        report.emit("=== Close-up crumb images ===")

        let cases: [(String, String)] = [
            ("A  790x528 macro", "/tmp/bread_closeup_a.png"),
            ("B  259x194 tiny", "/tmp/bread_closeup_b.jpg")
        ]

        for (label, path) in cases {
            guard let image = UIImage(contentsOfFile: path) else {
                report.emit("  \(label): could not read \(path)")
                continue
            }
            report.emit("")
            report.emit("  \(label)  native \(Int(image.size.width))x\(Int(image.size.height))")

            // 1. Pure measurement, no ROI detection and no crust trim.
            do {
                var parameters = AnalysisParameters()
                parameters.thresholdMode = .adaptive
                parameters.sauvolaK = 0.34
                parameters.morphologyKernelSize = 3
                parameters.minPoreArea = 24
                parameters.roiMode = .fullImage
                let result = try await BreadAnalyzer().analyze(image: image, parameters: parameters)
                report.emit(String(
                    format: "     analyze(fullImage)     porosity %6.2f%%   pores %5d   avgArea %7.1f",
                    result.porosity * 100, result.poreCount, result.averagePoreArea
                ))
            } catch {
                report.emit("     analyze(fullImage)     FAILED: \(error.localizedDescription)")
            }

            // 2. What the app's "Single Slice" button does: 1x1 grid, so slice-ROI
            //    detection and the 11% crust trim both run on an image with no crust.
            do {
                let result = try await BreadAnalyzer().analyzeGrid(
                    image: image, gridSpec: GridSpec(rows: 1, columns: 1)
                )
                let cell = result.allResults.first
                report.emit(String(
                    format: "     analyzeGrid(1x1)       porosity %6.2f%%   pores %5d   crumbROI %.0f%% x %.0f%%",
                    (cell?.analysisResult.porosity ?? 0) * 100,
                    cell?.analysisResult.poreCount ?? 0,
                    (cell?.crumbROINormalized.width ?? 0) * 100,
                    (cell?.crumbROINormalized.height ?? 0) * 100
                ))
            } catch {
                report.emit("     analyzeGrid(1x1)       FAILED: \(error.localizedDescription)")
            }

            // 3. What happens if the user simply hits Analyze with the default 4x6.
            do {
                let result = try await BreadAnalyzer().analyzeGrid(
                    image: image, gridSpec: GridSpec(rows: 4, columns: 6)
                )
                let porosities = result.allResults.map(\.analysisResult.porosity)
                let mean = porosities.reduce(0, +) / Double(max(1, porosities.count))
                report.emit(String(
                    format: "     analyzeGrid(4x6)       mean %6.2f%%   %d of 24 cells produced a result",
                    mean * 100, result.allResults.count
                ))
            } catch {
                report.emit("     analyzeGrid(4x6)       FAILED: \(error.localizedDescription)")
            }
        }
    }

    /// How much of each kind of image does `detectBackground` claim as background?
    ///
    /// This is the evidence for `BackgroundRemover.maximumBackgroundCoverage`. A genuine
    /// surround should be a partial fraction; if the number is near 1.0 the detector has
    /// selected the bread instead, and the guard must fire.
    func testBackgroundCoverageDiagnostic() throws {
        report.emit("")
        report.emit("=== Background coverage by input kind ===")
        report.emit("  image                                  coverage   verdict")

        /// Reports the fraction of the frame the detector *overwrote*. Zero means
        /// nothing was filled — either because no background was found, or because the
        /// degeneracy guard fired. Both are correct for an image with no background.
        func reportCoverage(_ grayscale: GrayscaleImage, label: String) {
            let mask = BackgroundRemover.detectBackground(grayscale)
            let covered = mask.reduce(0) { $0 + Int($1) }
            let coverage = Double(covered) / Double(grayscale.pixelCount)
            let verdict = covered == 0 ? "nothing overwritten" : "overwrote this fraction"
            report.emit(String(format: "  %-38@ %8.3f   %@", label as NSString, coverage, verdict as NSString))
        }

        for (label, target, radius) in [
            ("phantom 10%, r 6-10 (the traced one)", 0.10, 6.0...10.0),
            ("phantom 20%, r 4-14 (still failing)", 0.20, 4.0...14.0),
            ("phantom 10%, r  3-6 (still failing)", 0.10, 3.0...6.0)
        ] as [(String, Double, ClosedRange<Double>)] {
            let phantom = PhantomFactory.make(
                width: phantomSide, height: phantomSide,
                targetPorosity: target, poreRadius: radius, seed: 0x0E51
            )
            let input = try AnalysisImageFactory.makeInput(from: phantom.image, maxDimension: 1400)
            reportCoverage(input.grayscale, label: label)
        }
        report.emit("")

        if let slice = UIImage(contentsOfFile: "/tmp/bread_slice.png") {
            let sliceInput = try AnalysisImageFactory.makeInput(from: slice, maxDimension: 1400)
            reportCoverage(sliceInput.grayscale, label: "real slice, +crust, full frame")

            let detectedSlice = GridSlicer.detectSlice(in: sliceInput.grayscale)
            let crumbROI = GridSlicer.crustTrimmedROI(
                from: detectedSlice?.roi,
                sliceMask: detectedSlice?.mask,
                imageWidth: sliceInput.grayscale.width,
                imageHeight: sliceInput.grayscale.height,
                sourceImage: sliceInput.grayscale
            )
            let bounds = CGRect(x: 0, y: 0, width: sliceInput.grayscale.width, height: sliceInput.grayscale.height)
            let crumbRect = crumbROI.clampedToUnit(minSize: 0.05).denormalized(in: bounds).integral
            reportCoverage(
                sliceInput.grayscale.cropped(to: crumbRect),
                label: "real slice, crust-trimmed (what prod feeds)"
            )
        }

        if let photo = UIImage(contentsOfFile: "/tmp/bread_real_photo.jpg") {
            let photoInput = try AnalysisImageFactory.makeInput(from: photo, maxDimension: 1400)
            reportCoverage(photoInput.grayscale, label: "real 4x6 grid photo, full frame")
        }
    }

    /// Where does the pore area go? Walks one phantom through the stage chain and
    /// reports, after each step, how much of the *true* pore area is still recoverable.
    ///
    /// Contrast is `mean(outside pores) - mean(inside pores)` on the grayscale stages; a
    /// collapse there means the pores have been washed out before any threshold sees
    /// them. Recall/precision are measured against the exact truth mask.
    func testStageTraceOnPhantom() throws {
        let phantom = PhantomFactory.make(
            width: phantomSide, height: phantomSide,
            targetPorosity: 0.10, poreRadius: 6...10, seed: 0x0E51
        )
        let input = try AnalysisImageFactory.makeInput(from: phantom.image, maxDimension: 1400)
        let grayscale = input.grayscale
        let truth = phantom.truthMask

        report.emit("")
        report.emit("=== Stage trace (true porosity \(String(format: "%.2f", phantom.truePorosity * 100))%) ===")
        report.emit("  \(phantom.note)")

        func contrast(_ image: GrayscaleImage) -> Double {
            var insideSum = 0.0, insideCount = 0.0
            var outsideSum = 0.0, outsideCount = 0.0
            for index in 0..<image.pixelCount {
                if truth.pixels[index] == 1 {
                    insideSum += Double(image.pixels[index]); insideCount += 1
                } else {
                    outsideSum += Double(image.pixels[index]); outsideCount += 1
                }
            }
            guard insideCount > 0, outsideCount > 0 else { return 0 }
            return (outsideSum / outsideCount) - (insideSum / insideCount)
        }

        func scores(_ mask: BinaryMask) -> (recall: Double, precision: Double) {
            var hit = 0.0, marked = 0.0, truthCount = 0.0
            for index in 0..<mask.pixelCount {
                if truth.pixels[index] == 1 { truthCount += 1 }
                if mask.pixels[index] == 1 {
                    marked += 1
                    if truth.pixels[index] == 1 { hit += 1 }
                }
            }
            return (truthCount > 0 ? hit / truthCount : 0, marked > 0 ? hit / marked : 0)
        }

        report.emit(String(format: "  %-32@  contrast %7.2f", "input grayscale" as NSString, contrast(grayscale)))

        let backgroundRemoved = BackgroundRemover.removeBackground(grayscale)
        report.emit(String(format: "  %-32@  contrast %7.2f", "after BackgroundRemover" as NSString, contrast(backgroundRemoved)))

        let normalized = ImagePreprocessor.normalize(backgroundRemoved)
        report.emit(String(format: "  %-32@  contrast %7.2f", "after normalize + stretch" as NSString, contrast(normalized)))

        /// Runs the remainder of the chain from a preprocessed image and reports the
        /// recall/precision of the final mask against truth.
        func runChain(from source: GrayscaleImage, label: String) {
            var parameters = AnalysisParameters()
            parameters.thresholdMode = .adaptive
            parameters.sauvolaK = 0.34
            parameters.morphologyKernelSize = 3
            parameters.minPoreArea = 24

            let segmented = Thresholding.segment(source, parameters: parameters)
            let cleaned = BinaryMorphology.clean(segmented, kernelSize: parameters.morphologyKernelSize)
            let refined = PoreRegionRefiner.growAndFill(
                seedMask: cleaned, sourceImage: source, kernelSize: parameters.morphologyKernelSize
            )
            let components = ConnectedComponents.filter(
                mask: refined, minimumArea: parameters.minPoreArea, maximumArea: nil,
                sourceImage: source, minimumLocalContrast: 0
            )
            let final = scores(components.filteredMask)
            report.emit(String(
                format: "  %-32@  recall %.3f  precision %.3f  (threshold recall %.3f)",
                label as NSString, final.recall, final.precision, scores(segmented).recall
            ))
        }

        report.emit("")
        report.emit("  -- with BackgroundRemover (what production does) --")
        runChain(from: normalized, label: "full chain")

        // The same chain with that one stage removed. BackgroundRemover is given an
        // image containing no background at all whenever the grid path has already
        // crust-trimmed the cell, so this isolates its effect.
        report.emit("  -- with BackgroundRemover removed --")
        let normalizedWithout = ImagePreprocessor.normalize(grayscale)
        report.emit(String(
            format: "  %-32@  contrast %7.2f",
            "normalize + stretch (no bg removal)" as NSString, contrast(normalizedWithout)
        ))
        runChain(from: normalizedWithout, label: "chain without bg removal")
    }

    /// Should `minPoreArea` be an absolute pixel count, or a fraction of the analysed
    /// area? The two models differ by 4x between a 400px and an 800px image, and the
    /// grid path currently calibrates on one resolution while applying to another.
    ///
    /// The same bread is imaged at two resolutions with pore radii scaled to match, then
    /// swept over `minPoreArea`. If the value that recovers the truth is roughly
    /// *constant*, the floor model is right and the derivation just needs the right pixel
    /// count. If it scales with area, the ratio is the real quantity.
    func testMinPoreAreaScaling() async throws {
        report.emit("")
        report.emit("=== How should minPoreArea scale with resolution? ===")
        report.emit("  same bread at two resolutions, pore radii scaled to match")

        let cases: [(side: Int, radius: ClosedRange<Double>)] = [
            (400, 2.5...6.0),
            (800, 5.0...12.0)
        ]

        for (side, radius) in cases {
            let phantom = PhantomFactory.make(
                width: side, height: side, targetPorosity: 0.10, poreRadius: radius, seed: 0x11AA
            )
            report.emit("")
            report.emit(String(
                format: "  %dx%d = %d px   true %.2f%%   pores radius %.1f-%.1f px",
                side, side, side * side, phantom.truePorosity * 100,
                radius.lowerBound, radius.upperBound
            ))
            report.emit("    minArea   measured %    error (pp)   pores")

            for minArea in [4, 8, 16, 24, 48, 96, 192, 384] {
                let measured = try await measure(phantom, sauvolaK: 0.34, minPoreArea: minArea)
                report.emit(String(
                    format: "    %7d    %9.2f    %+9.2f   %6d",
                    minArea, measured.porosity * 100,
                    (measured.porosity - phantom.truePorosity) * 100, measured.poreCount
                ))
            }
        }
    }

    private func measure(
        _ phantom: Phantom,
        sauvolaK: Double,
        mode: ThresholdMode = .adaptive,
        minPoreArea: Int = 24
    ) async throws -> Measurement {
        var parameters = AnalysisParameters()
        parameters.thresholdMode = mode
        parameters.sauvolaK = sauvolaK
        parameters.morphologyKernelSize = 3
        parameters.minPoreArea = minPoreArea
        parameters.roiMode = .fullImage
        parameters.roiRectNormalized = nil

        let analyzer = BreadAnalyzer()
        let result = try await analyzer.analyze(image: phantom.image, parameters: parameters)
        return Measurement(porosity: result.porosity, poreCount: result.poreCount)
    }
}
