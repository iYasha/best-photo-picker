import SwiftUI

// MARK: - ThumbnailImage (issue 4)
//
// The single view that produces a frame's image. It decodes the **real** photo
// from disk — keyed by `frame.relPath` joined to the imported source root
// (`AppModel.sourceURL`) — downsampled to the tile size, cached, and rendered
// `.scaledToFill()` clipped to the frame the caller gives it. The caller still
// owns size / aspect / corner-radius / clipping; this view only fills the space.
//
//     ThumbnailImage(frame: ScoreFrame)   // ← the stable seam (issue 3)
//
// Every call site (grid thumbnail, future preview filmstrip/stage, export list)
// goes through this one view.
//
// ── States (no layout pop, never crash) ─────────────────────────────────────
//   • loading            → the dark placeholder gradient (below) — the would-be
//                          photo colour reads true, chrome recedes (README "Assets").
//   • decoded            → the real image, `.scaledToFill()` clipped by the caller.
//   • missing / failure  → the same placeholder. The current fixture's `relPath`s
//                          don't point at real files, so this path is exercised by
//                          design until issue 5 feeds a real source folder; it must
//                          look correct (placeholder shows, no error chrome).
//
// Originals are only **read** (ADR 0001) — `ThumbnailDecoder` opens the file
// read-only and ImageIO never writes back.
struct ThumbnailImage: View {
    let frame: ScoreFrame

    /// How the photo sits in the caller's box.
    ///   • `.fill` — crop to fill the box (small list/icon thumbs).
    ///   • `.fit`  — show the WHOLE photo at true proportions, letterboxed on a
    ///     dark matte (a portrait frame pillarboxes instead of being cropped to
    ///     landscape). The grid, filmstrip, and large preview use this so vertical
    ///     and horizontal photos both read at their real shape.
    var contentMode: ContentMode = .fill

    /// The source root chosen on Import. `frame.relPath` is resolved against it.
    @Environment(AppModel.self) private var model

    /// The decoded thumbnail, once ready. `nil` while loading or after a failure
    /// (both render the placeholder).
    @State private var decoded: CGImage?

    var body: some View {
        GeometryReader { geo in
            ZStack {
                // Letterbox matte: the dark surround a `.fit` photo sits on (the
                // pillarbox/letterbox bars). No-op under `.fill` — the photo covers
                // it. The caller's `.clipShape` rounds it with the photo.
                if contentMode == .fit {
                    Palette.panelDeepAlt
                }
                if let decoded {
                    // Real photo: `.fill` crops overflow to the box, `.fit` shows
                    // the whole frame centred. The caller's `.clipShape` rounds the
                    // corners.
                    Image(decoded: decoded)
                        .resizable()
                        .aspectRatio(contentMode: contentMode)
                        .frame(width: geo.size.width, height: geo.size.height)
                        .clipped()
                } else {
                    placeholder(in: geo.size)
                }
            }
            // Re-decode when the frame identity OR the target size changes. The
            // pixel target is bucketed so minor layout jitter doesn't thrash the
            // cache or re-decode on every sub-point resize.
            .task(id: TaskKey(frameID: frame.id, bucket: pixelBucket(for: geo.size))) {
                await load(targetSize: geo.size)
            }
        }
    }

    // MARK: Loading

    /// Identity for `.task` so a re-decode fires on a frame change or a size-bucket
    /// change, but not on every pixel of resize.
    private struct TaskKey: Equatable {
        let frameID: String
        let bucket: Int
    }

    /// Resolve the file, decode (off-main, via the cache), deliver on main.
    @MainActor
    private func load(targetSize: CGSize) async {
        guard let url = resolvedURL else {
            decoded = nil // No source root yet, or no rel path → placeholder.
            return
        }
        let maxPixelSize = pixelBucket(for: targetSize)
        let key = ImageCache.Key(frameID: frame.id, maxPixelSize: maxPixelSize)
        let image = await ImageCache.shared.image(for: key, url: url)
        // `.task` is cancelled & restarted if identity changes, so this assignment
        // is for the frame/size we were asked about. A `nil` result (missing file
        // or decode failure) falls back to the placeholder.
        decoded = image
    }

    /// `sourceURL` + `relPath`. `nil` when no source has been chosen yet.
    private var resolvedURL: URL? {
        guard let root = model.sourceURL else { return nil }
        return root.appending(path: frame.relPath)
    }

    /// Target longest-edge in **pixels**, bucketed to a power-of-two-ish ladder so
    /// the grid (≈196pt) and a future large preview don't fragment the cache, and a
    /// few points of layout jitter never trigger a re-decode. Falls back to a sane
    /// default before the first layout pass reports a size.
    private func pixelBucket(for size: CGSize) -> Int {
        let scale = 2.0 // Retina; over-decoding slightly is cheap and keeps it crisp.
        let longestPoints = max(size.width, size.height)
        // Ceiling on the decoded longest edge. The full-screen Preview stage is the
        // big consumer here; on a 5K display `longestPoints * 2` is ~5000px (~70 MB
        // a frame). A preview never needs more than this — zoom just magnifies the
        // already-decoded bitmap — so capping keeps each cached frame bounded
        // (`maxPixels` keeps memory sane alongside ImageCache's byte budget).
        let maxPixels = 2560.0
        let target = min(maxPixels, max(64, longestPoints * scale))
        // Round up to the next 128px step.
        let step = 128.0
        return Int((target / step).rounded(.up) * step)
    }

    // MARK: Placeholder (loading + failure fallback)
    //
    // The deterministic dark placeholder gradient from issue 3: a per-frame base
    // hue + a soft "subject" radial that fades for low sharpness + a vignette, so
    // chrome recedes and the would-be photo colour reads true (README "Assets").
    // Kept as the FALLBACK for the loading and missing/decode-failure states.

    @ViewBuilder
    private func placeholder(in size: CGSize) -> some View {
        ZStack {
            // Base fill (per-frame hue, dark).
            placeholderBase
            // Soft "subject" highlight; smaller/dimmer for low-sharpness frames.
            RadialGradient(
                colors: [subjectColor.opacity(subjectStrength), .clear],
                center: subjectCenter,
                startRadius: 0,
                endRadius: min(size.width, size.height) * 0.7 * subjectStrength
            )
            // Vignette so the surround stays near-black.
            RadialGradient(
                colors: [.clear, Color.black.opacity(0.58)],
                center: .init(x: 0.5, y: 0.34),
                startRadius: 0,
                endRadius: max(size.width, size.height) * 0.95
            )
        }
    }

    /// Stable hash of the frame id → a hue, so the same frame always looks the same.
    private var hue: Double {
        let h = frame.id.unicodeScalars.reduce(UInt64(5381)) { acc, u in
            (acc &* 33) &+ UInt64(u.value)
        }
        return Double(h % 360) / 360
    }

    private var placeholderBase: LinearGradient {
        LinearGradient(
            colors: [
                Color(hue: hue, saturation: 0.32, brightness: 0.20),
                Color(hue: hue, saturation: 0.38, brightness: 0.11),
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    private var subjectColor: Color {
        Color(hue: hue, saturation: 0.30, brightness: 0.46)
    }

    /// Low-sharpness frames get a smaller/softer subject (prototype `soft` factor).
    private var subjectStrength: Double {
        switch frame.sharpness {
        case ..<52: return 0.52
        case ..<74: return 0.74
        default: return 1.0
        }
    }

    /// Nudge the subject horizontally by id so frames in a burst aren't identical.
    private var subjectCenter: UnitPoint {
        let offset = Double(abs(frame.id.hashValue) % 30) / 100 - 0.15
        return UnitPoint(x: 0.5 + offset, y: 0.56)
    }
}

// MARK: - Image from CGImage (cross-platform-safe bridge)

extension Image {
    /// Build a SwiftUI `Image` from a decoded `CGImage`. On macOS `Image(decorative:
    /// scale:orientation:)` takes a `CGImage` directly, avoiding an `NSImage`
    /// round-trip. `decorative` (no accessibility label) is right here — the photo
    /// is conveyed by the surrounding tile chrome (filename, marks), not alt text.
    init(decoded cgImage: CGImage) {
        self.init(decorative: cgImage, scale: 1, orientation: .up)
    }
}
