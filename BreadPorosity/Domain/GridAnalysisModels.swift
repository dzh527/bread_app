import UIKit

struct GridSpec: Equatable {
    var rows: Int
    var columns: Int

    var cellCount: Int {
        rows * columns
    }

    func isValid(row: Int, column: Int) -> Bool {
        row >= 0 && row < rows && column >= 0 && column < columns
    }
}

struct GridCellIndex: Hashable {
    let row: Int
    let column: Int

    var label: String {
        "R\(row + 1)C\(column + 1)"
    }
}

struct GridCellResult: Identifiable {
    let cellIndex: GridCellIndex
    let cellImage: UIImage
    let analysisResult: BreadAnalysisResult
    let crumbROINormalized: CGRect
    let crumbROIArea: Int

    init(
        cellIndex: GridCellIndex,
        cellImage: UIImage,
        analysisResult: BreadAnalysisResult,
        crumbROINormalized: CGRect = CGRect(x: 0, y: 0, width: 1, height: 1),
        crumbROIArea: Int? = nil
    ) {
        self.cellIndex = cellIndex
        self.cellImage = cellImage
        self.analysisResult = analysisResult
        self.crumbROINormalized = crumbROINormalized
        self.crumbROIArea = crumbROIArea ?? Int((cellImage.size.width * crumbROINormalized.width) * (cellImage.size.height * crumbROINormalized.height))
    }

    var id: GridCellIndex {
        cellIndex
    }

    var crumbROIAreaText: String {
        "\(crumbROIArea) px²"
    }
}

struct ColumnSummary {
    let column: Int
    let meanPorosity: Double
    let stdPorosity: Double
    let sampleCount: Int

    var meanPorosityPercentText: String {
        String(format: "%.1f%%", meanPorosity * 100)
    }

    var stdPorosityPercentText: String {
        String(format: "%.1f%%", stdPorosity * 100)
    }

    var summaryText: String {
        String(format: "%.1f ± %.1f%%", meanPorosity * 100, stdPorosity * 100)
    }
}

struct GridAnalysisResult {
    let gridSpec: GridSpec
    let cellResults: [[GridCellResult?]]
    let columnSummaries: [ColumnSummary]
    let gridRegionNormalized: CGRect

    init(
        gridSpec: GridSpec,
        cellResults: [[GridCellResult?]],
        columnSummaries: [ColumnSummary],
        gridRegionNormalized: CGRect = CGRect(x: 0, y: 0, width: 1, height: 1)
    ) {
        self.gridSpec = gridSpec
        self.cellResults = cellResults
        self.columnSummaries = columnSummaries
        self.gridRegionNormalized = gridRegionNormalized
    }

    func cellResult(row: Int, column: Int) -> GridCellResult? {
        guard gridSpec.isValid(row: row, column: column) else {
            return nil
        }
        return cellResults[row][column]
    }

    var allResults: [GridCellResult] {
        cellResults.flatMap { row in row.compactMap { $0 } }
    }

    static func computeColumnSummaries(
        gridSpec: GridSpec,
        cellResults: [[GridCellResult?]]
    ) -> [ColumnSummary] {
        (0..<gridSpec.columns).map { column in
            let porosities = (0..<gridSpec.rows).compactMap { row in
                cellResults[row][column]?.analysisResult.porosity
            }

            guard !porosities.isEmpty else {
                return ColumnSummary(column: column, meanPorosity: 0, stdPorosity: 0, sampleCount: 0)
            }

            let mean = porosities.reduce(0, +) / Double(porosities.count)
            let variance = porosities.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(porosities.count)
            let std = sqrt(variance)

            return ColumnSummary(column: column, meanPorosity: mean, stdPorosity: std, sampleCount: porosities.count)
        }
    }
}
