import CoreGraphics
import CoreVideo
import Foundation
import SwiftUI
import Vision

/// A plain sRGB colour, 0...255, that can go into hashable, sendable settings.
struct Swatch: Hashable, Sendable {
    var r: Double, g: Double, b: Double

    static let white = Swatch(r: 255, g: 255, b: 255)

    init(r: Double, g: Double, b: Double) {
        self.r = r; self.g = g; self.b = b
    }

    init(_ color: Color) {
        let c = color.rgb255
        self.init(r: c.r, g: c.g, b: c.b)
    }

    var rgb: (r: Double, g: Double, b: Double) { (r, g, b) }
}

/// Finds the main subject of a photo on-device with Apple's Vision framework, the same model behind
/// "Lift subject from background" in Photos. Nothing is uploaded.
enum SubjectMask {
    private static let lock = NSLock()
    private static var cache: [String: [Float]] = [:]
    private static var order: [String] = []

    /// Per-pixel subject opacity, 0...1, matching `image` row for row from the top.
    /// `cacheKey` lets the live preview reuse the mask while sliders move.
    static func alpha(for image: CGImage, cacheKey: String? = nil) throws -> [Float] {
        let key = cacheKey.map { "\($0)#\(image.width)x\(image.height)" }
        if let key {
            lock.lock()
            let hit = cache[key]
            lock.unlock()
            if let hit { return hit }
        }
        let mask = try detect(image)
        if let key {
            lock.lock()
            cache[key] = mask
            order.append(key)
            while order.count > 4 { cache[order.removeFirst()] = nil }
            lock.unlock()
        }
        return mask
    }

    private static func detect(_ image: CGImage) throws -> [Float] {
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        let request = VNGenerateForegroundInstanceMaskRequest()
        do { try handler.perform([request]) } catch {
            throw ToolError("Subject detection isn't available on this Mac (\(error.localizedDescription)). Try Solid colour instead.")
        }
        guard let observation = request.results?.first, !observation.allInstances.isEmpty else {
            throw ToolError("Couldn't find a clear subject in this image. Try Solid colour instead.")
        }
        let buffer = try observation.generateScaledMaskForImage(forInstances: observation.allInstances, from: handler)
        return try read(buffer, width: image.width, height: image.height)
    }

    /// Copies a one-channel float mask out of a pixel buffer, resampling if its size differs.
    private static func read(_ buffer: CVPixelBuffer, width: Int, height: Int) throws -> [Float] {
        guard CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_OneComponent32Float else {
            throw ToolError("Subject detection returned an unexpected mask.")
        }
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { throw ToolError("Couldn't read the subject mask.") }
        let mw = CVPixelBufferGetWidth(buffer), mh = CVPixelBufferGetHeight(buffer)
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        var out = [Float](repeating: 0, count: width * height)
        for y in 0..<height {
            let sy = mh == height ? y : min(y * mh / height, mh - 1)
            let row = base.advanced(by: sy * stride).assumingMemoryBound(to: Float.self)
            for x in 0..<width {
                let sx = mw == width ? x : min(x * mw / width, mw - 1)
                out[y * width + x] = min(max(row[sx], 0), 1)
            }
        }
        return out
    }
}

extension Pixels {
    /// Grows (`shift` > 0) or shrinks the edge of a mask by about `shift` pixels, then softens it by `feather` pixels.
    func refine(_ mask: [Float], shift: Double, feather: Double) -> [Float] {
        var a = mask
        let r = Int((abs(shift) * 2).rounded())
        if r > 0 {
            let blurred = boxBlur(a, radius: r)
            a = shift > 0 ? blurred.map { min($0 * 2, 1) } : blurred.map { max($0 * 2 - 1, 0) }
        }
        let f = Int(feather.rounded())
        if f > 0 { a = boxBlur(a, radius: f) }
        return a
    }

    /// Replaces the background colour bleeding into semi-transparent edge pixels with colour borrowed
    /// from the solid subject next to them, so hair and soft edges don't carry a halo onto a new backdrop.
    mutating func cleanEdges(radius: Int) {
        let n = count
        var wr = [Float](repeating: 0, count: n), wg = wr, wb = wr, ww = wr
        for i in 0..<n {
            let c = color(i)
            guard c.a > 0 else { continue }
            let a2 = Float(c.a * c.a), w = a2 * a2
            ww[i] = w; wr[i] = Float(c.r) * w; wg[i] = Float(c.g) * w; wb[i] = Float(c.b) * w
        }
        wr = boxBlur(wr, radius: radius); wg = boxBlur(wg, radius: radius)
        wb = boxBlur(wb, radius: radius); ww = boxBlur(ww, radius: radius)
        for i in 0..<n {
            let c = color(i)
            guard c.a > 0.01, c.a < 0.97, ww[i] > 1e-4 else { continue }
            let t = c.a * c.a
            let er = Double(wr[i] / ww[i]), eg = Double(wg[i] / ww[i]), eb = Double(wb[i] / ww[i])
            set(i, r: er + (c.r - er) * t, g: eg + (c.g - eg) * t, b: eb + (c.b - eb) * t, a: c.a)
        }
    }

    /// Composites the image onto a solid colour.
    mutating func fill(_ c: Swatch) {
        for i in 0..<count {
            let o = i * 4
            let k = 1 - Double(data[o + 3]) / 255
            data[o] = UInt8(min(Double(data[o]) + c.r * k, 255))
            data[o + 1] = UInt8(min(Double(data[o + 1]) + c.g * k, 255))
            data[o + 2] = UInt8(min(Double(data[o + 2]) + c.b * k, 255))
            data[o + 3] = 255
        }
    }

    /// The cut-out's bounds with some breathing room, for cropping.
    func subjectBounds(padding: Double) -> CGRect? {
        opaqueBounds().map {
            $0.insetBy(dx: -padding, dy: -padding).intersection(CGRect(x: 0, y: 0, width: width, height: height)).integral
        }
    }
}
