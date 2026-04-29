import PhotosUI
import SwiftUI
import UIKit

@MainActor
final class GridAnalysisViewModel: ObservableObject {
    @Published var selectedImage: UIImage?
    @Published var gridSpec = GridSpec(rows: 2, columns: 3)
    @Published var gridRegionNormalized = CGRect(x: 0, y: 0, width: 1, height: 1)
    @Published var gridResult: GridAnalysisResult?
    @Published var isAnalyzing = false
    @Published var isDetectingGridROI = false
    @Published var alertMessage: String?
    @Published var isShowingCamera = false

    private let analyzer: any BreadAnalyzing
    private let maxROIDetectionDimension = 1400
    private var roiDetectionID = UUID()
    private var roiEditedSinceSelection = false

    init(analyzer: any BreadAnalyzing = BreadAnalyzer()) {
        self.analyzer = analyzer
    }

    var cameraAvailable: Bool {
        UIImagePickerController.isSourceTypeAvailable(.camera)
    }

    var canAnalyze: Bool {
        selectedImage != nil && !isAnalyzing && !isDetectingGridROI
    }

    func didPickImage(_ image: UIImage?) {
        guard let image else {
            return
        }

        selectedImage = image.normalizedOrientationForAnalysis()
        gridRegionNormalized = CGRect(x: 0, y: 0, width: 1, height: 1)
        roiEditedSinceSelection = false
        roiDetectionID = UUID()
        gridResult = nil
        alertMessage = nil

        let detectionID = roiDetectionID
        Task {
            await detectGridROI(detectionID: detectionID)
        }
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
            gridResult = try await analyzer.analyzeGrid(
                image: image,
                gridSpec: gridSpec,
                gridRegionNormalized: gridRegionNormalized
            )
        } catch {
            alertMessage = error.localizedDescription
        }
    }

    func clearResult() {
        gridResult = nil
    }

    func updateGridRegion(_ rect: CGRect) {
        roiEditedSinceSelection = true
        gridRegionNormalized = rect.clampedToUnit(minSize: 0.05)
        gridResult = nil
    }

    private func detectGridROI(detectionID: UUID) async {
        guard let image = selectedImage else {
            return
        }

        isDetectingGridROI = true
        defer {
            if roiDetectionID == detectionID {
                isDetectingGridROI = false
            }
        }

        let maxDimension = maxROIDetectionDimension
        do {
            let detectedROI = try await Task.detached(priority: .userInitiated) {
                let input = try AnalysisImageFactory.makeInput(from: image, maxDimension: maxDimension)
                return GridSlicer.detectGridContentROI(in: input.grayscale)
            }.value

            guard selectedImage === image, roiDetectionID == detectionID, !roiEditedSinceSelection else {
                return
            }

            gridRegionNormalized = (detectedROI ?? CGRect(x: 0, y: 0, width: 1, height: 1))
                .clampedToUnit(minSize: 0.05)
            gridResult = nil
        } catch {
            if roiDetectionID == detectionID, !roiEditedSinceSelection {
                gridRegionNormalized = CGRect(x: 0, y: 0, width: 1, height: 1)
            }
        }
    }
}
