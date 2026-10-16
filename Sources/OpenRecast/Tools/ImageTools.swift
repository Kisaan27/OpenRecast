import Foundation
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

extension Toolbox {
    static let image: [ToolInfo] = [
        ToolInfo("image-convert", "Convert Image", "JPG, PNG, HEIC, WebP, AVIF, TIFF, GIF, BMP and ICO.",
                 symbol: "arrow.triangle.2.circlepath", category: .image, types: [.image]) { ConvertImageTool() },
        ToolInfo("image-resize", "Resize", "Scale images down by percentage or to a maximum size.",
                 symbol: "arrow.up.left.and.arrow.down.right", category: .image, types: [.image], runLabel: "Resize") { ResizeImageTool() },
        ToolInfo("image-compress", "Compress", "Make photos smaller for email and the web.",
                 symbol: "arrow.down.right.and.arrow.up.left", category: .image, types: [.image], runLabel: "Compress") { CompressImageTool() },
        ToolInfo("image-strip", "Remove Metadata", "Strip location, camera and date info before you share.",
                 symbol: "location.slash", category: .image, types: [.image], runLabel: "Clean") { StripMetadataTool() },
    ]
}

enum ImageFormat: String, CaseIterable {
    case jpg, png, heic, webp, avif, tiff, gif, bmp, ico

    var title: String { rawValue.uppercased() }
    var lossy: Bool { [.jpg, .heic, .webp, .avif].contains(self) }
    var keepsAlpha: Bool { ![.jpg, .bmp].contains(self) }

    /// Formats macOS writes natively. WebP and AVIF go through ffmpeg.
    var type: UTType? {
        switch self {
        case .jpg: .jpeg
        case .png: .png
        case .heic: .heic
        case .tiff: .tiff
        case .gif: .gif
        case .bmp: .bmp
        case .ico: .ico
        case .webp, .avif: nil
        }
    }

    /// Encodes `input` into `dest`, keeping metadata where the format allows.
    func write(_ input: URL, to dest: URL, quality: Double, maxPixel: Int? = nil, _ ctx: JobContext) async throws {
        switch self {
        case .webp, .avif:
            // Decode upright with ImageIO first so HEIC, RAW and rotated photos all work.
            let tmp = Output.temporary(ext: "png")
            defer { try? FileManager.default.removeItem(at: tmp) }
            try ImageKit.write(ImageKit.load(input, maxPixel: maxPixel), to: tmp, type: .png)
            let args = self == .webp
                ? ["-c:v", "libwebp", "-quality", String(Int(quality * 100)), "-compression_level", "5"]
                : ["-c:v", "libaom-av1", "-still-picture", "1", "-crf", String(Int(52 - quality * 40)), "-cpu-used", "6",
                   "-vf", "scale=trunc(iw/2)*2:trunc(ih/2)*2", "-pix_fmt", "yuv420p"]
            try await FFmpeg.run(["-i", tmp.path] + args, output: dest, duration: nil, ctx)
        case .ico:
            // Icons must be square and at most 256 px: centre the image on a transparent canvas.
            let image = try ImageKit.load(input, maxPixel: min(maxPixel ?? 256, 256))
            let side = max(image.width, image.height)
            guard let canvas = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
                                         space: ImageKit.sRGB, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { throw ToolError("Couldn't build the icon.") }
            canvas.draw(image, in: CGRect(x: (side - image.width) / 2, y: (side - image.height) / 2,
                                          width: image.width, height: image.height))
            guard let square = canvas.makeImage() else { throw ToolError("Couldn't build the icon.") }
            try ImageKit.write(square, to: dest, type: .ico)
        default:
            guard let type else { return }
            let src = try ImageKit.source(input)
            let q: Double? = lossy ? quality : nil
            if maxPixel != nil || (!keepsAlpha && ImageKit.hasAlpha(src)) {
                var image = try ImageKit.load(input, maxPixel: maxPixel)
                if !keepsAlpha { image = ImageKit.flatten(image) }
                try ImageKit.write(image, to: dest, type: type, quality: q)
            } else {
                guard let d = CGImageDestinationCreateWithURL(dest as CFURL, type.identifier as CFString, 1, nil) else {
                    throw ToolError("This Mac can't write \(title) files.")
                }
                var opts: [CFString: Any] = [:]
                if let q { opts[kCGImageDestinationLossyCompressionQuality] = q }
                CGImageDestinationAddImageFromSource(d, src, 0, opts as CFDictionary)
                guard CGImageDestinationFinalize(d) else { throw ToolError("Couldn't save \(dest.lastPathComponent).") }
            }
        }
    }

    /// The file's own format, if it's one OpenRecast writes.
    static func of(_ url: URL) -> ImageFormat? {
        switch url.pathExtension.lowercased() {
        case "jpg", "jpeg": .jpg
        case "heic", "heif": .heic
        case "tif", "tiff": .tiff
        case let ext: ImageFormat(rawValue: ext)
        }
    }

    /// Best targets for a source file, most useful first.
    static func best(for url: URL) -> [ImageFormat] {
        switch of(url) {
        case .heic: [.jpg, .png, .webp]
        case .jpg: [.png, .webp, .heic]
        case .png: [.jpg, .webp, .ico]
        case .webp, .avif: [.jpg, .png]
        case .gif: [.png, .jpg, .webp]
        default: [.jpg, .png, .webp]
        }
    }

    /// The format to keep when the user didn't ask for a change.
    static func matching(_ url: URL) -> ImageFormat {
        switch url.pathExtension.lowercased() {
        case "jpg", "jpeg": .jpg
        case "heic", "heif": .heic
        case "tif", "tiff": .tiff
        case let ext: ImageFormat(rawValue: ext) ?? .png
        }
    }
}

@Observable
final class ConvertImageTool: FileTool {
    var format: ImageFormat = .png
    var quality = 0.85
    var choices: [ImageFormat] = ImageFormat.allCases
    var best: ImageFormat?

    var options: AnyView? { AnyView(Options(tool: self)) }

    func inputsChanged(_ inputs: [URL]) {
        guard let first = inputs.first else { choices = ImageFormat.allCases; best = nil; return }
        let recommended = ImageFormat.best(for: first)
        choices = FormatChoice.order(ImageFormat.allCases, best: recommended,
                                     hide: FormatChoice.shared(inputs, ImageFormat.of) ?? nil)
        best = choices.first
        if let best { format = best }
    }

    func run(_ inputs: [URL], _ ctx: JobContext) async throws -> JobOutput {
        var out = JobOutput()
        for (i, url) in inputs.enumerated() {
            try Task.checkCancellation()
            let dest = Output.url(for: url, in: ctx.folder(for: url), ext: format.rawValue)
            try await format.write(url, to: dest, quality: quality, ctx.part(i, of: inputs.count))
            out.files.append(dest)
            ctx.part(i, of: inputs.count).progress(1)
        }
        return out
    }

    struct Options: View {
        @Bindable var tool: ConvertImageTool
        var body: some View {
            VStack(alignment: .leading, spacing: 8) {
                OptionRow("Convert to") {
                    Chips(selection: $tool.format, options: tool.choices.map { ($0, $0.title) }, recommended: tool.best)
                }
                if tool.format.lossy {
                    OptionRow("Quality") { SliderRow(value: $tool.quality, range: 0.3...1) { "\(Int($0 * 100))%" } }
                }
            }
        }
    }
}

@Observable
final class ResizeImageTool: FileTool {
    var byPercent = true
    var percent = 50.0
    var longest = "1600"

    var options: AnyView? { AnyView(Options(tool: self)) }

    func validate(_ inputs: [URL]) -> String? {
        if !byPercent, (Int(longest) ?? 0) < 1 { return "Enter the longest side in pixels, like 1600." }
        return nil
    }

    func run(_ inputs: [URL], _ ctx: JobContext) async throws -> JobOutput {
        var out = JobOutput()
        for (i, url) in inputs.enumerated() {
            try Task.checkCancellation()
            let size = ImageKit.pixelSize(try ImageKit.source(url))
            let current = max(size.width, size.height)
            let target = byPercent ? Int(Double(current) * percent / 100) : min(Int(longest) ?? current, current)
            let format = ImageFormat.matching(url)
            let dest = Output.url(for: url, in: ctx.folder(for: url), suffix: " resized", ext: format.rawValue)
            try await format.write(url, to: dest, quality: 0.9, maxPixel: max(target, 1), ctx.part(i, of: inputs.count))
            out.files.append(dest)
            ctx.part(i, of: inputs.count).progress(1)
        }
        return out
    }

    struct Options: View {
        @Bindable var tool: ResizeImageTool
        var body: some View {
            VStack(alignment: .leading, spacing: 8) {
                OptionRow("Resize by") {
                    Chips(selection: $tool.byPercent, options: [(true, "Percentage"), (false, "Longest side")])
                }
                if tool.byPercent {
                    OptionRow("Scale") { SliderRow(value: $tool.percent, range: 5...100, step: 5) { "\(Int($0))%" } }
                } else {
                    OptionRow("Longest side") {
                        TextField("1600", text: $tool.longest).fieldStyle(width: 90)
                        Text("px").font(.system(size: 12)).foregroundStyle(Theme.muted)
                    }
                }
            }
        }
    }
}

@Observable
final class CompressImageTool: FileTool {
    var quality = 0.7
    var keepFormat = false

    var options: AnyView? { AnyView(Options(tool: self)) }

    func run(_ inputs: [URL], _ ctx: JobContext) async throws -> JobOutput {
        var out = JobOutput()
        for (i, url) in inputs.enumerated() {
            try Task.checkCancellation()
            let src = try ImageKit.source(url)
            var format: ImageFormat = keepFormat ? ImageFormat.matching(url) : (ImageKit.hasAlpha(src) ? .webp : .jpg)
            if !format.lossy { format = .jpg }
            let dest = Output.url(for: url, in: ctx.folder(for: url), suffix: " compressed", ext: format.rawValue)
            try await format.write(url, to: dest, quality: quality, ctx.part(i, of: inputs.count))
            if Output.size(dest) >= Output.size(url) {
                try? FileManager.default.removeItem(at: dest)
                out.notes.append("\(url.lastPathComponent): already as small as it gets, left unchanged")
            } else {
                out.files.append(dest)
                out.notes.append(Output.change(from: url, to: dest))
            }
        }
        return out
    }

    struct Options: View {
        @Bindable var tool: CompressImageTool
        var body: some View {
            VStack(alignment: .leading, spacing: 8) {
                OptionRow("Quality") { SliderRow(value: $tool.quality, range: 0.3...0.95) { "\(Int($0 * 100))%" } }
                OptionRow("Format") {
                    Chips(selection: $tool.keepFormat, options: [(false, "Best for size (JPG / WebP)"), (true, "Keep original")])
                }
            }
        }
    }
}

@Observable
final class StripMetadataTool: FileTool {
    var everything = true

    var options: AnyView? { AnyView(Options(tool: self)) }

    func run(_ inputs: [URL], _ ctx: JobContext) async throws -> JobOutput {
        var out = JobOutput()
        for (i, url) in inputs.enumerated() {
            try Task.checkCancellation()
            let src = try ImageKit.source(url)
            let typeID = CGImageSourceGetType(src).map { $0 as String } ?? UTType.png.identifier
            let ext = url.pathExtension.isEmpty ? "png" : url.pathExtension
            let dest = Output.url(for: url, in: ctx.folder(for: url), suffix: " clean", ext: ext)
            guard let d = CGImageDestinationCreateWithURL(dest as CFURL, typeID as CFString, 1, nil) else {
                throw ToolError("Can't rewrite \(url.lastPathComponent) in its own format.")
            }
            var opts: [CFString: Any] = [kCGImageMetadataShouldExcludeGPS: true]
            if everything {
                // Start from empty metadata, keeping only orientation so photos stay upright.
                let clean = CGImageMetadataCreateMutable()
                CGImageMetadataSetValueMatchingImageProperty(clean, kCGImagePropertyTIFFDictionary, kCGImagePropertyTIFFOrientation,
                                                             ImageKit.orientation(src) as CFNumber)
                opts[kCGImageDestinationMetadata] = clean
                opts[kCGImageDestinationMergeMetadata] = false
                opts[kCGImageMetadataShouldExcludeXMP] = true
            }
            // Copy the compressed data as-is where ImageIO can (JPEG, PNG, TIFF…): no quality loss.
            if CGImageDestinationCopyImageSource(d, src, opts as CFDictionary, nil) {
                out.notes.append("\(url.lastPathComponent): cleaned without re-encoding")
            } else {
                try? FileManager.default.removeItem(at: dest)
                try ImageKit.write(ImageKit.load(url), to: dest, type: UTType(typeID) ?? .png, quality: 0.95)
                out.notes.append("\(url.lastPathComponent): cleaned (re-saved at high quality)")
            }
            out.files.append(dest)
            ctx.progress(Double(i + 1) / Double(inputs.count))
        }
        return out
    }

    struct Options: View {
        @Bindable var tool: StripMetadataTool
        var body: some View {
            OptionRow("Remove") {
                Chips(selection: $tool.everything, options: [(true, "Everything (camera, dates, location)"), (false, "Location only")])
            }
        }
    }
}
