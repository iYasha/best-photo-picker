import SwiftUI

// MARK: - ExportView (issue 10)
//
// Screen 4 (README / .dc.html EXPORT block ~299-366). Delivers the human's picks:
// shows the export set, a copy-to destination, and an Export button that COPIES the
// starred originals into the destination as real files and writes an export
// manifest there. Originals are only read — never moved or deleted (ADR 0001/0002/
// 0006). The copy itself lives in `ExportService`, driven off the main actor by
// `AppModel.runExport()`.
//
// Two states:
//   • empty   (no favourites) → ★ card "Nothing selected yet" + Back to Review.
//   • ready   (≥1 favourite)  → summary cards, destination, list, footer, Export.
struct ExportView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                BackToReviewButton { model.backToReviewButtonTapped() }
                    .padding(.bottom, 18)

                Text("Export selection")
                    .font(Typography.ui(23, weight: .heavy))
                    .tracking(-0.4)
                    .foregroundStyle(Palette.textPrimary)
                    .padding(.bottom, 5)

                Text("Copies every photo you starred to a new folder as real files. Everything in your source stays exactly where it is.")
                    .font(Typography.ui(14))
                    .foregroundStyle(Palette.textSecondary)
                    .lineSpacing(3)
                    .padding(.bottom, 26)

                if model.favourites.isEmpty {
                    emptyState
                        .frame(maxWidth: .infinity)
                } else {
                    readyState
                }
            }
            .frame(maxWidth: 620, alignment: .leading)
            .frame(maxWidth: .infinity)
            .padding(Metrics.Spacing.screenPadding)
            // bpp-up: fade-up entrance (shared modifier, DesignSystem/Animations).
            .screenEntrance()
        }
    }

    // MARK: Empty state (nothing starred)

    private var emptyState: some View {
        VStack(spacing: 0) {
            RoundedRectangle(cornerRadius: 15)
                .fill(Palette.titleBarBottom)
                .frame(width: 58, height: 58)
                .overlay(
                    RoundedRectangle(cornerRadius: 15)
                        .strokeBorder(Color(hex: "#262630"), lineWidth: 1)
                )
                .overlay(
                    Image(systemName: Icon.star)
                        .font(.system(size: 22))
                        .foregroundStyle(Palette.textSecondary)
                )
                .padding(.bottom, 16)

            Text("Nothing selected yet")
                .font(Typography.ui(17, weight: .bold))
                .foregroundStyle(Palette.textPrimary)
                .padding(.bottom, 7)

            Text("Star the frames you want to keep in Review — your starred photos are exactly what gets exported here.")
                .font(Typography.ui(13))
                .foregroundStyle(Palette.textSecondary)
                .multilineTextAlignment(.center)
                .lineSpacing(3)
                .frame(maxWidth: 360)
                .padding(.bottom, 20)

            NeutralStateButton(title: "Back to Review") {
                model.backToReviewButtonTapped()
            }
        }
        .padding(.top, 40)
    }

    // MARK: Ready state (≥1 favourite)

    private var readyState: some View {
        VStack(alignment: .leading, spacing: 0) {
            summaryCards
                .padding(.bottom, 18)
            destinationSection
                .padding(.bottom, 18)
            exportList
                .padding(.bottom, 22)
            footerRow
            if let report = model.exportReport {
                resultBanner(report)
                    .padding(.top, 16)
            }
        }
    }

    // MARK: Summary cards

    private var summaryCards: some View {
        HStack(spacing: 12) {
            SummaryCard(label: "Selected") {
                Text(model.exportCountDisplay)
                    .font(Typography.mono(26, weight: .semibold))
                    // Softer "selected" gold (#f2c178) per the EXPORT spec — distinct
                    // from the primary action gold (#f2a73c = Palette.accent). Defined
                    // locally to avoid touching the DesignSystem tokens.
                    .foregroundStyle(Color(hex: "#f2c178"))
                    .padding(.top, 4)
            }
            SummaryCard(label: "Approx. size") {
                Text(model.exportApproxSizeDisplay)
                    .font(Typography.mono(26, weight: .semibold))
                    .foregroundStyle(Palette.textPrimary)
                    .padding(.top, 4)
            }
            SummaryCard(label: "Originals") {
                Text("Untouched")
                    .font(Typography.ui(14, weight: .semibold))
                    .foregroundStyle(Palette.nonDestructiveStrong)
                    .padding(.top, 8)
            }
        }
    }

    // MARK: Destination

    private var destinationSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionLabel("COPY TO")
                .padding(.bottom, 9)
            HStack(spacing: 14) {
                RoundedRectangle(cornerRadius: Metrics.Radius.buttonSmall)
                    .fill(
                        LinearGradient(
                            colors: [Color(hex: "#2a2a30"), Color(hex: "#1a1a1e")],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 40, height: 40)
                    .overlay(
                        Image(systemName: Icon.folderOpen)
                            .font(.system(size: 16))
                            .foregroundStyle(Palette.textSecondary)
                    )

                Text(model.exportDestinationDisplay)
                    .font(Typography.mono(12.5))
                    .foregroundStyle(Palette.textPrimaryAlt)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)

                ChooseButton { model.chooseExportDestination() }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .background(
                RoundedRectangle(cornerRadius: Metrics.Radius.card)
                    .fill(Palette.panelRaised)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Metrics.Radius.card)
                    .strokeBorder(Color(hex: "#2a2a30"), lineWidth: 1)
            )
        }
    }

    // MARK: "Will be exported" list

    private var exportList: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                SectionLabel("WILL BE EXPORTED")
                Spacer()
                Text("\(model.exportCountDisplay) photos")
                    .font(Typography.mono(11))
                    .foregroundStyle(Palette.textTertiary)
            }
            .padding(.bottom, 9)

            ScrollView {
                LazyVStack(spacing: 0) {
                    let frames = model.exportFrames
                    ForEach(Array(frames.enumerated()), id: \.element.id) { index, frame in
                        ExportRow(frame: frame, isFavourite: true)
                        if index < frames.count - 1 {
                            Rectangle()
                                .fill(Color(hex: "#161619"))
                                .frame(height: 1)
                        }
                    }
                }
            }
            .frame(maxHeight: 236)
            .background(
                RoundedRectangle(cornerRadius: Metrics.Radius.card)
                    .fill(Palette.panelDeep)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Metrics.Radius.card)
                    .strokeBorder(Palette.borderSubtleAlt, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: Metrics.Radius.card))
        }
    }

    // MARK: Footer + Export button

    private var footerRow: some View {
        HStack(alignment: .center, spacing: 20) {
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: Metrics.Radius.badge)
                    .fill(Palette.nonDestructiveTint)
                    .frame(width: 22, height: 22)
                    .overlay(
                        Image(systemName: Icon.lock)
                            .font(.system(size: 10))
                            .foregroundStyle(Palette.nonDestructiveAccent)
                    )
                Text("New copies only — nothing is moved or deleted.")
                    .font(Typography.ui(12.5))
                    .foregroundStyle(Palette.nonDestructiveText)
            }
            Spacer()
            if model.isExporting {
                ExportingIndicator(progress: model.exportProgress)
            } else {
                PrimaryButton(title: "Export \(model.exportCountDisplay) photos") {
                    model.startExport()
                }
            }
        }
    }

    // MARK: Result banner

    @ViewBuilder
    private func resultBanner(_ report: ExportReport) -> some View {
        let copiedOK = report.copiedCount > 0 && report.failedCount == 0
        let tint = copiedOK ? Palette.nonDestructiveAccent : Palette.markMaybe
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Image(systemName: copiedOK ? Icon.check : Icon.warning)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(tint)
                Text(report.summary)
                    .font(Typography.ui(12.5, weight: .semibold))
                    .foregroundStyle(Palette.textPrimary)
            }
            if let manifestPath = report.manifestPath {
                Text("Manifest written · \(manifestPath)")
                    .font(Typography.mono(11))
                    .foregroundStyle(Palette.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .background(
            RoundedRectangle(cornerRadius: Metrics.Radius.cardSmall)
                .fill(Palette.panelRaised)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Metrics.Radius.cardSmall)
                .strokeBorder(Palette.borderSubtleAlt2, lineWidth: 1)
        )
    }
}

// MARK: - Pieces

/// ← Back to Review pill (top-left). .dc.html ~304: bg #161618, border #232328,
/// radius 8, 12.5px/600, hover bg #1f1f24 / text #ededf0.
private struct BackToReviewButton: View {
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Image(systemName: Icon.back)
                    .font(.system(size: 12, weight: .semibold))
                Text("Back to Review")
                    .font(Typography.ui(12.5, weight: .semibold))
            }
            .foregroundStyle(hovering ? Palette.textPrimary : Palette.textSecondary)
            .padding(.horizontal, 13)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: Metrics.Radius.buttonSmall)
                    .fill(hovering ? Palette.hoverRaisedStrong : Palette.titleBarBottom)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Metrics.Radius.buttonSmall)
                    .strokeBorder(Palette.borderSubtleAlt2, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

/// 11px uppercase tertiary section label (COPY TO / WILL BE EXPORTED).
private struct SectionLabel: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text)
            .font(Typography.ui(11, weight: .semibold))
            .tracking(0.9)
            .foregroundStyle(Palette.textLabel)
    }
}

/// One summary card: 11px uppercase label over a value. .dc.html ~320: bg #121214,
/// border #232328, radius 11, 15×16 padding.
private struct SummaryCard<Value: View>: View {
    let label: String
    @ViewBuilder let value: Value

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(label.uppercased())
                .font(Typography.ui(11))
                .tracking(0.5)
                .foregroundStyle(Palette.textTertiary)
            value
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 15)
        .background(
            RoundedRectangle(cornerRadius: Metrics.Radius.card)
                .fill(Palette.panelRaised)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Metrics.Radius.card)
                .strokeBorder(Palette.borderSubtleAlt2, lineWidth: 1)
        )
    }
}

/// "Choose…" pill on the destination card. .dc.html ~339: bg #26262b, border
/// #34343b, radius 7, 12.5px/600, hover bg #2f2f35.
private struct ChooseButton: View {
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text("Choose…")
                .font(Typography.ui(12.5, weight: .semibold))
                .foregroundStyle(Palette.textTitle)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: Metrics.Radius.chip)
                        .fill(hovering ? Palette.hoverNeutral : Palette.hoverRaisedStronger)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: Metrics.Radius.chip)
                        .strokeBorder(Palette.borderStronger, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(Anim.hover, value: hovering)
    }
}

/// One row of the "Will be exported" list. .dc.html ~349: 54×36 thumb, mono
/// filename (flex), mark dot + label, mono size right-aligned (56px).
private struct ExportRow: View {
    let frame: ScoreFrame
    let isFavourite: Bool

    private var display: FrameDisplay { frame.display(isFavourite: isFavourite) }

    var body: some View {
        HStack(spacing: 11) {
            ThumbnailImage(frame: frame)
                .frame(width: 54, height: 36)
                .clipShape(RoundedRectangle(cornerRadius: Metrics.Radius.thumbnailDense))

            Text(frame.filename)
                .font(Typography.mono(12))
                .foregroundStyle(Palette.textPrimaryAlt)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 5) {
                Circle()
                    .fill(display.markColor)
                    .frame(width: 6, height: 6)
                Text(display.markLabel)
                    .font(Typography.ui(11))
                    .foregroundStyle(display.markColor)
            }

            Text(ExportRow.sizeString(frame.sizeBytes))
                .font(Typography.mono(11.5))
                .foregroundStyle(Palette.textTertiary)
                .frame(width: 56, alignment: .trailing)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    /// Compact per-file size for the row, e.g. `24 MB`, `1.2 GB`.
    static func sizeString(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowedUnits = [.useMB, .useGB, .useKB]
        return formatter.string(fromByteCount: bytes)
    }
}

/// Running indicator shown in place of the Export button while a copy is in flight.
private struct ExportingIndicator: View {
    let progress: ExportProgress?

    var body: some View {
        HStack(spacing: 9) {
            ProgressView()
                .controlSize(.small)
            Text(label)
                .font(Typography.ui(13, weight: .semibold))
                .foregroundStyle(Palette.textSecondary)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 11)
    }

    private var label: String {
        guard let progress, progress.total > 0 else { return "Exporting…" }
        return "Exporting \(progress.done)/\(progress.total)…"
    }
}
