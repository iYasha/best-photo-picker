import SwiftUI

// MARK: - Frame display helper
//
// Derives the per-frame display values the Review grid (issue 3), the filter
// chips (issue 6), and the Preview overlay (issue 7) all show, so formatting
// lives in ONE place instead of being scattered across views. Mirrors the
// prototype's `decorate()` (Best Photo Picker.dc.html ~619) and the `MARK`
// table (~443): label "Best"/"Maybe"/"Rejected", the mark colour/dot, a
// zero-padded 2-digit sharpness string, an exposure-warning flag, and the
// is-keeper / is-favourite booleans.
//
// `isFavourite` is passed in (it is app-side state on `AppModel`, deliberately
// not on the read-only `ScoreFrame`); everything else derives from the frame.

extension Mark {
    /// User-facing label. `keeper` reads as **"Best"** (ADR 0006 / CONTEXT.md).
    var displayLabel: String {
        switch self {
        case .keeper: return "Best"
        case .maybe: return "Maybe"
        case .rejected: return "Rejected"
        }
    }

    /// The mark's colour — green Best / grey Maybe / red Rejected. Never gold
    /// (gold is reserved for the human's Favourite star).
    var color: Color {
        switch self {
        case .keeper: return Palette.markBest
        case .maybe: return Palette.markMaybe
        case .rejected: return Palette.markRejected
        }
    }
}

extension Exposure {
    /// True when the frame is exposure-flagged (drives the ▲ warning glyph).
    var isWarning: Bool { self != .ok }

    /// Plain-English exposure label (used by the Preview info panel, issue 7).
    var warningLabel: String? {
        switch self {
        case .ok: return nil
        case .blown: return "Highlights clipped"
        case .crushed: return "Shadows crushed"
        }
    }
}

/// A frame plus its derived, ready-to-render display values. Build one with
/// `frame.display(isFavourite:)`; reuse across grid / chips / preview.
struct FrameDisplay {
    let frame: ScoreFrame
    let isFavourite: Bool

    var id: String { frame.id }
    var isKeeper: Bool { frame.mark == .keeper }

    var markLabel: String { frame.mark.displayLabel }
    var markColor: Color { frame.mark.color }

    /// Zero-padded 2-digit sharpness, e.g. `09`, `99` (clamped to two digits).
    var sharpnessString: String { String(format: "%02d", frame.sharpness) }

    var hasExposureWarning: Bool { frame.exposure.isWarning }
    var exposureLabel: String? { frame.exposure.warningLabel }

    /// Eyes-open as a percentage string, or `—` when the frame has no face.
    var eyesString: String { frame.eyes.map { "\($0)%" } ?? "—" }
    var facesString: String { "\(frame.faces)" }

    /// Original source file name, e.g. `IMG_0421.CR3` (Preview metadata, issue 7).
    var filename: String { frame.filename }

    /// Human-readable original file size, e.g. `8.4 MB` (ByteCountFormatter `.file`).
    var sizeString: String {
        ByteCountFormatter.string(fromByteCount: frame.sizeBytes, countStyle: .file)
    }
}

extension ScoreFrame {
    /// Derive this frame's display values. `isFavourite` is the app-side star
    /// state (`AppModel.isFavourite(id)`).
    func display(isFavourite: Bool) -> FrameDisplay {
        FrameDisplay(frame: self, isFavourite: isFavourite)
    }
}
