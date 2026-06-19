import SwiftUI

// MARK: - Animations (issue 12)
//
// Reusable motion + hover modifiers that recreate the prototype's `bpp-*`
// keyframes and inline `style-hover` behaviour (.dc.html ~19-24, README →
// "Interactions & Behavior"). One home for the values so every screen reads the
// same and a tuning change happens in one place.
//
//   bpp-up      8px fade-up entrance, .18-.4s  → `.screenEntrance()`
//   hover (gold)    brightness(1.06)           → `.goldHover(_:)`
//   hover (neutral) background step-up          → wired per-button with `.onHover`
//                                                 (the helpers here keep the timing
//                                                  consistent: `Anim.hover`)
//
// The continuous loops (bpp-spin / bpp-pulse / bpp-scan / bpp-shimmer) stay local
// to the views that own them (ScoringView, ReviewLoadingState, RegroupPanel) since
// each drives its own `@State` phase; this file holds only the cross-cutting pieces.

enum Anim {
    /// Entrance curve for `bpp-up` (8px fade-up). The prototype quotes .18-.4s;
    /// .28s sits in that band and reads subtle on a large window.
    static let entrance = Animation.easeOut(duration: 0.28)

    /// Shared hover/press feedback timing — the existing controls already use
    /// `.easeOut(duration: 0.12)`; this names it so new call sites match.
    static let hover = Animation.easeOut(duration: 0.12)
}

// MARK: Screen entrance — bpp-up

/// 8px fade-up entrance (`bpp-up`). Plays once when the view first appears (keyed
/// off local `@State`, so it does NOT re-fire on every state change of the
/// screen). Apply to a screen's main content column or a centered card.
private struct ScreenEntranceModifier: ViewModifier {
    @State private var appeared = false

    func body(content: Content) -> some View {
        content
            .opacity(appeared ? 1 : 0)
            .offset(y: appeared ? 0 : 8)
            .onAppear {
                guard !appeared else { return }
                withAnimation(Anim.entrance) { appeared = true }
            }
    }
}

extension View {
    /// `bpp-up`: opacity 0→1 + translateY 8→0 on first appearance (.28s ease-out).
    /// Subtle by design and one-shot — see `ScreenEntranceModifier`.
    func screenEntrance() -> some View { modifier(ScreenEntranceModifier()) }
}

// MARK: Gold hover — brightness(1.06)

/// Gold-button hover: brighten by 1.06 while hovered, matching the prototype's
/// `filter:brightness(1.06)` on gold buttons. Drives its own `@State`; wire it on
/// any gold/gradient button so the brighten timing is consistent app-wide.
private struct GoldHoverModifier: ViewModifier {
    /// When false the brighten is suppressed (e.g. a gold button that is only
    /// "active" when selected). Defaults to always-on.
    let isEnabled: Bool
    @State private var hovering = false

    func body(content: Content) -> some View {
        content
            .brightness(hovering && isEnabled ? 0.06 : 0)
            .animation(Anim.hover, value: hovering)
            .onHover { hovering = $0 }
    }
}

extension View {
    /// Brighten by `1.06` on hover (the prototype's gold-button hover). Pass
    /// `isEnabled: false` to suppress (e.g. only-when-selected gold controls).
    func goldHover(isEnabled: Bool = true) -> some View {
        modifier(GoldHoverModifier(isEnabled: isEnabled))
    }
}
