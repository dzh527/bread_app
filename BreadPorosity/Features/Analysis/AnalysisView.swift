import PhotosUI
import SwiftUI

struct AnalysisView: View {
    @StateObject private var viewModel: AnalysisViewModel
    @State private var selectedPhotoItem: PhotosPickerItem?
    @State private var analysisTask: Task<Void, Never>?

    init(viewModel: AnalysisViewModel) {
        _viewModel = StateObject(wrappedValue: viewModel)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    sourceSection
                    previewSection
                    parameterSection
                    analysisSection
                    resultsSection
                }
                .padding(20)
            }
            .navigationTitle("Bread Porosity")
            .sheet(isPresented: $viewModel.isShowingCamera) {
                ImagePicker(sourceType: .camera) { image in
                    viewModel.isShowingCamera = false
                    viewModel.didPickImage(image)
                }
                .ignoresSafeArea()
            }
            .task(id: selectedPhotoItem) {
                await viewModel.loadPhotoSelection(selectedPhotoItem)
            }
            .alert(
                "Bread Porosity",
                isPresented: Binding(
                    get: { viewModel.alertMessage != nil },
                    set: { isPresented in
                        if !isPresented {
                            viewModel.alertMessage = nil
                        }
                    }
                )
            ) {
                Button("OK", role: .cancel) { }
            } message: {
                Text(viewModel.alertMessage ?? "")
            }
            .onDisappear {
                analysisTask?.cancel()
                analysisTask = nil
            }
        }
    }

    private var sourceSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Source")
                .font(.headline)

            HStack(spacing: 12) {
                Button {
                    viewModel.isShowingCamera = true
                } label: {
                    Label("Take Photo", systemImage: "camera")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!viewModel.cameraAvailable || viewModel.isAnalyzing)

                PhotosPicker(selection: $selectedPhotoItem, matching: .images) {
                    Label("Photo Library", systemImage: "photo.on.rectangle")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .disabled(viewModel.isAnalyzing)
            }

            if !viewModel.cameraAvailable {
                Label("Camera is unavailable on this device or simulator.", systemImage: "exclamationmark.triangle")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .cardStyle()
    }

    private var previewSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Selected Image")
                .font(.headline)

            if let image = viewModel.selectedImage {
                if viewModel.parameters.roiMode == .manualCrop {
                    ROIEditorView(image: image, normalizedRect: roiRectBinding)
                        .frame(height: 320)
                        .allowsHitTesting(!viewModel.isAnalyzing)

                    HStack(alignment: .top) {
                        Text("Drag inside the box to move the ROI. Drag the corner handles to resize it.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)

                        Spacer()

                        Button("Reset ROI") {
                            viewModel.resetROI()
                        }
                        .buttonStyle(.bordered)
                        .disabled(viewModel.isAnalyzing)
                    }
                } else {
                    analysisImage(image)
                }
            } else {
                ContentUnavailableView(
                    "No Photo Selected",
                    systemImage: "photo",
                    description: Text("Capture a bread crumb image or choose one from the library.")
                )
                .frame(maxWidth: .infinity)
                .frame(minHeight: 220)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
        }
        .cardStyle()
        .disabled(viewModel.isAnalyzing)
    }

    private var parameterSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Parameters")
                .font(.headline)

            VStack(alignment: .leading, spacing: 8) {
                Text("ROI Mode")
                    .font(.subheadline)
                    .fontWeight(.semibold)

                Picker("ROI Mode", selection: roiModeBinding) {
                    ForEach(ROIMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Thresholding")
                    .font(.subheadline)
                    .fontWeight(.semibold)

                Picker("Threshold Mode", selection: thresholdModeBinding) {
                    ForEach(ThresholdMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
            }

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Threshold Bias")
                        .font(.subheadline)
                        .fontWeight(.semibold)

                    Spacer()

                    Text(viewModel.parameters.thresholdBiasText)
                        .foregroundStyle(.secondary)
                }

                Slider(value: thresholdBiasBinding, in: -20...20, step: 1)

                Text("Positive values detect more pores. Negative values make detection stricter.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Stepper(value: minPoreAreaBinding, in: 4...400, step: 4) {
                LabeledContent("Minimum Pore Area", value: "\(viewModel.parameters.minPoreArea) px")
            }

            Stepper(value: morphologyKernelBinding, in: 1...7, step: 2) {
                LabeledContent("Morphology Kernel", value: "\(viewModel.parameters.morphologyKernelSize)")
            }
        }
        .cardStyle()
    }

    private var analysisSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Analysis")
                .font(.headline)

            Text("Run the local segmentation pipeline to estimate crumb porosity and inspect the detected pore regions.")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Button {
                analysisTask?.cancel()
                analysisTask = Task {
                    await viewModel.analyze()
                }
            } label: {
                HStack {
                    if viewModel.isAnalyzing {
                        ProgressView()
                            .tint(.white)
                    } else {
                        Image(systemName: "chart.bar.xaxis")
                    }

                    Text(viewModel.isAnalyzing ? "Analyzing..." : "Analyze")
                        .fontWeight(.semibold)
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(!viewModel.canAnalyze)

            if viewModel.parameters.roiMode == .manualCrop {
                Label("Analysis will run on the selected ROI only.", systemImage: "crop")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                Label("Analysis will run on the full image.", systemImage: "photo")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .cardStyle()
    }

    private var resultsSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Results")
                .font(.headline)

            if let result = viewModel.result {
                resultSummary(for: result)

                VStack(alignment: .leading, spacing: 10) {
                    Text("Binary Mask")
                        .font(.subheadline)
                        .fontWeight(.semibold)

                    analysisImage(result.maskImage)
                }

                VStack(alignment: .leading, spacing: 10) {
                    Text("Overlay")
                        .font(.subheadline)
                        .fontWeight(.semibold)

                    analysisImage(result.overlayImage)
                }
            } else if viewModel.isAnalyzing {
                HStack(spacing: 12) {
                    ProgressView()
                    Text("Processing image locally...")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 8)
            } else {
                ContentUnavailableView(
                    "No Analysis Yet",
                    systemImage: "slider.horizontal.3",
                    description: Text("Choose an image and run analysis to see porosity, mask, and overlay output.")
                )
                .frame(maxWidth: .infinity)
                .frame(minHeight: 180)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
        }
        .cardStyle()
    }

    private func resultSummary(for result: BreadAnalysisResult) -> some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                metricTile(title: "Porosity", value: result.porosityPercentText)
                metricTile(title: "Pores", value: "\(result.poreCount)")
            }

            metricTile(title: "Average Pore Area", value: result.averagePoreAreaText)
        }
    }

    private func metricTile(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.footnote)
                .foregroundStyle(.secondary)

            Text(value)
                .font(.title3)
                .fontWeight(.semibold)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func analysisImage(_ image: UIImage) -> some View {
        Image(uiImage: image)
            .resizable()
            .scaledToFit()
            .frame(maxWidth: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var thresholdModeBinding: Binding<ThresholdMode> {
        Binding(
            get: { viewModel.parameters.thresholdMode },
            set: { newValue in
                viewModel.parameters.thresholdMode = newValue
                viewModel.invalidateResult()
            }
        )
    }

    private var thresholdBiasBinding: Binding<Double> {
        Binding(
            get: { Double(viewModel.parameters.thresholdBias) },
            set: { newValue in
                viewModel.parameters.thresholdBias = Int(newValue.rounded())
                viewModel.invalidateResult()
            }
        )
    }

    private var minPoreAreaBinding: Binding<Int> {
        Binding(
            get: { viewModel.parameters.minPoreArea },
            set: { newValue in
                viewModel.parameters.minPoreArea = newValue
                viewModel.invalidateResult()
            }
        )
    }

    private var morphologyKernelBinding: Binding<Int> {
        Binding(
            get: { viewModel.parameters.morphologyKernelSize },
            set: { newValue in
                viewModel.parameters.morphologyKernelSize = newValue
                viewModel.invalidateResult()
            }
        )
    }

    private var roiModeBinding: Binding<ROIMode> {
        Binding(
            get: { viewModel.parameters.roiMode },
            set: { newValue in
                viewModel.parameters.roiMode = newValue
                viewModel.invalidateResult()
            }
        )
    }

    private var roiRectBinding: Binding<CGRect> {
        Binding(
            get: { viewModel.roiRectNormalized },
            set: { newValue in
                viewModel.roiRectNormalized = newValue.clampedToUnit(minSize: 0.12)
                viewModel.invalidateResult()
            }
        )
    }
}

private extension View {
    func cardStyle() -> some View {
        padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
}

#Preview {
    AnalysisView(viewModel: AnalysisViewModel())
}
