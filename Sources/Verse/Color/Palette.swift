import AppKit
import SwiftUI

/// All vibe-mode colors derive from the album art's dominant hue.
struct Palette: Equatable {
    /// Dominant hue at ~12% lightness — dark enough to blend with the
    /// physical notch, tinted enough to feel alive.
    var background: Color
    /// Full-bright tint for the current lyric line.
    var bright: Color
    /// Mid-tone for neighbor lines (used at ~35% opacity by callers).
    var mid: Color
    /// Muted tint for secondary UI (timestamps, icons).
    var muted: Color
    /// Accent for the underline tracer and scrubber fill.
    var accent: Color

    static let fallback = Palette(
        background: Color(hue: 0.66, saturation: 0.25, brightness: 0.13),
        bright: Color(hue: 0.66, saturation: 0.10, brightness: 0.98),
        mid: Color(hue: 0.66, saturation: 0.15, brightness: 0.85),
        muted: Color(hue: 0.66, saturation: 0.20, brightness: 0.60),
        accent: Color(hue: 0.66, saturation: 0.55, brightness: 0.90)
    )

    /// Extract the dominant color of album art (downsampled histogram —
    /// cheap k-means-ish quantization) and derive the full palette.
    static func from(artwork: NSImage?) -> Palette {
        guard let artwork,
              let tiff = artwork.tiffRepresentation,
              let source = NSBitmapImageRep(data: tiff) else { return .fallback }

        // Downsample to at most 32x32 for speed.
        let sw = min(source.pixelsWide, 32), sh = min(source.pixelsHigh, 32)
        guard sw > 0, sh > 0,
              let small = NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: sw, pixelsHigh: sh,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                isPlanar: false, colorSpaceName: .deviceRGB,
                bytesPerRow: 0, bitsPerPixel: 0)
        else { return .fallback }

        NSGraphicsContext.saveGraphicsState()
        if let ctx = NSGraphicsContext(bitmapImageRep: small) {
            NSGraphicsContext.current = ctx
            artwork.draw(in: NSRect(x: 0, y: 0, width: sw, height: sh),
                         from: .zero, operation: .copy, fraction: 1.0)
            ctx.flushGraphics()
        }
        NSGraphicsContext.restoreGraphicsState()

        // Histogram over quantized hue buckets, weighted by saturation ×
        // mid-brightness so vivid colors win over near-black/near-white.
        var buckets = [Double](repeating: 0, count: 24)
        var bucketHue = [Double](repeating: 0, count: 24)
        var bucketSat = [Double](repeating: 0, count: 24)
        var grayWeight = 0.0, colorWeight = 0.0

        for y in 0..<sh {
            for x in 0..<sw {
                guard let c = small.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                let h = c.hueComponent, s = c.saturationComponent, b = c.brightnessComponent
                if s < 0.12 || b < 0.08 || b > 0.97 {
                    grayWeight += 1
                    continue
                }
                let weight = Double(s) * Double(1 - abs(b - 0.55))
                let idx = min(Int(h * 24), 23)
                buckets[idx] += weight
                bucketHue[idx] += Double(h) * weight
                bucketSat[idx] += Double(s) * weight
                colorWeight += 1
            }
        }

        // Mostly grayscale art → neutral dark palette.
        guard colorWeight > 8, let best = buckets.indices.max(by: { buckets[$0] < buckets[$1] }),
              buckets[best] > 0 else {
            return Palette(
                background: Color(white: 0.10),
                bright: Color(white: 0.98),
                mid: Color(white: 0.85),
                muted: Color(white: 0.55),
                accent: Color(white: 0.90)
            )
        }

        let hue = bucketHue[best] / buckets[best]
        let sat = min(max(bucketSat[best] / buckets[best], 0.25), 0.85)

        return Palette(
            background: Color(hue: hue, saturation: sat * 0.75, brightness: 0.16), // ≈12% lightness
            bright: Color(hue: hue, saturation: sat * 0.15, brightness: 0.99),
            mid: Color(hue: hue, saturation: sat * 0.30, brightness: 0.88),
            muted: Color(hue: hue, saturation: sat * 0.35, brightness: 0.62),
            accent: Color(hue: hue, saturation: sat, brightness: 0.92)
        )
    }
}

/// Per-album palette cache.
final class PaletteCache {
    private var store: [String: Palette] = [:]
    func palette(for key: String, artwork: NSImage?) -> Palette {
        // Don't cache until artwork exists — it often arrives a beat after
        // the track metadata, and we'd pin the fallback palette forever.
        guard let artwork else { return .fallback }
        if let hit = store[key] { return hit }
        let p = Palette.from(artwork: artwork)
        store[key] = p
        return p
    }
}
