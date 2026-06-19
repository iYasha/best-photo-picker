import SwiftUI

struct ImportView: View {
    @Environment(AppModel.self) private var model
    @State private var dropzoneHovering = false
    @State private var chooseHovering = false

    var body: some View {
        GeometryReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    header
                    introLine
                    sourceLabel
                    dropzone
                    reassuranceAndStart
                }
                .frame(maxWidth: Metrics.Content.importMaxWidth, alignment: .leading)
                .frame(maxWidth: .infinity)
                .padding(Metrics.Spacing.screenPadding)
                // bpp-up: fade-up entrance (shared modifier, DesignSystem/Animations).
                .screenEntrance()
                // Centre the column in the window; fall back to scrolling if the
                // window is shorter than the content.
                .frame(minHeight: proxy.size.height)
            }
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text("Best Photo Picker")
                .font(Typography.ui(27, weight: .heavy))
                .tracking(-0.5)
                .foregroundStyle(Palette.textPrimary)
            Text("on-device culling for burst shooters")
                .font(Typography.ui(13))
                .foregroundStyle(Palette.textTertiary)
        }
        .padding(.bottom, 4)
    }

    private var introLine: some View {
        Text("Point it at a card or folder. It groups your frames into bursts, recommends the best of each, and tells you why — so you fly through and keep only your favourites.")
            .font(Typography.ui(14.5))
            .foregroundStyle(Palette.textSecondary)
            .lineSpacing(4)
            .frame(maxWidth: 560, alignment: .leading)
            .padding(.bottom, 30)
    }

    private var sourceLabel: some View {
        Text("SOURCE")
            .font(Typography.ui(11, weight: .semibold))
            .tracking(0.9)
            .foregroundStyle(Palette.textLabel)
            .padding(.bottom, 9)
    }

    private var dropzone: some View {
        HStack(spacing: 16) {
            RoundedRectangle(cornerRadius: Metrics.Radius.button)
                .fill(
                    LinearGradient(
                        colors: [Color(hex: "#2a2a30"), Color(hex: "#1a1a1e")],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .frame(width: 46, height: 46)
                .overlay(
                    Image(systemName: Icon.folder)
                        .font(.system(size: 19))
                        .foregroundStyle(Palette.textSecondary)
                )

            VStack(alignment: .leading, spacing: 3) {
                Text(model.sourcePathDisplay)
                    .font(Typography.mono(12.5))
                    .foregroundStyle(Palette.textPrimaryAlt)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(model.detectedStatsDisplay)
                    .font(Typography.ui(12))
                    .foregroundStyle(Palette.textTertiary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            chooseButton
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 18)
        .background(
            RoundedRectangle(cornerRadius: Metrics.Radius.card)
                .fill(Palette.panelRaised)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Metrics.Radius.card)
                .strokeBorder(
                    dropzoneHovering ? Palette.dashedBorderHover : Palette.dashedBorder,
                    style: StrokeStyle(lineWidth: Metrics.Stroke.dashed, dash: [6, 5])
                )
        )
        .onHover { dropzoneHovering = $0 }
        .animation(Anim.hover, value: dropzoneHovering)
    }

    private var chooseButton: some View {
        Button {
            model.chooseSourceButtonTapped()
        } label: {
            Text("Choose…")
                .font(Typography.ui(12.5, weight: .semibold))
                .foregroundStyle(Palette.textTitle)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: Metrics.Radius.chip)
                        .fill(chooseHovering ? Palette.hoverNeutral : Palette.hoverRaisedStronger)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: Metrics.Radius.chip)
                        .strokeBorder(Palette.borderStronger, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .onHover { chooseHovering = $0 }
        .animation(Anim.hover, value: chooseHovering)
    }

    private var reassuranceAndStart: some View {
        HStack(alignment: .center, spacing: 20) {
            HStack(spacing: 9) {
                RoundedRectangle(cornerRadius: Metrics.Radius.badge)
                    .fill(Palette.nonDestructiveTint)
                    .frame(width: 22, height: 22)
                    .overlay(
                        Image(systemName: Icon.lock)
                            .font(.system(size: 10))
                            .foregroundStyle(Palette.nonDestructiveAccent)
                    )
                (
                    Text("Non-destructive — your originals are only ")
                        .foregroundStyle(Palette.nonDestructiveText)
                    + Text("read").foregroundStyle(Palette.nonDestructiveStrong)
                    + Text(", never moved or changed.")
                        .foregroundStyle(Palette.nonDestructiveText)
                )
                .font(Typography.ui(12.5))
            }
            Spacer()
            PrimaryButton(title: "Start culling", isEnabled: model.canStartCulling) {
                model.startCullingButtonTapped()
            }
        }
        .padding(.top, 28)
    }
}
