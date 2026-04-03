import PhotosUI
import SwiftUI
import UIKit

@MainActor
final class GridAnalysisViewModel: ObservableObject {
    @Published var selectedImage: UIImage?
    @Published var gridSpec = GridSpec(rows: 2, columns: 3)
    @Published var gridResult: GridAnalysisResult?
    @Published var isAnalyzing = false
    @Published var alertMessage: String?
    @Published var isShowingCamera = false

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

        selectedImage = image.normalizedOrientationForAnalysis()
        gridResult = nil
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

    func analyzeGrid() async {
        guard !isAnalyzing else {
            return
        }

        guard let image = selectedImage else {
            alertMessage = "Select an image before starting analysis."
            return
        }

        isAnalyzing = true
        gridResult = nil
        alertMessage = nil

        defer {
            isAnalyzing = false
        }

        do {
            gridResult = try await analyzer.analyzeGrid(image: image, gridSpec: gridSpec)
        } catch {
            alertMessage = error.localizedDescription
        }
    }

    func clearResult() {
        gridResult = nil
    }
}
