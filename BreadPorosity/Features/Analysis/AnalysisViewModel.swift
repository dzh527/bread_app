import PhotosUI
import SwiftUI
import UIKit

@MainActor
final class AnalysisViewModel: ObservableObject {
    @Published var selectedImage: UIImage?
    @Published var result: BreadAnalysisResult?
    @Published var parameters = AnalysisParameters()
    @Published var roiRectNormalized: CGRect = .defaultAnalysisROI
    @Published var isShowingCamera = false
    @Published var isAnalyzing = false
    @Published var alertMessage: String?

    private let analyzer: any BreadAnalyzing

    init(analyzer: any BreadAnalyzing = BreadAnalyzer()) {
        self.analyzer = analyzer
    }

    var cameraAvailable: Bool {
        UIImagePickerController.isSourceTypeAvailable(.camera)
    }

    var canAnalyze: Bool {
        selectedImage != nil && !isAnalyzing
    }

    func didPickImage(_ image: UIImage?) {
        guard let image else {
            return
        }

        selectedImage = image.normalizedOrientation()
        roiRectNormalized = .defaultAnalysisROI
        result = nil
        alertMessage = nil
    }

    func loadPhotoSelection(_ item: PhotosPickerItem?) async {
        guard let item else {
            return
        }

        do {
            guard
                let data = try await item.loadTransferable(type: Data.self),
                let image = UIImage(data: data)
            else {
                alertMessage = "The selected image could not be loaded."
                return
            }

            didPickImage(image)
        } catch {
            alertMessage = "Failed to load the selected image."
        }
    }

    func analyze() async {
        guard !isAnalyzing else {
            return
        }

        guard let image = selectedImage else {
            alertMessage = "Select an image before starting analysis."
            return
        }

        isAnalyzing = true
        result = nil
        alertMessage = nil

        defer {
            isAnalyzing = false
        }

        do {
            var effectiveParameters = parameters
            effectiveParameters.roiRectNormalized = parameters.roiMode == .manualCrop
                ? roiRectNormalized.clampedToUnit(minSize: 0.12)
                : nil

            result = try await analyzer.analyze(image: image, parameters: effectiveParameters)
        } catch {
            alertMessage = error.localizedDescription
        }
    }

    func invalidateResult() {
        result = nil
    }

    func resetROI() {
        roiRectNormalized = .defaultAnalysisROI
        invalidateResult()
    }
}

private extension UIImage {
    func normalizedOrientation() -> UIImage {
        guard imageOrientation != .up else {
            return self
        }

        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { _ in
            draw(in: CGRect(origin: .zero, size: size))
        }
    }
}
