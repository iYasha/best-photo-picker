import CoreGraphics

// MARK: - Histogram
//
// Per-channel tone distribution of a frame, for the Preview info panel. Counts
// pixels into `binCount` tonal buckets per channel (bin 0 = shadows … last =
// highlights). Built from the small, already-downsampled **display** image
// (sRGB) — so it shows the tones the user actually sees on the stage, which is
// the right reference for culling, not the RAW-linear data.
//
// Pure value type + a pure `make(from:)`. `ImageCache` owns decoding, threading,
// and memoisation (it computes one off a background thread and caches it by
// frame id); this type just bins pixels.
struct Histogram: Sendable, Equatable {
    /// Number of tonal buckets across 0…255. 64 reads cleanly in a ~232px card.
    static let binCount = 64

    var red: [Int]
    var green: [Int]
    var blue: [Int]
    var luma: [Int]

    /// Tallest bin across R/G/B — the shared vertical scale for the RGB chart so
    /// the three curves stay comparable. Never zero (avoids divide-by-zero).
    var rgbPeak: Int { max(red.max() ?? 0, green.max() ?? 0, blue.max() ?? 0, 1) }
    /// Tallest luma bin — the luma chart's vertical scale.
    var lumaPeak: Int { max(luma.max() ?? 0, 1) }
}

extension Histogram {
    /// Bin `image` into `binCount` buckets per channel. Downscales to at most
    /// `sample` px on the longest edge first so cost is fixed regardless of the
    /// source size (the input is already a thumbnail, but this pins it). Returns
    /// `nil` if a bitmap context can't be created.
    static func make(from image: CGImage, sample: Int = 160) -> Histogram? {
        let srcW = image.width, srcH = image.height
        guard srcW > 0, srcH > 0 else { return nil }

        let scale = min(1, Double(sample) / Double(max(srcW, srcH)))
        let w = max(1, Int((Double(srcW) * scale).rounded()))
        let h = max(1, Int((Double(srcH) * scale).rounded()))
        let bytesPerRow = w * 4

        // Draw the image into a packed RGBX8 buffer. `noneSkipLast` = opaque, no
        // premultiply, so the channel bytes are the straight sRGB values we bin.
        var data = [UInt8](repeating: 0, count: bytesPerRow * h)
        let drew = data.withUnsafeMutableBytes { raw -> Bool in
            guard let ctx = CGContext(
                data: raw.baseAddress,
                width: w, height: h,
                bitsPerComponent: 8,
                bytesPerRow: bytesPerRow,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
            ) else { return false }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard drew else { return nil }

        let bins = binCount
        var r = [Int](repeating: 0, count: bins)
        var g = [Int](repeating: 0, count: bins)
        var b = [Int](repeating: 0, count: bins)
        var l = [Int](repeating: 0, count: bins)

        var i = 0
        while i < data.count {
            let rv = Int(data[i]), gv = Int(data[i + 1]), bv = Int(data[i + 2])
            r[rv * bins / 256] += 1
            g[gv * bins / 256] += 1
            b[bv * bins / 256] += 1
            // Rec.601 luma, integer maths.
            let lum = (rv * 299 + gv * 587 + bv * 114) / 1000
            l[min(bins - 1, lum * bins / 256)] += 1
            i += 4
        }
        return Histogram(red: r, green: g, blue: b, luma: l)
    }
}
