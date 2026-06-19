import SwiftUI

// MARK: - Review empty state (issue 9)
//
// .dc.html ~156-163 ("empty" block). Shown for real when the active `markFilter`
// matches zero frames across every burst (`AppModel.hasNoFilterMatches`). A
// centered 🔍 card: neutral icon tile, "Nothing matches", a one-line body, and a
// single "Reset view" action that clears the filter (`resetFilter()` → `.all`).
//
// Rendered INSIDE the grid region — never touches ReviewView's trailing preview
// `.overlay` (issue 7).
struct ReviewEmptyState: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ReviewStateCard(maxWidth: 460) {
            // 🔍 icon tile: 62px, radius 16, neutral panel bg + border (.dc.html).
            StateIconTile(
                icon: Icon.search,
                iconSize: 24,
                tint: Palette.textSecondary,
                background: Palette.titleBarBottom,        // #161618
                border: Palette.borderSubtleAlt2           // ~#232328 (design #262630)
            )

            Text("Nothing matches")
                .font(Typography.ui(19, weight: .bold))
                .foregroundStyle(Palette.textPrimary)

            Text("No frames fit the current filter. Clear it to see every burst again.")
                .font(Typography.ui(13.5))
                .foregroundStyle(Palette.textSecondary)
                .lineSpacing(3)
                .multilineTextAlignment(.center)

            NeutralStateButton(title: "Reset view") {
                model.resetFilter()
            }
            .padding(.top, 4)
        }
    }
}
