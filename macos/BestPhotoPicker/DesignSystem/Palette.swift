import SwiftUI

enum Palette {
    static let desktopBackdropTop = Color(hex: "#1a1b1f")
    static let desktopBackdropMid = Color(hex: "#0a0a0c")
    static let desktopBackdropBottom = Color(hex: "#060607")

    static let windowBody = Color(hex: "#101012")
    static let titleBarTop = Color(hex: "#1b1c1f")
    static let titleBarBottom = Color(hex: "#161618")
    static let contentBase = Color(hex: "#0c0c0e")
    static let panelRaised = Color(hex: "#121214")
    static let panelDeep = Color(hex: "#0e0e10")
    static let panelDeepAlt = Color(hex: "#0c0c0e")

    static let hoverRaised = Color(hex: "#1c1c20")
    static let hoverRaisedStrong = Color(hex: "#222227")
    static let hoverRaisedStronger = Color(hex: "#26262b")
    static let hoverNeutral = Color(hex: "#2f2f35")

    static let borderSubtle = Color(hex: "#1d1d22")
    static let borderSubtleAlt = Color(hex: "#1f1f24")
    static let borderSubtleAlt2 = Color(hex: "#232328")
    static let borderStrong = Color(hex: "#2c2c33")
    static let borderStronger = Color(hex: "#34343b")
    static let borderStrongest = Color(hex: "#3a3a42")
    static let windowBorder = Color(hex: "#242429")
    static let dashedBorder = Color(hex: "#34343b")
    static let dashedBorderHover = Color(hex: "#4a4a52")

    static let textPrimary = Color(hex: "#ededf0")
    static let textPrimaryAlt = Color(hex: "#dcdce0")
    static let textTitle = Color(hex: "#d7d7dc")
    static let textSecondary = Color(hex: "#9a9aa2")
    static let textTertiary = Color(hex: "#6b6b73")
    static let textLabel = Color(hex: "#74747c")
    static let textMuted = Color(hex: "#52525a")
    static let textIconIdle = Color(hex: "#8a8a92")

    static let accent = Color(hex: "#f2a73c")
    static let accentGradientTop = Color(hex: "#f4b352")
    static let accentGradientBottom = Color(hex: "#eb9a2c")
    static let accentTextOnGold = Color(hex: "#231703")

    static let markBest = Color(hex: "#54cf93")
    static let markMaybe = Color(hex: "#9aa0aa")
    static let markRejected = Color(hex: "#e0655c")

    static let exposureWarning = Color(hex: "#f0c14b")

    static let nonDestructiveText = Color(hex: "#7e8c84")
    static let nonDestructiveAccent = Color(hex: "#54cf93")
    static let nonDestructiveTint = Color(hex: "#54cf93").opacity(0.12)
    static let nonDestructiveStrong = Color(hex: "#9fb8aa")

    static let trafficRed = Color(hex: "#ff5f57")
    static let trafficYellow = Color(hex: "#febc2e")
    static let trafficGreen = Color(hex: "#28c840")

    static let accentGradient = LinearGradient(
        colors: [accentGradientTop, accentGradientBottom],
        startPoint: .top,
        endPoint: .bottom
    )
    /// Dark counterpart to `accentGradient` — same top→bottom shape, black tones.
    /// Fills the primary button in its disabled state so it reads as a solid (inert)
    /// button rather than a hollow outline.
    static let darkButtonGradient = LinearGradient(
        colors: [Color(hex: "#2a2a30"), Color(hex: "#1a1a1e")],
        startPoint: .top,
        endPoint: .bottom
    )
    static let titleBarGradient = LinearGradient(
        colors: [titleBarTop, titleBarBottom],
        startPoint: .top,
        endPoint: .bottom
    )
    static let footerGradient = LinearGradient(
        colors: [titleBarBottom, panelRaised],
        startPoint: .top,
        endPoint: .bottom
    )
}
