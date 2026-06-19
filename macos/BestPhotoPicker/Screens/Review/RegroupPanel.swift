import SwiftUI

// The one-time regroup job (issue 8): shown in ReviewView's grid well at TOP
// precedence while `model.regrouping`. Toggling to an uncomputed grouping runs the
// engine once for that grouping; thereafter switching is instant (both cached).
// Mirrors the .dc.html regrouping block: spinner + on-device label, 46px mono %,
// "{done} of {total} frames clustered", gold bar, the run-once copy, and Cancel.
struct RegroupPanel: View {
    @Environment(AppModel.self) private var model
    @State private var spin = false

    private var targetLabel: String {
        model.regroupTarget == .similarity ? "SIMILARITY" : "TIME"
    }

    private var clusteredCount: String {
        model.regroupTotal > 0 ? model.regroupDone.formatted() : "—"
    }

    private var totalCount: String {
        model.regroupTotal > 0 ? model.regroupTotal.formatted() : "—"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 9) {
                spinner
                Text("REGROUPING BY \(targetLabel) — on-device")
                    .font(Typography.ui(12, weight: .semibold))
                    .kerning(0.4)
                    .foregroundStyle(Color(hex: "9fb8aa"))
            }
            .padding(.bottom, 18)

            HStack(alignment: .lastTextBaseline, spacing: 12) {
                Text(model.regroupPercentDisplay)
                    .font(Typography.mono(46, weight: .semibold))
                    .foregroundStyle(Palette.textPrimary)
                Text("\(Text(clusteredCount).foregroundColor(Palette.textPrimary).font(Typography.mono(13, weight: .medium))) of \(totalCount) frames clustered")
                    .font(Typography.ui(13))
                    .foregroundStyle(Palette.textSecondary)
                    .padding(.bottom, 7)
            }
            .padding(.bottom, 14)

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color(hex: "1c1c20"))
                    Capsule()
                        .fill(Palette.accentGradient)
                        .frame(width: geo.size.width * model.regroupFraction)
                        .animation(.linear(duration: 0.12), value: model.regroupFraction)
                }
            }
            .frame(height: 7)
            .padding(.bottom, 18)

            Text("Comparing every frame to its neighbours to group near-duplicates. This runs once — about a minute — then you can switch between Time and Similarity instantly. Your photos aren’t touched.")
                .font(Typography.ui(13))
                .foregroundStyle(Palette.textSecondary)
                .lineSpacing(4)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, 22)

            RegroupCancelButton(action: model.cancelRegroup)
        }
        .frame(maxWidth: 520, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.top, 60)
        // bpp-up: fade-up entrance (shared modifier, DesignSystem/Animations).
        .screenEntrance()
    }

    private var spinner: some View {
        Circle()
            .trim(from: 0, to: 0.8)
            .stroke(
                AngularGradient(
                    colors: [Palette.borderStrong, Palette.accent],
                    center: .center
                ),
                style: StrokeStyle(lineWidth: 2, lineCap: .round)
            )
            .frame(width: 14, height: 14)
            .rotationEffect(.degrees(spin ? 360 : 0))
            .animation(.linear(duration: 0.8).repeatForever(autoreverses: false), value: spin)
            .onAppear { spin = true }
    }
}

// Neutral "Cancel" pill for the regroup job — matches the app's other neutral
// buttons with a background step-up on hover (.dc.html: bg #1c1c20 → #26262b).
private struct RegroupCancelButton: View {
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text("Cancel")
                .font(Typography.ui(13, weight: .semibold))
                .foregroundStyle(Palette.textPrimary)
                .padding(.horizontal, 18)
                .padding(.vertical, 9)
                .background(hovering ? Palette.hoverRaisedStronger : Color(hex: "1c1c20"))
                .overlay(
                    RoundedRectangle(cornerRadius: Metrics.Radius.button)
                        .stroke(hovering ? Palette.borderStrongest : Palette.borderStrong, lineWidth: 1)
                )
                .clipShape(RoundedRectangle(cornerRadius: Metrics.Radius.button))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(Anim.hover, value: hovering)
    }
}
