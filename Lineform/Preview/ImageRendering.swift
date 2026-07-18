import AppKit
import CryptoKit

/// Stable, compact cache key for a downscaled image attachment: url + modification date +
/// fitted box + scale (mirrors `MermaidCacheKey`). Two different files at the same key would
/// collide only if their paths, mtimes, and fit box were all identical, which is precisely
/// when a fresh load is unnecessary — an unchanged file's raster is safe to reuse.
enum ImageAttachmentCacheKey {
    static func key(url: URL, modificationDate: Date?, maxSize: CGSize, scale: CGFloat) -> String {
        let mtime = modificationDate?.timeIntervalSince1970 ?? -1
        let material = "\(url.standardizedFileURL.path)\n\(mtime)\n\(maxSize.width)x\(maxSize.height)\n\(scale)"
        let digest = SHA256.hash(data: Data(material.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

/// Abstracts local-image-file loading so the (future) block renderer never touches the
/// filesystem directly and tests can inject a fake without real files.
protocol ImageAttachmentProviding: AnyObject {
    /// `NSImage` for a resolved local image URL, scaled to FIT within `maxSize` (aspect
    /// preserved, downscale-only — never upscaled past native size), cached. `nil` on failure
    /// (missing / unreadable / corrupt / out-of-scope). `maxSize` is typically
    /// `(columnWidth, ImageFit.maxHeight(...))`.
    func image(at url: URL, maxSize: CGSize, scale: CGFloat) -> NSImage?
}

/// A provider that never loads (images referenced in Markdown fall back to the placeholder).
/// Used by back-compat render conveniences and by tests that don't want image loading.
final class DisabledImageAttachmentProvider: ImageAttachmentProviding {
    func image(at url: URL, maxSize: CGSize, scale: CGFloat) -> NSImage? {
        nil
    }
}

/// The single seam that reads local image files from disk. Loads, downscales to fit within
/// `maxSize` (never upscaling), and memory-caches the SMALL downscaled raster (not the
/// original) so the cache doesn't bloat on large source photos. Mirrors `MermaidImageProvider`.
final class ImageAttachmentProvider: ImageAttachmentProviding {
    private let cache = NSCache<NSString, NSImage>()
    /// Failed loads are remembered too, keyed by url+mtime, so an unreadable/out-of-scope file
    /// isn't re-probed every preview pass — but a later mtime change (the file reappearing or
    /// being replaced) produces a fresh key and retries automatically (auto-heal).
    private let failureCache = NSCache<NSString, NSNumber>()

    init() {
        cache.countLimit = ImageCacheBudget.countLimit
        cache.totalCostLimit = ImageCacheBudget.totalCostLimitBytes
        failureCache.countLimit = 200
    }

    func image(at url: URL, maxSize: CGSize, scale: CGFloat) -> NSImage? {
        let modificationDate = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
        let key = ImageAttachmentCacheKey.key(url: url, modificationDate: modificationDate, maxSize: maxSize, scale: scale) as NSString

        if let cached = cache.object(forKey: key) { return cached }
        if failureCache.object(forKey: key) != nil { return nil }

        guard let source = NSImage(contentsOf: url) else {
            failureCache.setObject(true as NSNumber, forKey: key)
            return nil
        }

        let fitted = ImageFit.size(for: source.size, in: maxSize)
        guard fitted.width > 0, fitted.height > 0 else {
            failureCache.setObject(true as NSNumber, forKey: key)
            return nil
        }

        let downscaled = NSImage(size: fitted)
        downscaled.lockFocus()
        source.draw(
            in: CGRect(origin: .zero, size: fitted),
            from: CGRect(origin: .zero, size: source.size),
            operation: .copy,
            fraction: 1
        )
        downscaled.unlockFocus()

        cache.setObject(downscaled, forKey: key, cost: RasterImageCost.bytes(for: downscaled))
        return downscaled
    }
}
