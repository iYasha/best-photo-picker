import SwiftUI
import AppKit

enum Typography {
    static let uiFamily = "Schibsted Grotesk"
    static let monoFamilyRegular = "IBM Plex Mono"
    static let monoFamilyMedium = "IBM Plex Mono Medium"
    static let monoFamilySemiBold = "IBM Plex Mono SemiBold"

    static let uiAvailable: Bool = {
        NSFontManager.shared.availableFontFamilies.contains(uiFamily)
    }()
    static let monoAvailable: Bool = {
        NSFontManager.shared.availableFontFamilies.contains(monoFamilyRegular)
    }()

    static func ui(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        if uiAvailable {
            return Font.custom(uiFamily, size: size).weight(weight)
        }
        return Font.system(size: size, weight: weight)
    }

    static func mono(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        if monoAvailable {
            switch weight {
            case .semibold, .bold, .heavy, .black:
                return Font.custom(monoFamilySemiBold, size: size)
            case .medium:
                return Font.custom(monoFamilyMedium, size: size)
            default:
                return Font.custom(monoFamilyRegular, size: size)
            }
        }
        return Font.system(size: size, weight: weight, design: .monospaced)
    }
}
