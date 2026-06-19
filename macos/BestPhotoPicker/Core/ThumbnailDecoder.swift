import CoreGraphics
import ImageIO
import Foundation

// MARK: - ThumbnailDecoder (issue 4)
//
// The decode step of the thumbnail pipeline: a pure, stateless function that
// reads an original photo off disk and returns a downsampled `CGImage`. It is
// the only place that touches the filesystem for imagery, and it touches it
// **read-only** (ADR 0001 non-destructive invariant): `CGImageSourceCreateWithURL`
// opens the file for reading, ImageIO never writes back.
//
// Why ImageIO / `CGImageSourceCreateThumbnailAtIndex`:
//   • It downsamples *while* decoding, so a 45-megapixel RAW never has to be fully
//     materialised in memory just to produce a 196pt grid tile — decode cost and
//     peak memory both scale to the target size, not the source size.
//   • It handles a wide range of formats natively, including many camera RAW
//     formats (CR3, NEF, ARW, DNG, …) via the system RAW codec — the same engine
//     Preview/Photos use — so we get RAW for free without a third-party SDK.
//
// Call this OFF the main thread (it does blocking disk I/O + decode). `ImageCache`
// owns the threading and memoisation; this type just decodes.
enum ThumbnailDecoder {
    /// Decode `url` to a thumbnail whose longest edge is at most `maxPixelSize`
    /// **pixels** (not points — the caller multiplies by the display scale).
    ///
    /// Returns `nil` on any failure (missing file, unreadable, unsupported codec,
    /// corrupt data). Callers fall back to the placeholder — never crash.
    ///
    /// - Parameters:
    ///   - url: the original photo on disk. Opened read-only.
    ///   - maxPixelSize: target longest-edge in pixels (≥ 1).
    static func decode(url: URL, maxPixelSize: Int) -> CGImage? {
        let safeMax = max(1, maxPixelSize)

        // `shouldCache: false` keeps ImageIO from holding the full-resolution
        // decoded source around after we've extracted the thumbnail — we cache the
        // small result ourselves in `ImageCache`.
        let sourceOptions: [CFString: Any] = [
            kCGImageSourceShouldCache: false,
        ]
        guard let source = CGImageSourceCreateWithURL(
            url as CFURL, sourceOptions as CFDictionary
        ) else {
            return nil
        }

        let thumbOptions: [CFString: Any] = [
            // Always synthesise from the full image rather than trusting a
            // possibly-missing or too-small embedded preview — important for RAW,
            // where the embedded JPEG may be absent or low quality.
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            // Honour the EXIF/RAW orientation so portrait shots are upright.
            kCGImageSourceCreateThumbnailWithTransform: true,
            // Cap the longest edge — this is what makes it a *downsample*.
            kCGImageSourceThumbnailMaxPixelSize: safeMax,
            // Decode the bitmap now (on this background thread) rather than lazily
            // on first draw on the main thread.
            kCGImageSourceShouldCacheImmediately: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(
            source, 0, thumbOptions as CFDictionary
        )
    }
}
