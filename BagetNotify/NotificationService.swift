import UserNotifications
import UIKit

/// Runs for a moment when a notification arrives: downloads the find's product photo and attaches it,
/// so the notification shows the item itself. If anything fails, the text-only notification goes through as is.
final class NotificationService: UNNotificationServiceExtension {
    private var handler: ((UNNotificationContent) -> Void)?
    private var content: UNMutableNotificationContent?
    private let lock = NSLock()

    override func didReceive(_ request: UNNotificationRequest, withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void) {
        handler = contentHandler
        content = request.content.mutableCopy() as? UNMutableNotificationContent
        guard let content,
              let link = request.content.userInfo["image"] as? String,
              let url = URL(string: link), url.scheme == "https" else {
            finish()
            return
        }
        var req = URLRequest(url: url)
        req.timeoutInterval = 20
        URLSession.shared.dataTask(with: req) { [weak self] data, response, _ in
            defer { self?.finish() }
            guard let data, (response as? HTTPURLResponse)?.statusCode == 200,
                  let image = UIImage(data: data) else { return }
            // Re-encode as JPEG: notifications can't show every format stores use (WebP, for one).
            guard let jpeg = Self.fitted(image).jpegData(compressionQuality: 0.85) else { return }
            let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".jpg")
            guard (try? jpeg.write(to: file)) != nil,
                  let attachment = try? UNNotificationAttachment(identifier: "photo", url: file, options: nil) else { return }
            content.attachments = [attachment]
        }.resume()
    }

    override func serviceExtensionTimeWillExpire() {
        finish()
    }

    /// Hands the notification to iOS exactly once.
    private func finish() {
        lock.lock()
        let h = handler, c = content
        handler = nil
        lock.unlock()
        if let h, let c { h(c) }
    }

    /// Big photos are scaled down to keep the attachment small (extensions have tight memory limits).
    private static func fitted(_ image: UIImage, maxSide: CGFloat = 1200) -> UIImage {
        let side = max(image.size.width, image.size.height)
        guard side > maxSide else { return image }
        let scale = maxSide / side
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in image.draw(in: CGRect(origin: .zero, size: size)) }
    }
}
