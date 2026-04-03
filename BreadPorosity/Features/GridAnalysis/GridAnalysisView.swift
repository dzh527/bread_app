import PhotosUI
import SwiftUI

struct GridAnalysisView: View {
    @StateObject private var viewModel: GridAnalysisViewModel
    @State private var selectedPhotoItem: PhotosPickerItem?
    @State private var analysisTask: Task<Void, Never>?
    @State private var selectedCell: GridCellResult?

    init(viewModel: GridAnalysisViewModel) {
        _viewModel = StateObject(wrappedValue: viewModel)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    sourceSection
                    gridSpecSection
                    previewSection
                    analysisSection
                    if viewModel.gridResult != nil {
                        resultsSection
                        columnSummarySection
                    }
                }
                .padding(20)
            }
            .navigationTitle("Grid Analysis")
            .sheet(isPresented: $viewModel.isShowingCamera) {
                ImagePicker(sourceType: .camera) { image in
                    viewModel.isShowingCamera = false
                    viewModel.didPickImage(image)
                }
                .ignoresSafeArea()
            }
            .sheet(item: $selectedCell) { cell in
                NavigationStack {
                    GridCellDetailView(cellResult: cell)
                        .navigationTitle(cell.cellIndex.label)
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar {
                            ToolbarItem(placement: .topBarTrailing) {
                                Button("Done") { selectedCell = nil }
                            }
                        }
                }
            }
            .task(id: selectedPhotoItem) {
                await viewModel.loadPhotoSelection(selectedPhotoItem)
            }
            .alert(
                "Grid Analysis",
                isPresented: Binding(
                    get: { viewModel.alertMessage != nil },
                    set: { if !$0 { viewModel.alertMessage = nil } }
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
        }
        .gridCardStyle()
    }

    private var gridSpecSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Grid Size")
                .font(.headline)

            Stepper(value: $viewModel.gridSpec.rows, in: 1...8) {
                LabeledContent("Rows", value: "\(viewModel.gridSpec.rows)")
            }
            .onChange(of: viewModel.gridSpec.rows) { _ in viewModel.clearResult() }

            Stepper(value: $viewModel.gridSpec.columns, in: 1...8) {
                LabeledContent("Columns", value: "\(viewModel.gridSpec.columns)")
            }
            .onChange(of: viewModel.gridSpec.columns) { _ in viewModel.clearResult() }

            Text("\(viewModel.gridSpec.rows) × \(viewModel.gridSpec.columns) = \(viewModel.gridSpec.cellCount) slices")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .gridCardStyle()
    }

    private var previewSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Preview")
                .font(.headline)

            if let image = viewModel.selectedImage {
                if let result = viewModel.gridResult {
                    let overlay = GridOverlayRenderer.renderGridOverlay(
                        baseImage: image,
                        gridSpec: result.gridSpec,
                        cellResults: result.cellResults
                    )
                    analysisImage(overlay)
                } else {
                    GridPreviewOverlay(image: image, gridSpec: viewModel.gridSpec)
                        .frame(maxWidth: .infinity)
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
            } else {
                ContentUnavailableView(
                    "No Photo Selected",
                    systemImage: "photo",
                    description: Text("Capture a grid of bread slices or choose a photo from the library.")
                )
                .frame(maxWidth: .infinity)
                .frame(minHeight: 220)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
        }
        .gridCardStyle()
    }

    private var analysisSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button {
                analysisTask?.cancel()
                analysisTask = Task {
                    await viewModel.analyzeGrid()
                }
            } label: {
                HStack {
                    if viewModel.isAnalyzing {
                        ProgressView()
                            .tint(.white)
                    } else {
                        Image(systemName: "square.grid.3x3")
                    }

                    Text(viewModel.isAnalyzing ? "Analyzing \(viewModel.gridSpec.cellCount) cells..." : "Analyze Grid")
                        .fontWeight(.semibold)
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(!viewModel.canAnalyze)
        }
        .gridCardStyle()
    }

    private var resultsSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Porosity Matrix")
                .font(.headline)

            if let result = viewModel.gridResult {
                gridMatrix(result: result)
            }

            Text("Tap a cell to see detailed results.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .gridCardStyle()
    }

    private func gridMatrix(result: GridAnalysisResult) -> some View {
        let columns = Array(
            repeating: GridItem(.flexible(), spacing: 8),
            count: result.gridSpec.columns
        )

        return LazyVGrid(columns: columns, spacing: 8) {
            ForEach(0..<result.gridSpec.rows, id: \.self) { row in
                ForEach(0..<result.gridSpec.columns, id: \.self) { column in
                    if let cellResult = result.cellResult(row: row, column: column) {
                        gridCell(cellResult: cellResult)
                    } else {
                        emptyGridCell(row: row, column: column)
                    }
                }
            }
        }
    }

    private func gridCell(cellResult: GridCellResult) -> some View {
        Button {
            selectedCell = cellResult
        } label: {
            VStack(spacing: 4) {
                Image(uiImage: cellResult.cellImage)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

                Text(cellResult.analysisResult.porosityPercentText)
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(porosityColor(cellResult.analysisResult.porosity))

                Text(cellResult.cellIndex.label)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(6)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private func emptyGridCell(row: Int, column: Int) -> some View {
        VStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(.quaternary)
                .aspectRatio(1, contentMode: .fit)

            Text("--")
                .font(.caption)
                .foregroundStyle(.secondary)

            Text(GridCellIndex(row: row, column: column).label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(6)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var columnSummarySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Column Summary")
                .font(.headline)

            if let result = viewModel.gridResult {
                ForEach(result.columnSummaries.indices, id: \.self) { index in
                    let summary = result.columnSummaries[index]
                    HStack {
                        Text("Column \(summary.column + 1)")
                            .font(.subheadline)
                            .fontWeight(.medium)

                        Spacer()

                        if summary.sampleCount > 0 {
                            Text(summary.summaryText)
                                .font(.subheadline)
                                .fontWeight(.semibold)
                                .foregroundStyle(porosityColor(summary.meanPorosity))

                            Text("(n=\(summary.sampleCount))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else {
                            Text("No data")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 4)

                    if index < result.columnSummaries.count - 1 {
                        Divider()
                    }
                }
            }
        }
        .gridCardStyle()
    }

    private func analysisImage(_ image: UIImage) -> some View {
        Image(uiImage: image)
            .resizable()
            .scaledToFit()
            .frame(maxWidth: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func porosityColor(_ porosity: Double) -> Color {
        let percent = porosity * 100
        if percent < 20 {
            return .blue
        } else if percent < 40 {
            return .green
        } else if percent < 60 {
            return .orange
        } else {
            return .red
        }
    }
}

private struct GridPreviewOverlay: View {
    let image: UIImage
    let gridSpec: GridSpec

    var body: some View {
        Image(uiImage: image)
            .resizable()
            .scaledToFit()
            .overlay {
                GeometryReader { geometry in
                    let size = geometry.size
                    Canvas { context, canvasSize in
                        let cellWidth = canvasSize.width / CGFloat(gridSpec.columns)
                        let cellHeight = canvasSize.height / CGFloat(gridSpec.rows)

                        for row in 1..<gridSpec.rows {
                            let y = CGFloat(row) * cellHeight
                            var path = Path()
                            path.move(to: CGPoint(x: 0, y: y))
                            path.addLine(to: CGPoint(x: canvasSize.width, y: y))
                            context.stroke(path, with: .color(.white.opacity(0.8)), lineWidth: 1.5)
                        }

                        for column in 1..<gridSpec.columns {
                            let x = CGFloat(column) * cellWidth
                            var path = Path()
                            path.move(to: CGPoint(x: x, y: 0))
                            path.addLine(to: CGPoint(x: x, y: canvasSize.height))
                            context.stroke(path, with: .color(.white.opacity(0.8)), lineWidth: 1.5)
                        }
                    }
                    .frame(width: size.width, height: size.height)
                }
            }
    }
}

private extension View {
    func gridCardStyle() -> some View {
        padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
}

#Preview {
    GridAnalysisView(viewModel: GridAnalysisViewModel())
}
