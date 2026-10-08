import SwiftUI
import UIKit
import Vision
import CoreImage
import CryptoKit

/// A product photo ready to show. `lifted` means the product was cut out of its background
/// (transparent around it), so it sits on the app's own tile; otherwise it's the photo as-is.
struct ProductPhoto {
    let image: UIImage
    let lifted: Bool
}

/// Product photos from store pages (used by Plate). The cleaned-up version is cached on disk,
/// so the cut-out runs once per photo, not every time a tile appears.
@MainActor
final class ImageCache {
    static let shared = ImageCache()
    private let memory = NSCache<NSURL, Box>()
    private var failed: Set<URL> = []
    private var inFlight: [URL: Task<ProductPhoto?, Never>] = [:]
    private final class Box { let photo: ProductPhoto; init(_ p: ProductPhoto) { photo = p } }

    private let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.urlCache = URLCache(memoryCapacity: 10 * 1024 * 1024, diskCapacity: 100 * 1024 * 1024)
        config.requestCachePolicy = .returnCacheDataElseLoad
        config.timeoutIntervalForRequest = 15
        return URLSession(configuration: config)
    }()

    nonisolated private static let dir: URL = {
        let d = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("product-photos", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()

    init() { memory.countLimit = 150 }

    func cached(_ url: URL) -> ProductPhoto? { memory.object(forKey: url as NSURL)?.photo }

    func load(_ url: URL) async -> ProductPhoto? {
        if let hit = cached(url) { return hit }
        if failed.contains(url) { return nil }
        if let t = inFlight[url] { return await t.value }
        let session = self.session
        let task = Task<ProductPhoto?, Never> {
            let key = Self.key(url)
            // Already cleaned up on an earlier run?
            if let p = await Task.detached(priority: .userInitiated, operation: { Self.readDisk(key) }).value { return p }
            var req = URLRequest(url: url)
            req.setValue("image/jpeg,image/png,image/webp,image/*;q=0.8", forHTTPHeaderField: "Accept")
            guard let (data, resp) = try? await session.data(for: req),
                  (resp as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? false else { return nil }
            return await Task.detached(priority: .userInitiated) { Self.process(data, key: key) }.value
        }
        inFlight[url] = task
        let photo = await task.value
        inFlight[url] = nil
        if let photo { memory.setObject(Box(photo), forKey: url as NSURL) } else { failed.insert(url) }
        return photo
    }

    // MARK: Off the main thread

    nonisolated private static func key(_ url: URL) -> String {
        SHA256.hash(data: Data(url.absoluteString.utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    nonisolated private static func readDisk(_ key: String) -> ProductPhoto? {
        let lifted = dir.appendingPathComponent("\(key)-cut.png")
        if let img = UIImage(contentsOfFile: lifted.path) { return ProductPhoto(image: img, lifted: true) }
        let flat = dir.appendingPathComponent("\(key)-flat.jpg")
        if let img = UIImage(contentsOfFile: flat.path) { return ProductPhoto(image: img, lifted: false) }
        return nil
    }

    /// Downsizes, then tries to cut the product out of its background. Saves whichever result it gets.
    nonisolated private static func process(_ data: Data, key: String) -> ProductPhoto? {
        guard let raw = UIImage(data: data), raw.size.width >= 120, raw.size.height >= 120 else { return nil }
        let img = raw.preparingThumbnail(of: fit(raw.size, max: 1000)) ?? raw
        if let cut = lift(img) {
            if let png = cut.pngData() { try? png.write(to: dir.appendingPathComponent("\(key)-cut.png"), options: .atomic) }
            return ProductPhoto(image: cut, lifted: true)
        }
        let flat = trimWhite(img) ?? img
        if let jpg = flat.jpegData(compressionQuality: 0.85) { try? jpg.write(to: dir.appendingPathComponent("\(key)-flat.jpg"), options: .atomic) }
        return ProductPhoto(image: flat, lifted: false)
    }

    /// Cuts the main subject out with Vision, cropped tight to it. Nil when there's no clear subject
    /// (or the subject fills the whole frame, like a scene, which looks better left as a photo).
    nonisolated private static func lift(_ img: UIImage) -> UIImage? {
        guard let cg = img.cgImage else { return nil }
        let request = VNGenerateForegroundInstanceMaskRequest()
        let handler = VNImageRequestHandler(cgImage: cg, orientation: .up)
        guard (try? handler.perform([request])) != nil,
              let obs = request.results?.first, !obs.allInstances.isEmpty,
              let buffer = try? obs.generateMaskedImage(ofInstances: obs.allInstances, from: handler, croppedToInstancesExtent: true)
        else { return nil }
        let w = CVPixelBufferGetWidth(buffer), h = CVPixelBufferGetHeight(buffer)
        let share = Double(w * h) / Double(max(1, cg.width * cg.height))
        guard share > 0.04, share < 0.97 else { return nil }
        let ci = CIImage(cvPixelBuffer: buffer)
        guard let out = CIContext(options: [.useSoftwareRenderer: false]).createCGImage(ci, from: ci.extent) else { return nil }
        return UIImage(cgImage: out)
    }

    /// Crops away plain white or near-white margins so the product fills the tile.
    nonisolated private static func trimWhite(_ img: UIImage) -> UIImage? {
        guard let cg = img.cgImage else { return nil }
        let w = cg.width, h = cg.height
        var px = [UInt8](repeating: 0, count: w * h * 4)
        guard let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        func blank(_ x: Int, _ y: Int) -> Bool {
            let i = (y * w + x) * 4
            return px[i] > 242 && px[i + 1] > 242 && px[i + 2] > 242
        }
        var minX = w, minY = h, maxX = -1, maxY = -1
        for y in stride(from: 0, to: h, by: 2) {
            for x in stride(from: 0, to: w, by: 2) where !blank(x, y) {
                minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        guard maxX > minX, maxY > minY else { return nil }
        let pad = Int(Double(max(maxX - minX, maxY - minY)) * 0.04)
        let rect = CGRect(x: max(0, minX - pad), y: max(0, minY - pad),
                          width: min(w, maxX + pad) - max(0, minX - pad), height: min(h, maxY + pad) - max(0, minY - pad))
        guard rect.width < CGFloat(w) * 0.98 || rect.height < CGFloat(h) * 0.98, let cropped = cg.cropping(to: rect) else { return nil }
        return UIImage(cgImage: cropped)
    }

    nonisolated private static func fit(_ s: CGSize, max m: CGFloat) -> CGSize {
        let scale = min(1, m / max(s.width, s.height, 1))
        return CGSize(width: s.width * scale, height: s.height * scale)
    }
}
