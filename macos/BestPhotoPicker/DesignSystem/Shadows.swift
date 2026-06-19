import SwiftUI

struct ShadowStyle {
    let color: Color
    let radius: CGFloat
    let x: CGFloat
    let y: CGFloat
}

enum Shadows {
    /// No shadow — for states that should sit flat (e.g. a disabled primary button).
    static let none = ShadowStyle(color: .clear, radius: 0, x: 0, y: 0)
    static let window = ShadowStyle(
        color: Color.black.opacity(0.85), radius: 60, x: 0, y: 40
    )
    static let primaryButton = ShadowStyle(
        color: Palette.accent.opacity(0.6), radius: 9, x: 0, y: 6
    )
    static let keeperRingColor = Palette.markBest.opacity(0.5)
    static let thumbHairline = Color.white.opacity(0.05)
}

extension View {
    func applyShadow(_ style: ShadowStyle) -> some View {
        shadow(color: style.color, radius: style.radius, x: style.x, y: style.y)
    }
}
