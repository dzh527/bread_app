import SwiftUI

struct AppContainerView: View {
    var body: some View {
        TabView {
            AnalysisView(viewModel: AnalysisViewModel())
                .tabItem {
                    Label("Single", systemImage: "photo")
                }

            GridAnalysisView(viewModel: GridAnalysisViewModel())
                .tabItem {
                    Label("Grid", systemImage: "square.grid.3x3")
                }
        }
    }
}

#Preview {
    AppContainerView()
}
