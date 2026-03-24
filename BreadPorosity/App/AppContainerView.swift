import SwiftUI

struct AppContainerView: View {
    var body: some View {
        AnalysisView(viewModel: AnalysisViewModel())
    }
}

#Preview {
    AppContainerView()
}
