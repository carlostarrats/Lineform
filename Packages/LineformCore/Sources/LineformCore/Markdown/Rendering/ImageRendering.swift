import CryptoKit
import Foundation
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Stable, compact cache key for a downscaled image attachment: url + modification date +
/// fitted box + scale (mirrors `MermaidCacheKey`). Two different files at the same key would
/// collide only if their paths, mtimes, and fit box were all identical, which is precisely
/// when a fresh load is unnecessary — an unchanged file's raster is safe to reuse.
public enum ImageAttachmentCacheKey {
    public static func key(url: URL, modificationDate: Date?, maxSize: CGSize, scale: CGFloat) -> String {
        let mtime = modificationDate?.timeIntervalSince1970 ?? -1
        let material = "\(url.standardizedFileURL.path)\n\(mtime)\n\(maxSize.width)x\(maxSize.height)\n\(scale)"
        let digest = SHA256.hash(data: Data(material.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

/// Abstracts local-image-file loading so the (future) block renderer never touches the
/// filesystem directly and tests can inject a fake without real files.
public protocol ImageAttachmentProviding: AnyObject {
    /// The image (`NSImage` / `UIImage`) for a resolved local image URL, scaled to FIT within `maxSize` (aspect
    /// preserved, downscale-only — never upscaled past native size), cached. `nil` on failure
    /// (missing / unreadable / corrupt / out-of-scope). `maxSize` is typically
    /// `(columnWidth, ImageFit.maxHeight(...))`.
    func image(at url: URL, maxSize: CGSize, scale: CGFloat) -> PlatformImage?
}

/// A provider that never loads (images referenced in Markdown fall back to the placeholder).
/// Used by back-compat render conveniences and by tests that don't want image loading.
public final class DisabledImageAttachmentProvider: ImageAttachmentProviding {
    public init() {}

    public func image(at url: URL, maxSize: CGSize, scale: CGFloat) -> PlatformImage? {
        nil
    }
}

/// The single seam that reads local image files from disk. Loads, downscales to fit within
/// `maxSize` (never upscaling), and memory-caches the SMALL downscaled raster (not the
/// original) so the cache doesn't bloat on large source photos. Mirrors `MermaidImageProvider`.
public final class ImageAttachmentProvider: ImageAttachmentProviding {
    private let cache = NSCache<NSString, PlatformImage>()
    /// Failed loads are remembered too, keyed by url+mtime, so an unreadable/out-of-scope file
    /// isn't re-probed every preview pass — but a later mtime change (the file reappearing or
    /// being replaced) produces a fresh key and retries automatically (auto-heal).
    private let failureCache = NSCache<NSString, NSNumber>()

    public init() {
        cache.countLimit = ImageCacheBudget.countLimit
        cache.totalCostLimit = ImageCacheBudget.totalCostLimitBytes
        failureCache.countLimit = 200
    }

    public func image(at url: URL, maxSize: CGSize, scale: CGFloat) -> PlatformImage? {
        let modificationDate = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
        let key = ImageAttachmentCacheKey.key(url: url, modificationDate: modificationDate, maxSize: maxSize, scale: scale) as NSString

        if let cached = cache.object(forKey: key) { return cached }
        if failureCache.object(forKey: key) != nil { return nil }

        guard let source = Self.load(url) else {
            failureCache.setObject(true as NSNumber, forKey: key)
            return nil
        }

        let fitted = ImageFit.size(for: source.size, in: maxSize)
        guard fitted.width > 0, fitted.height > 0 else {
            failureCache.setObject(true as NSNumber, forKey: key)
            return nil
        }

        let downscaled = Self.downscale(source, to: fitted, scale: scale)

        cache.setObject(downscaled, forKey: key, cost: RasterImageCost.bytes(for: downscaled))
        return downscaled
    }

    /// macOS: `NSImage(contentsOf:)`. iOS: `UIImage(contentsOfFile:)`.
    private static func load(_ url: URL) -> PlatformImage? {
        #if os(macOS)
        NSImage(contentsOf: url)
        #else
        UIImage(contentsOfFile: url.path)
        #endif
    }

    /// `source` drawn at `fitted` points. macOS draws into a focus-locked `NSImage` (the screen's
    /// backing scale, as it always has; `scale` is not used). iOS draws with
    /// `UIGraphicsImageRenderer` at `scale` pixels per point.
    private static func downscale(_ source: PlatformImage, to fitted: CGSize, scale: CGFloat) -> PlatformImage {
        #if os(macOS)
        let downscaled = NSImage(size: fitted)
        downscaled.lockFocus()
        source.draw(
            in: CGRect(origin: .zero, size: fitted),
            from: CGRect(origin: .zero, size: source.size),
            operation: .copy,
            fraction: 1
        )
        downscaled.unlockFocus()
        return downscaled
        #else
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        return UIGraphicsImageRenderer(size: fitted, format: format).image { _ in
            source.draw(in: CGRect(origin: .zero, size: fitted))
        }
        #endif
    }
}
