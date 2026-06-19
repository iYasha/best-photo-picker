import SwiftUI

struct PrimaryButton: View {
    let title: String
    var systemIcon: String? = Icon.arrowRight
    var isEnabled: Bool = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Text(title)
                    .font(Typography.ui(14, weight: .bold))
                if let systemIcon {
                    Image(systemName: systemIcon)
                        .font(.system(size: 12, weight: .bold))
                }
            }
            // Disabled reads as inert: the dark raised panel + border of the source
            // card, with muted text — not a dimmed gold button.
            .foregroundStyle(isEnabled ? Palette.accentTextOnGold : Palette.textTertiary)
            .padding(.horizontal, 26)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: Metrics.Radius.button)
                    .fill(isEnabled ? AnyShapeStyle(Palette.accentGradient)
                                    : AnyShapeStyle(Palette.darkButtonGradient))
            )
            .overlay(
                RoundedRectangle(cornerRadius: Metrics.Radius.button)
                    .strokeBorder(Palette.borderStronger, lineWidth: isEnabled ? 0 : 1)
            )
            .applyShadow(isEnabled ? Shadows.primaryButton : Shadows.none)
            // bpp hover: gold buttons brighten by 1.06 (shared modifier). Suppressed
            // while disabled so a dead button never lights up under the pointer.
            .goldHover(isEnabled: isEnabled)
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
    }
}
