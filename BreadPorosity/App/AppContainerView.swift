import SwiftUI

struct AppContainerView: View {
    @State private var selectedTab: AppTab = .grid

    var body: some View {
        TabView(selection: $selectedTab) {
            AnalysisView(viewModel: AnalysisViewModel())
                .tabItem {
                    Label("Single", systemImage: "photo")
                }
                .tag(AppTab.single)

            GridAnalysisView(viewModel: GridAnalysisViewModel())
                .tabItem {
                    Label("Grid", systemImage: "square.grid.3x3")
                }
                .tag(AppTab.grid)
        }
    }
}

private enum AppTab {
    case single
    case grid
}

#Preview {
    AppContainerView()
}
