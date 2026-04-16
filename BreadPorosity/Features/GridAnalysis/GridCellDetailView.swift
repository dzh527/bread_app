import SwiftUI

struct GridCellDetailView: View {
    let cellResult: GridCellResult

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                metricSection
                originalSection
                maskSection
                overlaySection
            }
            .padding(20)
        }
    }

    private var metricSection: some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                metricTile(title: "Porosity", value: cellResult.analysisResult.porosityPercentText)
                metricTile(title: "Pores", value: "\(cellResult.analysisResult.poreCount)")
            }

            HStack(spacing: 12) {
                metricTile(title: "Avg Pore Area", value: cellResult.analysisResult.averagePoreAreaText)
                metricTile(title: "Pore Area CV", value: cellResult.analysisResult.poreAreaCVText)
            }
        }
        .detailCardStyle()
    }

    private var originalSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Cell Image")
                .font(.subheadline)
                .fontWeight(.semibold)

            analysisImage(cellResult.cellImage)
        }
        .detailCardStyle()
    }

    private var maskSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Binary Mask")
                .font(.subheadline)
                .fontWeight(.semibold)

            analysisImage(cellResult.analysisResult.maskImage)
        }
        .detailCardStyle()
    }

    private var overlaySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Overlay")
                .font(.subheadline)
                .fontWeight(.semibold)

            analysisImage(cellResult.analysisResult.overlayImage)
        }
        .detailCardStyle()
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
}

private extension View {
    func detailCardStyle() -> some View {
        padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
}
