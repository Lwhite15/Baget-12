import SwiftUI
import UIKit

/// Product photos from store pages (used by Plate). Kept in memory while the app runs and on disk via URLCache.
@MainActor
final class ImageCache {
    static let shared = ImageCache()
    private let memory = NSCache<NSURL, UIImage>()
    private var failed: Set<URL> = []
    private let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.urlCache = URLCache(memoryCapacity: 20 * 1024 * 1024, diskCapacity: 150 * 1024 * 1024)
        config.requestCachePolicy = .returnCacheDataElseLoad
        config.timeoutIntervalForRequest = 15
        return URLSession(configuration: config)
    }()

    init() { memory.countLimit = 200 }

    func cached(_ url: URL) -> UIImage? { memory.object(forKey: url as NSURL) }

    func load(_ url: URL) async -> UIImage? {
        if let img = cached(url) { return img }
        if failed.contains(url) { return nil }
        var req = URLRequest(url: url)
        req.setValue("image/avif,image/webp,image/jpeg,image/png,image/*;q=0.8", forHTTPHeaderField: "Accept")
        guard let (data, resp) = try? await session.data(for: req),
              (resp as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? false,
              let raw = UIImage(data: data) else {
            failed.insert(url)
            return nil
        }
        // Decode off the main thread at display size, so scrolling stays smooth.
        let img = await Task.detached(priority: .userInitiated) { raw.preparingThumbnail(of: Self.fit(raw.size, max: 900)) ?? raw }.value
        memory.setObject(img, forKey: url as NSURL)
        return img
    }

    nonisolated private static func fit(_ s: CGSize, max m: CGFloat) -> CGSize {
        let scale = min(1, m / max(s.width, s.height, 1))
        return CGSize(width: s.width * scale, height: s.height * scale)
    }
}
