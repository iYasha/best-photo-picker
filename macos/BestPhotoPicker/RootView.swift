import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        WindowChrome {
            switch model.screen {
            case .importSession:
                ImportView()
            case .scoring:
                ScoringView()
            case .review:
                ReviewView()
            case .export:
                ExportView()
            }
        }
        .frame(minWidth: 900, minHeight: 600)
    }
}
