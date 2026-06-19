import SwiftUI

// MARK: - Review no-faces / model-unavailable state (issue 9)
//
// .dc.html ~143-153 ("no faces / model unavailable" block). A centered ⚠ card:
// red-tinted icon tile, "Face model unavailable", an explanation that sharpness +
// exposure still ran and the Keeper falls back to the sharpest frame, then two
// actions — "Continue without faces" (neutral) / "Retry model" (gold).
//
// Driven by `AppModel.faceModelUnavailable`. Both actions call
// `continueWithoutFaces()` to clear the flag and drop back to the grid (see
// AppModel for the issue-5 hook that will eventually set the flag for real).
//
// Rendered INSIDE the grid region — never touches ReviewView's trailing preview
// `.overlay` (issue 7).
struct ReviewNoFacesState: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ReviewStateCard(maxWidth: 520) {
            // ⚠ icon tile: 62px, radius 16, red-tinted bg + border (.dc.html).
            StateIconTile(
                icon: Icon.warning,
                iconSize: 25,
                tint: Palette.markRejected,
                background: Palette.markRejected.opacity(0.1),
                border: Palette.markRejected.opacity(0.3)
            )

            Text("Face model unavailable")
                .font(Typography.ui(19, weight: .bold))
                .foregroundStyle(Palette.textPrimary)

            Text("The on-device face & eye-open model couldn’t load, so no faces were found in this batch. Sharpness and exposure scoring still ran — keeper picks fall back to the sharpest frame of each burst.")
                .font(Typography.ui(13.5))
                .foregroundStyle(Palette.textSecondary)
                .lineSpacing(3)
                .multilineTextAlignment(.center)

            HStack(spacing: 10) {
                NeutralStateButton(title: "Continue without faces") {
                    model.continueWithoutFaces()
                }
                GoldStateButton(title: "Retry model") {
                    // Issue 5: a real retry would re-request a score with the
                    // landmarker; for now it dismisses the card like Continue.
                    model.continueWithoutFaces()
                }
            }
            .padding(.top, 4)
        }
    }
}
