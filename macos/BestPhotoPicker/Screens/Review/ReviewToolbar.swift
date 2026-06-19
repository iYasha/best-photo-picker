import SwiftUI

// MARK: - ReviewToolbar (52px)
//
// README screen 3 / .dc.html ~91-107. Left: "Grouping" segmented Time/Similarity
// (active = gold fill). Then filter chips All · Best · Maybe · Rejected (mark dot
// + label + mono count badge). Right: ★ Export {N} → primary gold button.
struct ReviewToolbar: View {
    @Environment(AppModel.self) private var model
    let counts: MarkCounts

    var body: some View {
        HStack(spacing: 12) {
            groupingControl
            Divider()
                .frame(width: 1, height: 20)
                .overlay(Palette.borderSubtleAlt2)
            filterChips
            Spacer(minLength: 0)
            ExportToolbarButton(count: model.selectedCount) {
                model.exportButtonTapped()
            }
            .disabled(model.regrouping)
            .opacity(model.regrouping ? 0.5 : 1)
        }
        .padding(.horizontal, 16)
        .frame(height: 52)
        .background(Color(hex: "#0f0f11"))
        .overlay(alignment: .bottom) {
            Rectangle().fill(Palette.borderSubtleAlt).frame(height: 1)
        }
    }

    // MARK: Grouping segmented control

    private var groupingControl: some View {
        HStack(spacing: 7) {
            Text("Grouping")
                .font(Typography.ui(11))
                .foregroundStyle(Palette.textTertiary)
            HStack(spacing: 2) {
                groupingSegment(.time, icon: Icon.groupingTime, label: "Time")
                groupingSegment(.similarity, icon: Icon.groupingSimilarity, label: "Similarity")
            }
            .padding(3)
            .background(
                RoundedRectangle(cornerRadius: Metrics.Radius.button)
                    .fill(Palette.titleBarBottom)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Metrics.Radius.button)
                    .strokeBorder(Palette.borderSubtleAlt2, lineWidth: 1)
            )
        }
        .fixedSize()
        // Locked while a regroup is in flight — only the panel's Cancel acts (the
        // active tab already shows the target via `displayedGrouping`).
        .disabled(model.regrouping)
    }

    private func groupingSegment(_ grouping: Grouping, icon: String, label: String) -> some View {
        let active = model.displayedGrouping == grouping
        return Button {
            // Issue 8 implements the actual switch; this is the wired seam.
            model.selectGrouping(grouping)
        } label: {
            HStack(spacing: 5) {
                Image(systemName: icon).font(.system(size: 11, weight: .semibold))
                Text(label).font(Typography.ui(12.5, weight: .semibold))
            }
            .foregroundStyle(active ? Palette.accentTextOnGold : Palette.textSecondary)
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: Metrics.Radius.chip)
                    .fill(active ? Palette.accent : Color.clear)
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: Filter chips

    // .dc.html ~100: the chip row is `flex:1; min-width:0; overflow-x:auto`, so it
    // takes the slack between grouping + export and scrolls horizontally when tight.
    private var filterChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 3) {
                // Every chip carries a mark dot (All is grey #9aa0aa, like Maybe).
                FilterChip(label: "All", dot: Palette.markFilterAll,
                           count: counts.all, active: model.markFilter == .all) {
                    model.markFilter = .all
                }
                FilterChip(label: "Best", dot: Palette.markBest,
                           count: counts.keeper, active: model.markFilter == .keeper) {
                    model.markFilter = .keeper
                }
                FilterChip(label: "Maybe", dot: Palette.markMaybe,
                           count: counts.maybe, active: model.markFilter == .maybe) {
                    model.markFilter = .maybe
                }
                FilterChip(label: "Rejected", dot: Palette.markRejected,
                           count: counts.rejected, active: model.markFilter == .rejected) {
                    model.markFilter = .rejected
                }
            }
        }
        // Locked + dimmed during a regroup (only Cancel acts).
        .disabled(model.regrouping)
        .opacity(model.regrouping ? 0.5 : 1)
    }
}

// "All" / "Maybe" share the neutral grey mark dot from the design (#9aa0aa).
// `markMaybe` already holds that hex; alias it so the All dot reads intentionally.
private extension Palette {
    static var markFilterAll: Color { markMaybe }
}

// MARK: - Filter chip
//
// .dc.html `mkFilter` (~658-660). Chip: mark dot + label + mono count badge.
//   layout   gap 6, padding 5px 9px 5px 11px, radius 7 (Metrics.Radius.chip)
//   active   bg #26262b (hoverRaisedStronger), border #3a3a42 (borderStrongest), text #ededf0 (textPrimary)
//   inactive transparent bg/border, text #8a8a92 (textIconIdle)
//   badge    mono 10.5/600, radius 5, padding 1px 5px, margin-left 1px
//            active bg #34343b (borderStronger) / text #ededf0 (textPrimary)
//            inactive bg #1a1a1e / text #6b6b73 (textTertiary)
private struct FilterChip: View {
    let label: String
    let dot: Color
    let count: Int
    let active: Bool
    let action: () -> Void

    @State private var hovering = false
    @State private var pressed = false

    // Inactive count-badge fill is the only colour here without a Palette token.
    // Hex from .dc.html `mkFilter` countStyle (orchestrator: promote to Palette).
    private static let badgeInactiveFill = Color(hex: "#1a1a1e")

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Circle()
                    .fill(dot)
                    .frame(width: 7, height: 7)
                Text(label)
                    .font(Typography.ui(12, weight: .semibold))
                Text("\(count)")
                    .font(Typography.mono(10.5, weight: .semibold))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .foregroundStyle(active ? Palette.textPrimary : Palette.textTertiary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(
                        RoundedRectangle(cornerRadius: 5) // design badge radius
                            .fill(active ? Palette.borderStronger : Self.badgeInactiveFill)
                    )
                    .padding(.leading, 1) // design margin-left:1px on the badge
            }
            .foregroundStyle(active ? Palette.textPrimary : Palette.textIconIdle)
            .padding(.leading, 11)
            .padding(.trailing, 9)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: Metrics.Radius.chip)
                    .fill(chipFill)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Metrics.Radius.chip)
                    .strokeBorder(active ? Palette.borderStrongest : Color.clear, lineWidth: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: Metrics.Radius.chip))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .animation(.easeOut(duration: 0.12), value: active)
        // Neutral press/hover feedback consistent with the app's other controls:
        // a subtle bg step-up on inactive chips; the active chip stays put.
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in pressed = true }
                .onEnded { _ in pressed = false }
        )
    }

    // Active chip is fixed at #26262b; an inactive chip steps up to a faint
    // neutral fill on hover (and a touch more while pressed).
    private var chipFill: Color {
        if active { return Palette.hoverRaisedStronger }
        if pressed { return Palette.hoverRaised }
        if hovering { return Palette.hoverRaised.opacity(0.6) }
        return .clear
    }
}

// MARK: - Export button (gold, with mono count)

private struct ExportToolbarButton: View {
    let count: Int
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Image(systemName: Icon.star).font(.system(size: 11, weight: .bold))
                Text("Export").font(Typography.ui(12.5, weight: .bold))
                Text("\(count)")
                    .font(Typography.mono(12.5, weight: .semibold))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                Image(systemName: Icon.arrowRight).font(.system(size: 11, weight: .bold))
            }
            .foregroundStyle(Palette.accentTextOnGold)
            .padding(.horizontal, 15)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: Metrics.Radius.buttonSmall)
                    .fill(Palette.accentGradient)
            )
            // bpp hover: gold buttons brighten by 1.06 (shared modifier).
            .goldHover()
        }
        .buttonStyle(.plain)
        .fixedSize()
    }
}
