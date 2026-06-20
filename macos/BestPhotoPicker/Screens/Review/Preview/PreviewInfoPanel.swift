import SwiftUI

// MARK: - PreviewInfoPanel (issue 7) — the 264px right panel
//
// .dc.html ~229-242. Fixed 264px column, bg #101012, border #1f1f24, radius 12,
// padding 16. Top→bottom:
//   • mark dot + label (mark colour) + "AI mark"
//   • WHY card — uppercase label + plain-English reason
//   • FILE card — file name + size + shot time
//   • SCORES — Sharpness row + a colour-coded bar (green ≥70 / amber ≥48 / red <48)
//   • Eyes-open + Faces stat chips
//   • exposure warning row (only when flagged)
//   • spacer
//   • Select for export (gold when Favourite), full width
//   • keyboard hint row (← → frames · ↑ ↓ groups · Space select · Esc close)
struct PreviewInfoPanel: View {
    let display: FrameDisplay
    let isFavourite: Bool
    /// Capture timecode of the frame's burst, e.g. `07:42:11` (the core carries
    /// time per burst, not per frame — see `ScoreBurst.time`).
    let captureTime: String
    let onToggleFavourite: () -> Void

    /// For resolving the frame's file (source root + rel path) to compute its
    /// histogram — same seam `ThumbnailImage` uses.
    @Environment(AppModel.self) private var model
    /// The frame's tone histogram, once computed. `nil` while loading or on
    /// failure (the chart wells render empty).
    @State private var histogram: Histogram?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            markRow
                .padding(.bottom, 14)
            whyCard
                .padding(.bottom, 16)
            fileCard
                .padding(.bottom, 16)
            sectionLabel("Scores")
                .padding(.bottom, 10)
            sharpnessRow
                .padding(.bottom, 13)
            statChips
                .padding(.bottom, 13)
            HistogramCard(histogram: histogram)
                .padding(.bottom, 13)
            if display.hasExposureWarning {
                exposureRow
                    .padding(.bottom, 13)
            }
            Spacer(minLength: 12)
            actionRow
                .padding(.bottom, 12)
            keyboardHints
        }
        .padding(16)
        .frame(width: 264)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(
            RoundedRectangle(cornerRadius: Metrics.Radius.cardLarge)
                .fill(Palette.windowBody)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Metrics.Radius.cardLarge)
                .strokeBorder(Palette.borderSubtleAlt, lineWidth: 1)
        )
        // Recompute on every frame change; clears to nil first so a stale chart
        // never lingers under the new frame while its histogram is computing.
        .task(id: display.frame.id) { await loadHistogram() }
    }

    private func loadHistogram() async {
        histogram = nil
        guard let root = model.sourceURL else { return }
        let url = root.appending(path: display.frame.relPath)
        histogram = await ImageCache.shared.histogram(forFrameID: display.frame.id, url: url)
    }

    // MARK: Mark row — dot + label + "AI mark"

    private var markRow: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(display.markColor)
                .frame(width: 9, height: 9)
            Text(display.markLabel)
                .font(Typography.ui(14, weight: .bold))
                .foregroundStyle(display.markColor)
            Spacer(minLength: 0)
            Text("AI mark")
                .font(Typography.ui(11))
                .foregroundStyle(Palette.textTertiary)
        }
    }

    // MARK: WHY card

    private var whyCard: some View {
        VStack(alignment: .leading, spacing: 5) {
            sectionLabel("Why")
            Text(display.frame.reason)
                .font(Typography.ui(12.5))
                .foregroundStyle(Color(hex: "#cfcfd6"))
                .lineSpacing(3) // ~1.45 line-height at 12.5px
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 11)
        .background(
            RoundedRectangle(cornerRadius: Metrics.Radius.cardSmall - 1) // 9
                .fill(Palette.panelDeepAlt)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Metrics.Radius.cardSmall - 1)
                .strokeBorder(Palette.borderSubtle, lineWidth: 1)
        )
    }

    // MARK: FILE card — name · size · shot time

    private var fileCard: some View {
        VStack(alignment: .leading, spacing: 7) {
            sectionLabel("File")
            metaRow("Name", display.filename, truncateMiddle: true)
            metaRow("Size", display.sizeString)
            metaRow("Shot", captureTime)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 11)
        .background(
            RoundedRectangle(cornerRadius: Metrics.Radius.cardSmall - 1)
                .fill(Palette.panelDeepAlt)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Metrics.Radius.cardSmall - 1)
                .strokeBorder(Palette.borderSubtle, lineWidth: 1)
        )
    }

    /// A label → mono-value row (right-aligned value), reused for Name/Size/Shot.
    /// `truncateMiddle` keeps both ends of a long file name visible (`DSC_…13.JPG`).
    private func metaRow(_ label: String, _ value: String, truncateMiddle: Bool = false) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .font(Typography.ui(12))
                .foregroundStyle(Palette.textSecondary)
            Spacer(minLength: 8)
            Text(value)
                .font(Typography.mono(12, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(Palette.textPrimary)
                .lineLimit(1)
                .truncationMode(truncateMiddle ? .middle : .tail)
        }
    }

    // MARK: SCORES — Sharpness + colour bar

    private var sharpnessRow: some View {
        VStack(spacing: 5) {
            HStack {
                Text("Sharpness")
                    .font(Typography.ui(12))
                    .foregroundStyle(Palette.textSecondary)
                Spacer(minLength: 0)
                Text(display.sharpnessString)
                    .font(Typography.mono(12, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(Palette.textPrimary)
            }
            sharpnessBar
        }
    }

    private var sharpnessBar: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Palette.hoverRaised)
                Capsule()
                    .fill(sharpnessColor)
                    .frame(width: geo.size.width * fillFraction)
            }
        }
        .frame(height: 5)
    }

    /// Sharpness is 0–99; the bar fills proportionally out of 100 (prototype uses
    /// `width: {sharp}%`).
    private var fillFraction: CGFloat {
        min(1, max(0, CGFloat(display.frame.sharpness) / 100))
    }

    /// Bar colour thresholds (.dc.html `pvSharpBar`): green ≥70 / amber ≥48 / red <48.
    private var sharpnessColor: Color {
        let s = display.frame.sharpness
        if s >= 70 { return Palette.markBest }
        if s >= 48 { return Palette.exposureWarning }
        return Palette.markRejected
    }

    // MARK: Eyes-open + Faces stat chips

    private var statChips: some View {
        HStack(spacing: 9) {
            statChip(label: "Eyes-open", value: display.eyesString)
            statChip(label: "Faces", value: display.facesString)
        }
    }

    private func statChip(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(Typography.ui(10.5))
                .foregroundStyle(Palette.textTertiary)
            Text(value)
                .font(Typography.mono(15, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(Palette.textPrimary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .background(
            RoundedRectangle(cornerRadius: Metrics.Radius.buttonSmall)
                .fill(Palette.panelDeepAlt)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Metrics.Radius.buttonSmall)
                .strokeBorder(Palette.borderSubtle, lineWidth: 1)
        )
    }

    // MARK: Exposure warning row

    private var exposureRow: some View {
        HStack(spacing: 8) {
            Image(systemName: Icon.exposureWarning)
                .font(.system(size: 10))
                .foregroundStyle(Palette.exposureWarning)
            Text(display.exposureLabel ?? "Exposure warning")
                .font(Typography.ui(12))
                .foregroundStyle(Color(hex: "#e6cf8e"))
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 9)
        .background(
            RoundedRectangle(cornerRadius: Metrics.Radius.buttonSmall)
                .fill(Palette.exposureWarning.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: Metrics.Radius.buttonSmall)
                .strokeBorder(Palette.exposureWarning.opacity(0.25), lineWidth: 1)
        )
    }

    // MARK: Select for export (full width)

    private var actionRow: some View {
        SelectForExportButton(isFavourite: isFavourite, action: onToggleFavourite)
    }

    // MARK: Keyboard hints
    //
    // FlowLayout (not a fixed HStack) so hints wrap as whole units to a second
    // row in the narrow 264px panel; each hint is `.fixedSize()` so its label
    // never breaks mid-word ("fram es").
    private var keyboardHints: some View {
        FlowLayout(spacing: 10) {
            hint("← →", "frames")
            hint("↑ ↓", "groups")
            hint("Space", "select")
            hint("Esc", "close")
        }
    }

    private func hint(_ key: String, _ label: String) -> some View {
        HStack(spacing: 4) {
            Text(key)
                .font(Typography.mono(10.5, weight: .semibold))
                .foregroundStyle(Palette.textSecondary)
            Text(label)
                .font(Typography.ui(10.5))
                .foregroundStyle(Palette.textTertiary)
        }
        .fixedSize()
    }

    // MARK: Shared section label (uppercase, tracked)

    private func sectionLabel(_ text: String) -> some View {
        Text(text.uppercased())
            .font(Typography.ui(10))
            .tracking(0.6)
            .foregroundStyle(Palette.textTertiary)
    }
}

// MARK: - Select for export (gold when Favourite)
//
// .dc.html `pvFavBtn` / `pvFavLabel` (~714-715): fills with the gold gradient and
// reads "Selected" when Favourite; otherwise neutral #1c1c20 / #2c2c33 border with
// "Select for export".
private struct SelectForExportButton: View {
    let isFavourite: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Image(systemName: Icon.star).font(.system(size: 13, weight: .bold))
                Text(isFavourite ? "Selected" : "Select for export")
                    .font(Typography.ui(12.5, weight: .bold))
            }
            .foregroundStyle(isFavourite ? Palette.accentTextOnGold : Palette.textPrimaryAlt)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(background)
            .overlay(
                RoundedRectangle(cornerRadius: Metrics.Radius.button)
                    .strokeBorder(isFavourite ? Color.clear : Palette.borderStrong, lineWidth: 1)
            )
            .brightness(hovering && isFavourite ? 0.06 : 0)
        }
        .buttonStyle(.plain)
        .help(isFavourite ? "Remove from export selection (Space)" : "Select for export (Space)")
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
    }

    @ViewBuilder private var background: some View {
        if isFavourite {
            RoundedRectangle(cornerRadius: Metrics.Radius.button)
                .fill(Palette.accentGradient)
        } else {
            RoundedRectangle(cornerRadius: Metrics.Radius.button)
                .fill(hovering ? Palette.hoverRaisedStrong : Palette.hoverRaised)
        }
    }
}
