import CoreGraphics
import Foundation

// MARK: - ImageCache (issue 4)
//
// In-memory, async cache of decoded thumbnails so re-scrolling a large shoot
// doesn't re-decode the same frames. An `actor` so concurrent requests from many
// `ThumbnailImage`s are serialised safely without locks.
//
// Two jobs:
//   1. **Memoise** decoded `CGImage`s keyed by `(frame id, pixel-size bucket)`.
//   2. **De-duplicate in-flight decodes**: if ten tiles for the same frame appear
//      at once (e.g. a fast scroll), only one decode `Task` runs; the rest await
//      its result. Without this, a flick-scroll would kick off redundant decodes.
//
// Eviction is a bounded FIFO governed by a **byte budget** (not entry count). The
// grid tiles are small, but the full-screen Preview stage asks for near-screen-
// resolution images — on a Retina display one such frame can be 15–70 MB. A pure
// count cap would let "review every photo in every burst" pin hundreds of those
// and balloon to tens of GB of RAM; bounding by resident bytes keeps it flat
// regardless of how big any single decoded frame is. A high entry-count cap stays
// as a secondary backstop. No byte-accurate disk tier is needed for this slice.
//
// The decode itself runs on a background executor (`Task.detached`), off the main
// actor, and the decoded `CGImage` (immutable, `Sendable`-safe to hand across) is
// delivered back to the caller which hops to the main actor to render.
actor ImageCache {
    /// Shared instance — one cache for the whole app session.
    static let shared = ImageCache()

    /// Cache identity: the stable frame id plus the rounded target pixel size, so a
    /// thumbnail decoded for the grid isn't reused at a wildly different size (and
    /// vice-versa). Sizes are bucketed by the caller so minor layout jitter doesn't
    /// fragment the cache.
    struct Key: Hashable {
        let frameID: String
        let maxPixelSize: Int
    }

    /// Soft cap on **total resident decoded bytes**. The real bound — preview-stage
    /// images are large, so this is what keeps memory flat. 512 MB holds many
    /// screenfuls of thumbnails plus a healthy run of full-size previews.
    private let byteBudget = 512 * 1024 * 1024
    /// Secondary backstop on entry count, so the bookkeeping dictionaries can't grow
    /// without limit in a pathological all-tiny-images case.
    private let capacity = 1200

    /// Decoded results, newest-touched last (for FIFO-ish eviction).
    private var cached: [Key: CGImage] = [:]
    /// Bytes each cached image occupies (`bytesPerRow * height`), for the budget.
    private var sizes: [Key: Int] = [:]
    /// Running sum of `sizes.values`, kept in step with `cached`.
    private var residentBytes = 0
    /// Insertion/access order of keys for eviction (front = oldest).
    private var order: [Key] = []
    /// Decodes currently running, so duplicate requests await the same `Task`.
    private var inFlight: [Key: Task<CGImage?, Never>] = [:]

    /// Tone histograms keyed by frame id (size-independent). Each is ~1 KB, so
    /// they're kept for the session without eviction.
    private var histograms: [String: Histogram] = [:]
    /// In-flight histogram computes, de-duplicated like decodes.
    private var histogramTasks: [String: Task<Histogram?, Never>] = [:]

    /// **Single-slot** full-resolution decode for the zoomed Preview stage. Only
    /// the most-recently-requested frame is held — a native decode of a 45 MP
    /// frame is ~180 MB, so we keep at most ONE, deliberately outside the byte
    /// budget above (which stays bounded for the gallery). Requesting a different
    /// frame drops the previous one.
    private var fullResID: String?
    private var fullResImage: CGImage?

    /// Return the decoded thumbnail for `key`, decoding from `url` if not cached.
    /// Coalesces concurrent requests for the same key onto a single decode. Returns
    /// `nil` if the decode fails (caller shows the placeholder).
    func image(for key: Key, url: URL) async -> CGImage? {
        if let hit = cached[key] {
            touch(key)
            return hit
        }
        if let running = inFlight[key] {
            return await running.value
        }

        let maxPixelSize = key.maxPixelSize
        let task = Task<CGImage?, Never>.detached(priority: .userInitiated) {
            ThumbnailDecoder.decode(url: url, maxPixelSize: maxPixelSize)
        }
        inFlight[key] = task
        let image = await task.value
        inFlight[key] = nil

        if let image {
            store(key, image)
        }
        return image
    }

    /// Return the tone histogram for the frame, computing it once off a background
    /// thread and memoising by frame id. Decodes its own small image (independent
    /// of the display bucket) so the result is stable and cheap. Coalesces
    /// concurrent requests. `nil` if the decode fails.
    func histogram(forFrameID id: String, url: URL) async -> Histogram? {
        if let hit = histograms[id] { return hit }
        if let running = histogramTasks[id] { return await running.value }

        let task = Task<Histogram?, Never>.detached(priority: .utility) {
            guard let image = ThumbnailDecoder.decode(url: url, maxPixelSize: 256) else {
                return nil
            }
            return Histogram.make(from: image)
        }
        histogramTasks[id] = task
        let histogram = await task.value
        histogramTasks[id] = nil

        if let histogram { histograms[id] = histogram }
        return histogram
    }

    /// Native-resolution decode of one frame, for true 1:1 detail when the Preview
    /// stage is zoomed (the fit view stays on the small, byte-budgeted thumbnail).
    /// Holds only the latest requested frame, so memory stays bounded to a single
    /// image regardless of how many frames the user zooms into.
    func fullResolution(forFrameID id: String, url: URL) async -> CGImage? {
        if fullResID == id, let cached = fullResImage { return cached }

        // Claim the slot synchronously (before the await) so a newer request for a
        // different frame can supersede this one.
        fullResID = id
        fullResImage = nil
        let task = Task<CGImage?, Never>.detached(priority: .userInitiated) {
            // A max-pixel far above any real sensor never upscales — ImageIO caps
            // at the image's own size — so this yields the native image, oriented.
            ThumbnailDecoder.decode(url: url, maxPixelSize: 100_000)
        }
        let image = await task.value
        // Only keep the result if we're still the frame the stage wants.
        if fullResID == id { fullResImage = image }
        return image
    }

    // MARK: Eviction bookkeeping

    private func store(_ key: Key, _ image: CGImage) {
        // Replacing an existing key: drop its old byte count first.
        if let old = sizes[key] { residentBytes -= old }
        let bytes = image.bytesPerRow * image.height
        cached[key] = image
        sizes[key] = bytes
        residentBytes += bytes
        touch(key)
        // Evict oldest until BOTH the byte budget and the count backstop hold —
        // but always keep the entry we just stored (`order.count > 1`), so a single
        // image larger than the whole budget can't spin forever.
        while (residentBytes > byteBudget || order.count > capacity), order.count > 1 {
            evictOldest()
        }
    }

    private func evictOldest() {
        let oldest = order.removeFirst()
        if let bytes = sizes.removeValue(forKey: oldest) { residentBytes -= bytes }
        cached[oldest] = nil
    }

    private func touch(_ key: Key) {
        if let i = order.firstIndex(of: key) {
            order.remove(at: i)
        }
        order.append(key)
    }
}
