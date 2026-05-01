import UIKit

enum ThresholdMode: String, CaseIterable, Identifiable {
    case adaptive
    case otsu

    var id: Self {
        self
    }

    var title: String {
        switch self {
        case .adaptive:
            return "Adaptive"
        case .otsu:
            return "Otsu"
        }
    }
}

enum ROIMode: String, CaseIterable, Identifiable {
    case fullImage
    case manualCrop

    var id: Self {
        self
    }

    var title: String {
        switch self {
        case .fullImage:
            return "Full Image"
        case .manualCrop:
            return "Manual Crop"
        }
    }
}

struct AnalysisParameters: Equatable {
    var thresholdMode: ThresholdMode = .adaptive
    var thresholdBias: Int = 0
    var minPoreArea: Int = 24
    var maxPoreArea: Int?
    var minimumPoreContrast: Int = 0
    var morphologyKernelSize: Int = 3
    var roiMode: ROIMode = .fullImage
    var roiRectNormalized: CGRect?
}

struct BreadAnalysisResult {
    let porosity: Double
    let poreCount: Int
    let averagePoreArea: Double
    let poreAreaCV: Double
    let maskImage: UIImage
    let overlayImage: UIImage
}

extension BreadAnalysisResult {
    var porosityPercentText: String {
        String(format: "%.1f%%", porosity * 100)
    }

    var averagePoreAreaText: String {
        String(format: "%.1f px²", averagePoreArea)
    }

    var poreAreaCVText: String {
        String(format: "%.2f", poreAreaCV)
    }
}

extension AnalysisParameters {
    var thresholdBiasText: String {
        thresholdBias > 0 ? "+\(thresholdBias)" : "\(thresholdBias)"
    }
}

extension CGRect {
    static let defaultAnalysisROI = CGRect(x: 0.1, y: 0.1, width: 0.8, height: 0.8)

    func clampedToUnit(minSize: CGFloat) -> CGRect {
        let standardizedRect = standardized
        let limitedMinSize = min(max(minSize, 0.05), 1.0)

        var width = min(max(standardizedRect.width, limitedMinSize), 1.0)
        var height = min(max(standardizedRect.height, limitedMinSize), 1.0)
        var x = min(max(standardizedRect.origin.x, 0), 1.0 - width)
        var y = min(max(standardizedRect.origin.y, 0), 1.0 - height)

        if x + width > 1.0 {
            width = 1.0 - x
        }

        if y + height > 1.0 {
            height = 1.0 - y
        }

        x = min(max(x, 0), max(0, 1.0 - width))
        y = min(max(y, 0), max(0, 1.0 - height))

        return CGRect(x: x, y: y, width: width, height: height)
    }

    func denormalized(in rect: CGRect) -> CGRect {
        CGRect(
            x: rect.minX + (minX * rect.width),
            y: rect.minY + (minY * rect.height),
            width: width * rect.width,
            height: height * rect.height
        )
    }
}
