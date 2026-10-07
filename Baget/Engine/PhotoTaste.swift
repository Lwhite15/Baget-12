import UIKit
import Vision

/// What an agent picks up from a taste photo.
struct PhotoReading {
    var summary: String
    var traits: [String]
    var makers: [String] = []
    var creators: [String] = []
    /// True when Claude read it; false for the on-device reading.
    var byClaude = false
}

/// Reads a taste photo entirely on the phone: Apple's Vision image classifier for what's in it,
/// plus a color pass for the palette. Nothing is uploaded.
enum PhotoTaste {
    /// Labels that say nothing about taste, or that describe people. Never kept.
    private static let ignored: Set<String> = [
        "people", "person", "adult", "child", "baby", "face", "selfie", "portrait", "crowd", "hand", "finger",
        "structure", "indoor", "outdoor", "document", "text", "screenshot", "material", "object", "illustration",
        "machine", "consumer electronics", "electronics", "sky", "room", "interior room",
    ]

    static func read(_ image: UIImage, for agent: Agent) async -> PhotoReading {
        let upright = normalized(image, maxSide: 1024)
        let labels = await classify(upright)
        let colors = dominantColors(upright)
        var traits: [String] = []
        for t in labels + colors where !traits.contains(t) { traits.append(t) }
        traits = Array(traits.prefix(8))
        let summary: String
        if traits.isEmpty {
            summary = "I couldn't make much out of that one. Tell me what you love about it and I'll remember."
        } else {
            let lead = labels.prefix(3).joined(separator: ", ")
            let palette = colors.joined(separator: " and ")
            switch (lead.isEmpty, palette.isEmpty) {
            case (false, false): summary = "I'm seeing \(lead), mostly in \(palette). I'll hunt \(agent.mission.label.lowercased()) with that energy."
            case (false, true): summary = "I'm seeing \(lead). I'll hunt \(agent.mission.label.lowercased()) with that energy."
            default: summary = "Love the palette: \(palette). I'll look for \(agent.mission.label.lowercased()) in those tones."
            }
        }
        return PhotoReading(summary: summary, traits: traits)
    }

    /// Redraws the photo upright and no larger than `maxSide`, so analysis and storage stay light.
    static func normalized(_ image: UIImage, maxSide: CGFloat) -> UIImage {
        let scale = min(1, maxSide / max(image.size.width, image.size.height))
        let size = CGSize(width: max(1, image.size.width * scale), height: max(1, image.size.height * scale))
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in image.draw(in: CGRect(origin: .zero, size: size)) }
    }

    private static func classify(_ image: UIImage) async -> [String] {
        guard let cg = image.cgImage else { return [] }
        return await withCheckedContinuation { (cont: CheckedContinuation<[String], Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                let request = VNClassifyImageRequest()
                let handler = VNImageRequestHandler(cgImage: cg, options: [:])
                do { try handler.perform([request]) } catch { cont.resume(returning: []); return }
                let names = (request.results ?? [])
                    .filter { $0.confidence > 0.3 }
                    .map { $0.identifier.replacingOccurrences(of: "_", with: " ").lowercased() }
                    .filter { !ignored.contains($0) }
                cont.resume(returning: Array(names.prefix(6)))
            }
        }
    }

    /// The two or three colors that cover most of the photo, by name.
    static func dominantColors(_ image: UIImage) -> [String] {
        guard let cg = image.cgImage else { return [] }
        let w = 32, h = 32
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        let drawn: Bool = pixels.withUnsafeMutableBytes { buf -> Bool in
            guard let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard drawn else { return [] }
        var counts: [String: Int] = [:]
        for i in stride(from: 0, to: pixels.count, by: 4) {
            counts[colorName(Double(pixels[i]), Double(pixels[i + 1]), Double(pixels[i + 2])), default: 0] += 1
        }
        let total = Double(w * h)
        return counts.sorted { $0.value > $1.value }.filter { Double($0.value) / total > 0.12 }.prefix(3).map { $0.key }
    }

    static func colorName(_ r: Double, _ g: Double, _ b: Double) -> String {
        let R = r / 255, G = g / 255, B = b / 255
        let mx = max(R, G, B), mn = min(R, G, B), l = (mx + mn) / 2, d = mx - mn
        let s = d == 0 ? 0 : d / (1 - abs(2 * l - 1))
        var hue = 0.0
        if d > 0 {
            if mx == R { hue = 60 * ((G - B) / d).truncatingRemainder(dividingBy: 6) }
            else if mx == G { hue = 60 * ((B - R) / d + 2) }
            else { hue = 60 * ((R - G) / d + 4) }
            if hue < 0 { hue += 360 }
        }
        if l < 0.13 { return "black" }
        if l > 0.9 && s < 0.25 { return "white" }
        if s < 0.14 { return l > 0.6 ? "light grey" : "grey" }
        switch hue {
        case ..<15, 345...: return l < 0.35 ? "burgundy" : "red"
        case ..<40: return l < 0.42 ? "brown" : (s < 0.45 && l > 0.6 ? "beige" : "orange")
        case ..<65: return l < 0.42 ? "olive" : (s < 0.5 && l > 0.65 ? "cream" : "yellow")
        case ..<170: return l < 0.3 ? "forest green" : "green"
        case ..<195: return "teal"
        case ..<250: return l < 0.3 ? "navy" : "blue"
        case ..<290: return "purple"
        default: return "pink"
        }
    }
}
