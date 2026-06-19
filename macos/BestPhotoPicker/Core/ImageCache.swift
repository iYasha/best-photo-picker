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
// Eviction is a simple bounded FIFO on entry count — thumbnails are small and the
// working set (one screenful + a little) is modest, so a count cap is enough; no
// byte accounting or disk tier is needed for this slice (issue spec: in-memory is
// sufficient, disk optional).
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

    /// Cap on resident decoded thumbnails. ~600 small images is comfortably under a
    /// few hundred MB and covers many screenfuls of scrollback.
    private let capacity = 600

    /// Decoded results, newest-touched last (for FIFO-ish eviction).
    private var cached: [Key: CGImage] = [:]
    /// Insertion/access order of keys for eviction (front = oldest).
    private var order: [Key] = []
    /// Decodes currently running, so duplicate requests await the same `Task`.
    private var inFlight: [Key: Task<CGImage?, Never>] = [:]

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

    // MARK: Eviction bookkeeping

    private func store(_ key: Key, _ image: CGImage) {
        cached[key] = image
        touch(key)
        while order.count > capacity {
            let oldest = order.removeFirst()
            cached[oldest] = nil
        }
    }

    private func touch(_ key: Key) {
        if let i = order.firstIndex(of: key) {
            order.remove(at: i)
        }
        order.append(key)
    }
}
