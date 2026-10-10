import SwiftUI

struct AppContainerView: View {
    var body: some View {
        GridAnalysisView(viewModel: GridAnalysisViewModel())
    }
}

#Preview {
    AppContainerView()
}
