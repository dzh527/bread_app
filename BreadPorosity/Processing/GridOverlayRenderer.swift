import CoreGraphics
import UIKit

enum GridOverlayRenderer {
    static func renderGridOverlay(
        baseImage: UIImage,
        gridSpec: GridSpec,
        cellResults: [[GridCellResult?]]
    ) -> UIImage {
        let size = baseImage.size
        let renderer = UIGraphicsImageRenderer(size: size)

        return renderer.image { context in
            baseImage.draw(in: CGRect(origin: .zero, size: size))

            let cgContext = context.cgContext
            let cellWidth = size.width / CGFloat(gridSpec.columns)
            let cellHeight = size.height / CGFloat(gridSpec.rows)

            cgContext.setStrokeColor(UIColor.white.cgColor)
            cgContext.setLineWidth(max(2, min(size.width, size.height) / 300))

            for row in 1..<gridSpec.rows {
                let y = CGFloat(row) * cellHeight
                cgContext.move(to: CGPoint(x: 0, y: y))
                cgContext.addLine(to: CGPoint(x: size.width, y: y))
            }

            for column in 1..<gridSpec.columns {
                let x = CGFloat(column) * cellWidth
                cgContext.move(to: CGPoint(x: x, y: 0))
                cgContext.addLine(to: CGPoint(x: x, y: size.height))
            }

            cgContext.strokePath()

            let fontSize = max(12, min(cellWidth, cellHeight) / 6)
            let font = UIFont.boldSystemFont(ofSize: fontSize)
            let paragraphStyle = NSMutableParagraphStyle()
            paragraphStyle.alignment = .center

            for row in 0..<gridSpec.rows {
                for column in 0..<gridSpec.columns {
                    guard let cellResult = cellResults[row][column] else {
                        continue
                    }

                    let text = cellResult.analysisResult.porosityPercentText
                    let attributes: [NSAttributedString.Key: Any] = [
                        .font: font,
                        .foregroundColor: UIColor.white,
                        .paragraphStyle: paragraphStyle
                    ]

                    let textSize = (text as NSString).size(withAttributes: attributes)
                    let cellOriginX = CGFloat(column) * cellWidth
                    let cellOriginY = CGFloat(row) * cellHeight

                    let labelRect = CGRect(
                        x: cellOriginX + (cellWidth - textSize.width) / 2 - 4,
                        y: cellOriginY + cellHeight - textSize.height - 8,
                        width: textSize.width + 8,
                        height: textSize.height + 4
                    )

                    cgContext.setFillColor(UIColor.black.withAlphaComponent(0.6).cgColor)
                    cgContext.fill(labelRect)

                    let textRect = CGRect(
                        x: cellOriginX + (cellWidth - textSize.width) / 2,
                        y: cellOriginY + cellHeight - textSize.height - 6,
                        width: textSize.width,
                        height: textSize.height
                    )

                    (text as NSString).draw(in: textRect, withAttributes: attributes)
                }
            }
        }
    }
}
