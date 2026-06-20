import SwiftUI

/// Screen 2 — the on-device scoring pass. Live percentage, gold progress bar, a
/// now-processing card with a scan-line sweep, Elapsed / Remaining cards, Cancel.
/// Auto-advances to Review at 100% (driven by `AppModel.runScoring`).
struct ScoringView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack {
            content
                .frame(maxWidth: 560)
                .screenEntrance()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(Metrics.Spacing.screenPadding)
        // Unstructured Task tied to the view's lifecycle: starts the scoring run,
        // and is cancelled automatically when the screen leaves the hierarchy
        // (Cancel / auto-advance to Review) — which terminates the bridge stream.
        .task {
            await model.runScoring()
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 0) {
            onDeviceRow
            percentageRow
            progressBar
            nowProcessingCard
            statCards
            footerRow
        }
    }

    // MARK: On-device pulsing dot + label

    private var onDeviceRow: some View {
        HStack(spacing: 9) {
            PulsingDot()
            Text("SCORING ON-DEVICE — no photos leave your Mac")
                .font(Typography.ui(12, weight: .semibold))
                .tracking(0.4)
                .foregroundStyle(Palette.nonDestructiveStrong)
        }
        .padding(.bottom, 24)
    }

    // MARK: 58px percentage + counts

    private var percentageRow: some View {
        HStack(alignment: .bottom, spacing: 14) {
            Text(model.scoringPercentDisplay)
                .font(Typography.mono(58, weight: .bold))
                .tracking(-2)
                .foregroundStyle(Palette.textPrimary)
                .monospacedDigit()
                .contentTransition(.numericText())
            (
                Text(model.scoringCountsDisplay.done)
                    .font(Typography.mono(13))
                    .foregroundStyle(Palette.textPrimaryAlt)
                + Text(" of \(model.scoringCountsDisplay.total) frames")
                    .font(Typography.ui(13))
                    .foregroundStyle(Palette.textIconIdle)
            )
            .padding(.bottom, 9)
        }
        .padding(.bottom, 6)
    }

    // MARK: 7px gold progress bar

    private var progressBar: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Palette.hoverRaised)
                Capsule()
                    .fill(
                        LinearGradient(
                            colors: [Palette.accentGradientBottom, Palette.accentGradientTop],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: max(0, geo.size.width * model.scoringProgress))
            }
        }
        .frame(height: 7)
        .animation(.linear(duration: 0.13), value: model.scoringProgress)
        .padding(.top, 14)
        .padding(.bottom, 26)
    }

    // MARK: Now-processing card

    private var nowProcessingCard: some View {
        HStack(spacing: 14) {
            ScanThumbnail()
            VStack(alignment: .leading, spacing: 2) {
                Text(model.scoringActivityTitle)
                    .font(Typography.mono(12.5))
                    .foregroundStyle(Palette.textPrimaryAlt)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(model.scoringActivitySubtitle)
                    .font(Typography.ui(12))
                    .foregroundStyle(Palette.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 15)
        .padding(.vertical, 13)
        .background(
            RoundedRectangle(cornerRadius: Metrics.Radius.card)
                .fill(Palette.panelRaised)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Metrics.Radius.card)
                .strokeBorder(Palette.borderSubtleAlt2, lineWidth: 1)
        )
        .padding(.bottom, 18)
    }

    // MARK: Elapsed / Remaining stat cards

    private var statCards: some View {
        HStack(spacing: 10) {
            statCard(label: "Elapsed", value: model.scoringElapsedDisplay)
            statCard(label: "Remaining", value: "~\(model.scoringRemainingDisplay)")
        }
        .padding(.bottom, 28)
    }

    private func statCard(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label.uppercased())
                .font(Typography.ui(10.5))
                .tracking(0.6)
                .foregroundStyle(Palette.textTertiary)
            Text(value)
                .font(Typography.mono(18, weight: .medium))
                .foregroundStyle(Palette.textPrimary)
                .monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: Metrics.Radius.cardSmall)
                .fill(Palette.panelRaised)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Metrics.Radius.cardSmall)
                .strokeBorder(Palette.borderSubtleAlt2, lineWidth: 1)
        )
    }

    // MARK: Footer — non-destructive reminder + Cancel

    private var footerRow: some View {
        HStack {
            HStack(spacing: 7) {
                Image(systemName: Icon.lock)
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.nonDestructiveAccent)
                Text("Originals are only being read.")
                    .font(Typography.ui(12))
                    .foregroundStyle(Palette.nonDestructiveText)
            }
            Spacer()
            CancelButton {
                model.cancelScoringButtonTapped()
            }
        }
    }
}

// MARK: - Pieces

/// The pulsing green on-device dot.
private struct PulsingDot: View {
    @State private var animate = false

    var body: some View {
        Circle()
            .fill(Palette.nonDestructiveAccent)
            .frame(width: 9, height: 9)
            .scaleEffect(animate ? 1 : 0.7)
            .opacity(animate ? 1 : 0.5)
            .animation(
                .easeInOut(duration: 0.7).repeatForever(autoreverses: true),
                value: animate
            )
            .onAppear { animate = true }
    }
}

/// The 70×47 now-processing thumbnail with a gold scan-line sweeping top→bottom.
private struct ScanThumbnail: View {
    @State private var phase: CGFloat = 0
    private let width: CGFloat = 70
    private let height: CGFloat = 47

    var body: some View {
        ZStack(alignment: .top) {
            // Photo stand-in (a darkroom gradient; real decode arrives in issue 4).
            LinearGradient(
                colors: [Color(hex: "#234450"), Color(hex: "#0e2330")],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            // Scan line: a soft gold band riding from top to bottom.
            LinearGradient(
                colors: [Palette.accent.opacity(0.5), .clear],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: 14)
            .offset(y: phase * (height + 14) - 14)
        }
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: Metrics.Radius.thumbnailDense))
        .overlay(
            RoundedRectangle(cornerRadius: Metrics.Radius.thumbnailDense)
                .strokeBorder(Color.white.opacity(0.06), lineWidth: 1)
        )
        .onAppear {
            withAnimation(.linear(duration: 1.1).repeatForever(autoreverses: false)) {
                phase = 1
            }
        }
    }
}

/// Secondary "Cancel" button matching the prototype's neutral pill.
private struct CancelButton: View {
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text("Cancel")
                .font(Typography.ui(13, weight: .semibold))
                .foregroundStyle(Palette.textPrimaryAlt)
                .padding(.horizontal, 18)
                .padding(.vertical, 9)
                .background(
                    RoundedRectangle(cornerRadius: Metrics.Radius.buttonSmall)
                        .fill(hovering ? Palette.hoverRaisedStronger : Palette.hoverRaised)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: Metrics.Radius.buttonSmall)
                        .strokeBorder(hovering ? Palette.borderStrongest : Palette.borderStrong, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(Anim.hover, value: hovering)
    }
}
