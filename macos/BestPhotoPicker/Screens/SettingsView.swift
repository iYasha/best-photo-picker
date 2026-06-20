import SwiftUI

// MARK: - SettingsView (issue 11)
//
// README screen 5: everyday Grouping knobs surfaced plainly; the five advanced
// ML thresholds tucked behind a collapsible. All sliders use the gold accent
// (`Palette.accent`). Bound to `AppModel.settings` (a `SettingsStore`); changes
// auto-save (debounced) to the TOML config the core reads via `-c`.
//
// `WindowChrome` already supplies the title bar + footer, so this view renders
// only the centred, scrollable settings column (README: `max 640`).

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var showAdvanced = false
    /// Drives the confirmation dialog for "Reset to recommended" (a tuning wipe,
    /// so it asks first).
    @State private var showResetConfirm = false
    /// Debounce token: each slider change cancels the previous pending save and
    /// schedules a new one, so a drag writes the file once it settles rather than
    /// on every intermediate value.
    @State private var saveTask: Task<Void, Never>?

    var body: some View {
        @Bindable var settings = model.settings

        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                backButton
                title
                groupingCard($settings)
                performanceCard($settings)
                advancedToggle
                if showAdvanced {
                    advancedWell($settings)
                }
                resetRow
                savedNote
            }
            .frame(maxWidth: settingsMaxWidth, alignment: .leading)
            .frame(maxWidth: .infinity)
            .padding(34)
            // bpp-up: fade-up entrance (shared modifier, DesignSystem/Animations).
            .screenEntrance()
        }
        .onChange(of: settingsSnapshot) { _, _ in scheduleSave() }
        .confirmationDialog(
            "Reset all settings to recommended defaults?",
            isPresented: $showResetConfirm, titleVisibility: .visible
        ) {
            Button("Reset to recommended", role: .destructive) { resetTapped() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Grouping, performance, and the advanced ML thresholds all return to their defaults. This can't be undone.")
        }
    }

    private let settingsMaxWidth: CGFloat = 640

    // MARK: Header

    private var backButton: some View {
        Button {
            model.closeSettingsButtonTapped()
        } label: {
            HStack(spacing: 7) {
                Image(systemName: Icon.back)
                    .font(.system(size: 12, weight: .semibold))
                Text("Back")
                    .font(Typography.ui(12.5, weight: .semibold))
            }
            .foregroundStyle(Palette.textSecondary)
            .padding(.horizontal, 13)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: Metrics.Radius.button)
                    .fill(Palette.panelRaised)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Metrics.Radius.button)
                    .strokeBorder(Palette.borderSubtleAlt2, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .padding(.bottom, 18)
    }

    private var title: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Settings")
                .font(Typography.ui(23, weight: .heavy))
                .tracking(-0.4)
                .foregroundStyle(Palette.textPrimary)
            Text("Changes are saved automatically and apply to your next session.")
                .font(Typography.ui(13.5))
                .foregroundStyle(Palette.textSecondary)
        }
        .padding(.bottom, 26)
    }

    // MARK: Grouping card

    private func groupingCard(_ settings: Bindable<SettingsStore>) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionLabel("GROUPING")
                .padding(.bottom, 12)

            VStack(alignment: .leading, spacing: 0) {
                sliderRow(
                    icon: Icon.groupingTime,
                    title: "Time grouping — gap",
                    help: "Default. Starts a new burst when the gap between shots exceeds this.",
                    value: settings.timeGap,
                    range: 0.3...8,
                    step: 0.1,
                    readout: model.settings.timeGapDisplay
                )

                Divider()
                    .overlay(Palette.borderSubtle)
                    .padding(.vertical, 16)

                sliderRow(
                    icon: Icon.groupingSimilarity,
                    title: "Similarity grouping — threshold",
                    help: "Group frames above this visual likeness. Switch grouping on the Review screen.",
                    value: settings.simThreshold,
                    range: 40...98,
                    step: 1,
                    readout: model.settings.simThresholdDisplay
                )
            }
            .padding(18)
            .background(cardBackground)
        }
        .padding(.bottom, 18)
    }

    // MARK: Performance card

    private func performanceCard(_ settings: Bindable<SettingsStore>) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionLabel("PERFORMANCE")
                .padding(.bottom, 12)

            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 7) {
                            Image(systemName: "cpu")
                                .font(.system(size: 12))
                                .foregroundStyle(Palette.textSecondary)
                            Text("Scoring workers")
                                .font(Typography.ui(13.5, weight: .semibold))
                                .foregroundStyle(Palette.textPrimary)
                        }
                        Text("How many photos are scored at once. Each worker uses ≈1.3 GB of RAM — Auto sizes the count to your Mac.")
                            .font(Typography.ui(12))
                            .foregroundStyle(Color(hex: "#8a8a92"))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 12)
                    Text(model.settings.workersDisplay)
                        .font(Typography.mono(14, weight: .semibold))
                        .foregroundStyle(Palette.accent)
                }
                Picker("Scoring workers", selection: settings.workers) {
                    Text("Auto (recommended)").tag(0)
                    ForEach(1...max(1, SettingsStore.maxSelectableWorkers), id: \.self) { n in
                        Text("\(n)").tag(n)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .tint(Palette.accent)
            }
            .padding(18)
            .background(cardBackground)
        }
        .padding(.bottom, 18)
    }

    // MARK: Advanced

    private var advancedToggle: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.15)) { showAdvanced.toggle() }
        } label: {
            HStack(spacing: 9) {
                Image(systemName: showAdvanced ? Icon.chevronExpanded : Icon.chevronCollapsed)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Palette.textIconIdle)
                    .frame(width: 12, alignment: .leading)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Advanced — ML thresholds")
                        .font(Typography.ui(13.5, weight: .semibold))
                        .foregroundStyle(Palette.textPrimary)
                    Text("Tune how the model scores. Defaults work for most shoots.")
                        .font(Typography.ui(12))
                        .foregroundStyle(Palette.textIconIdle)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 13)
            .background(cardBackground)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.bottom, 12)
    }

    @ViewBuilder
    private func advancedWell(_ settings: Bindable<SettingsStore>) -> some View {
        VStack(spacing: 0) {
            advancedRow(
                title: "Face-detection confidence",
                help: "Below this, a region isn’t counted as a face.",
                value: settings.faceConf,
                range: 0.3...0.95,
                step: 0.01,
                readout: model.settings.faceConfDisplay
            )
            advancedDivider
            advancedRow(
                title: "Eyes-open threshold",
                help: "Open-eye probability needed to pass.",
                value: settings.eyeThresh,
                range: 0.1...0.9,
                step: 0.01,
                readout: model.settings.eyeThreshDisplay
            )
            advancedDivider
            advancedRow(
                title: "Highlights-blown limit",
                help: "Flag exposure when this fraction of pixels clip white.",
                value: settings.blownLimit,
                range: 0.8...1.0,
                step: 0.005,
                readout: model.settings.blownLimitDisplay
            )
            advancedDivider
            advancedRow(
                title: "Shadows-crushed limit",
                help: "Flag when this fraction crushes to black.",
                value: settings.crushLimit,
                range: 0...0.2,
                step: 0.005,
                readout: model.settings.crushLimitDisplay
            )
            advancedDivider
            advancedRow(
                title: "Rejection sharpness ratio",
                help: "Reject frames below this share of the burst’s sharpness peak.",
                value: settings.rejectRatio,
                range: 0.5...0.95,
                step: 0.01,
                readout: model.settings.rejectRatioDisplay
            )
        }
        .padding(.horizontal, 18)
        .padding(.top, 6)
        .padding(.bottom, 10)
        .background(
            RoundedRectangle(cornerRadius: Metrics.Radius.cardLarge)
                .fill(Palette.panelDeep)
                .overlay(
                    RoundedRectangle(cornerRadius: Metrics.Radius.cardLarge)
                        .strokeBorder(Palette.borderSubtleAlt, lineWidth: 1)
                )
        )
        .padding(.bottom, 24)
        .transition(.opacity)
    }

    private var advancedDivider: some View {
        Rectangle()
            .fill(Color(hex: "#18181b"))
            .frame(height: 1)
    }

    // MARK: Reset

    private var resetRow: some View {
        Button { showResetConfirm = true } label: {
            HStack(spacing: 7) {
                Image(systemName: "arrow.counterclockwise")
                    .font(.system(size: 11, weight: .semibold))
                Text("Reset to recommended defaults")
                    .font(Typography.ui(12.5, weight: .semibold))
            }
            .foregroundStyle(Palette.textSecondary)
            .padding(.horizontal, 13)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: Metrics.Radius.button)
                    .fill(Palette.panelRaised)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Metrics.Radius.button)
                    .strokeBorder(Palette.borderSubtleAlt2, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .padding(.bottom, 16)
    }

    // MARK: Footer note

    private var savedNote: some View {
        HStack(spacing: 7) {
            Image(systemName: Icon.check)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Palette.nonDestructiveAccent)
            Text("Saved to your config file automatically.")
                .font(Typography.ui(12))
                .foregroundStyle(Palette.textTertiary)
        }
        .padding(.bottom, 10)
    }

    // MARK: Reusable rows

    /// A grouping-card slider row: icon + title, help, gold mono readout, slider.
    private func sliderRow(
        icon: String,
        title: String,
        help: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        step: Double,
        readout: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 7) {
                        Image(systemName: icon)
                            .font(.system(size: 12))
                            .foregroundStyle(Palette.textSecondary)
                        Text(title)
                            .font(Typography.ui(13.5, weight: .semibold))
                            .foregroundStyle(Palette.textPrimary)
                    }
                    Text(help)
                        .font(Typography.ui(12))
                        .foregroundStyle(Color(hex: "#8a8a92"))
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 12)
                Text(readout)
                    .font(Typography.mono(14, weight: .semibold))
                    .foregroundStyle(Palette.accent)
            }
            goldSlider(value: value, range: range, step: step)
        }
    }

    /// An advanced-well slider row: title + gold mono readout, help, slider.
    private func advancedRow(
        title: String,
        help: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        step: Double,
        readout: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .font(Typography.ui(13, weight: .semibold))
                    .foregroundStyle(Palette.textPrimaryAlt)
                Spacer(minLength: 12)
                Text(readout)
                    .font(Typography.mono(13, weight: .semibold))
                    .foregroundStyle(Palette.accent)
            }
            .padding(.bottom, 4)

            Text(help)
                .font(Typography.ui(11.5))
                .foregroundStyle(Color(hex: "#7a7a82"))
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, 9)

            goldSlider(value: value, range: range, step: step)
        }
        .padding(.vertical, 15)
    }

    private func goldSlider(
        value: Binding<Double>,
        range: ClosedRange<Double>,
        step: Double
    ) -> some View {
        Slider(value: value, in: range, step: step)
            .controlSize(.small)
            .tint(Palette.accent)
    }

    // MARK: Shared style

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(Typography.ui(11, weight: .semibold))
            .tracking(0.9)
            .foregroundStyle(Palette.textLabel)
    }

    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: Metrics.Radius.cardLarge)
            .fill(Palette.panelRaised)
            .overlay(
                RoundedRectangle(cornerRadius: Metrics.Radius.cardLarge)
                    .strokeBorder(Palette.borderSubtleAlt2, lineWidth: 1)
            )
    }

    // MARK: Auto-save

    /// A value-equatable snapshot of every persisted knob. `onChange` fires when
    /// any slider moves; the snapshot avoids needing seven separate observers.
    private var settingsSnapshot: SettingsSnapshot {
        let s = model.settings
        return SettingsSnapshot(
            timeGap: s.timeGap, simThreshold: s.simThreshold, workers: s.workers,
            faceConf: s.faceConf, eyeThresh: s.eyeThresh,
            blownLimit: s.blownLimit, crushLimit: s.crushLimit,
            rejectRatio: s.rejectRatio
        )
    }

    /// Confirmed reset: drop any pending debounced write and restore defaults
    /// (which persists immediately). The `onChange` that follows the state change
    /// re-schedules a save of the same values — harmless and idempotent.
    private func resetTapped() {
        saveTask?.cancel()
        model.settings.resetToDefaults()
    }

    /// Debounce: coalesce a drag's many value changes into a single write ~0.4 s
    /// after the user stops moving the slider.
    private func scheduleSave() {
        saveTask?.cancel()
        let store = model.settings
        saveTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            store.save()
        }
    }
}

/// Plain value mirror of the persisted settings, used only to drive `onChange`.
private struct SettingsSnapshot: Equatable {
    let timeGap: Double
    let simThreshold: Double
    let workers: Int
    let faceConf: Double
    let eyeThresh: Double
    let blownLimit: Double
    let crushLimit: Double
    let rejectRatio: Double
}
