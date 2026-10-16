import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

enum ImageKit {
    static let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

    static let writableTypes: Set<String> = Set((CGImageDestinationCopyTypeIdentifiers() as? [String]) ?? [])

    static func source(_ url: URL) throws -> CGImageSource {
        guard let s = CGImageSourceCreateWithURL(url as CFURL, nil), CGImageSourceGetCount(s) > 0 else {
            throw ToolError("\(url.lastPathComponent) isn't an image OpenRecast can read.")
        }
        return s
    }

    static func properties(_ s: CGImageSource) -> [CFString: Any] {
        (CGImageSourceCopyPropertiesAtIndex(s, 0, nil) as? [CFString: Any]) ?? [:]
    }

    static func pixelSize(_ s: CGImageSource) -> (width: Int, height: Int) {
        let p = properties(s)
        return (p[kCGImagePropertyPixelWidth] as? Int ?? 0, p[kCGImagePropertyPixelHeight] as? Int ?? 0)
    }

    static func orientation(_ s: CGImageSource) -> Int {
        properties(s)[kCGImagePropertyOrientation] as? Int ?? 1
    }

    static func hasAlpha(_ s: CGImageSource) -> Bool {
        properties(s)[kCGImagePropertyHasAlpha] as? Bool ?? false
    }

    /// Decodes an image upright (EXIF orientation applied), optionally downscaled. Never upscales.
    static func load(_ url: URL, maxPixel: Int? = nil) throws -> CGImage {
        let s = try source(url)
        let size = pixelSize(s)
        let longest = max(size.width, size.height, 1)
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: min(maxPixel ?? longest, longest),
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(s, 0, opts as CFDictionary) else {
            throw ToolError("Couldn't decode \(url.lastPathComponent).")
        }
        return image
    }

    static func write(_ image: CGImage, to url: URL, type: UTType, quality: Double? = nil,
                      properties: [CFString: Any] = [:]) throws {
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil) else {
            throw ToolError("This Mac can't write \(type.preferredFilenameExtension?.uppercased() ?? "that") files.")
        }
        var props = properties
        if let quality { props[kCGImageDestinationLossyCompressionQuality] = quality }
        CGImageDestinationAddImage(dest, image, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw ToolError("Couldn't save \(url.lastPathComponent).") }
    }

    /// Composites onto white, for formats without transparency.
    static func flatten(_ image: CGImage) -> CGImage {
        let w = image.width, h = image.height
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: sRGB, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { return image }
        let rect = CGRect(x: 0, y: 0, width: w, height: h)
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(rect)
        ctx.draw(image, in: rect)
        return ctx.makeImage() ?? image
    }
}

/// An editable RGBA8 (premultiplied) pixel buffer.
struct Pixels {
    let width: Int
    let height: Int
    var data: [UInt8]

    init(_ image: CGImage) {
        let w = image.width, h = image.height
        var buffer = [UInt8](repeating: 0, count: w * h * 4)
        buffer.withUnsafeMutableBytes { raw in
            let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                space: ImageKit.sRGB, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            ctx?.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        width = w
        height = h
        data = buffer
    }

    var count: Int { width * height }

    func makeImage() throws -> CGImage {
        guard let provider = CGDataProvider(data: Data(data) as CFData),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                                  bytesPerRow: width * 4, space: ImageKit.sRGB,
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
        else { throw ToolError("Couldn't build the output image.") }
        return image
    }

    /// Straight (un-premultiplied) colour of pixel `i`, 0...255, and its alpha 0...1.
    @inline(__always)
    func color(_ i: Int) -> (r: Double, g: Double, b: Double, a: Double) {
        let o = i * 4
        let a = Double(data[o + 3]) / 255
        guard a > 0 else { return (0, 0, 0, 0) }
        return (Double(data[o]) / a, Double(data[o + 1]) / a, Double(data[o + 2]) / a, a)
    }

    @inline(__always)
    mutating func set(_ i: Int, r: Double, g: Double, b: Double, a: Double) {
        let o = i * 4
        let a = min(max(a, 0), 1)
        data[o] = UInt8(min(max(r * a, 0), 255))
        data[o + 1] = UInt8(min(max(g * a, 0), 255))
        data[o + 2] = UInt8(min(max(b * a, 0), 255))
        data[o + 3] = UInt8(a * 255)
    }

    /// Multiplies each pixel's alpha by `alpha[i]`.
    mutating func multiplyAlpha(_ alpha: [Float]) {
        for i in 0..<count where alpha[i] < 1 {
            let o = i * 4, f = max(alpha[i], 0)
            for c in 0..<4 { data[o + c] = UInt8(Float(data[o + c]) * f) }
        }
    }

    /// Separable box blur of a per-pixel mask.
    func boxBlur(_ src: [Float], radius r: Int) -> [Float] {
        guard r > 0 else { return src }
        let w = width, h = height, k = Float(2 * r + 1)
        var tmp = src, out = src
        for y in 0..<h {
            let row = y * w
            var sum: Float = 0
            for x in -r...r { sum += src[row + min(max(x, 0), w - 1)] }
            for x in 0..<w {
                tmp[row + x] = sum / k
                sum += src[row + min(x + r + 1, w - 1)] - src[row + max(x - r, 0)]
            }
        }
        for x in 0..<w {
            var sum: Float = 0
            for y in -r...r { sum += tmp[min(max(y, 0), h - 1) * w + x] }
            for y in 0..<h {
                out[y * w + x] = sum / k
                sum += tmp[min(y + r + 1, h - 1) * w + x] - tmp[max(y - r, 0) * w + x]
            }
        }
        return out
    }

    /// Bounding box of pixels that aren't (nearly) transparent, in CGImage coordinates.
    func opaqueBounds(threshold: UInt8 = 12) -> CGRect? {
        var minX = width, minY = height, maxX = -1, maxY = -1
        for y in 0..<height {
            for x in 0..<width where data[(y * width + x) * 4 + 3] > threshold {
                minX = min(minX, x); maxX = max(maxX, x)
                minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        guard maxX >= minX else { return nil }
        return CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
    }
}
