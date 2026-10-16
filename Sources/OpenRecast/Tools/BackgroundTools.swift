import Foundation
import SwiftUI

extension Toolbox {
    static let background: [ToolInfo] = [
        ToolInfo("bg-solid", "Remove Background", "Cut out white or solid-colour backgrounds from logos, products and icons.",
                 symbol: "square.dashed", category: .background, types: [.image], runLabel: "Remove") { SolidBackgroundTool() },
        ToolInfo("bg-signature", "Signature Cleanup", "Lift a signature or stamp off paper into a transparent PNG.",
                 symbol: "signature", category: .background, types: [.image], runLabel: "Clean up") { SignatureTool() },
        ToolInfo("bg-chroma", "Green Screen Photo", "Key out green or blue backdrops from photos.",
                 symbol: "person.crop.rectangle", category: .background, types: [.image], runLabel: "Remove") { ChromaKeyImageTool() },
        ToolInfo("bg-chroma-video", "Green Screen Video", "Key out green or blue backdrops into transparent video.",
                 symbol: "video.badge.checkmark", category: .background, types: [.movie], extensions: MediaExt.video,
                 runLabel: "Remove") { ChromaKeyVideoTool() },
    ]
}

/// Chroma key colours used by real-world screens, not pure RGB green/blue.
enum KeyColor: Hashable {
    case green, blue, custom

    var rgb: (r: Double, g: Double, b: Double) {
        switch self {
        case .green: (0, 177, 64)
        case .blue: (0, 71, 187)
        case .custom: (0, 0, 0)
        }
    }

    var hex: String {
        switch self {
        case .green: "0x00B140"
        case .blue: "0x0047BB"
        case .custom: "0x000000"
        }
    }
}

private func saveCutout(_ px: Pixels, for url: URL, _ ctx: JobContext, suffix: String) throws -> URL {
    let dest = Output.url(for: url, in: ctx.folder(for: url), suffix: suffix, ext: "png")
    try ImageKit.write(px.makeImage(), to: dest, type: .png)
    return dest
}

// MARK: - Solid colour

@Observable
final class SolidBackgroundTool: FileTool {
    enum Pick: Hashable { case auto, white, custom }
    var pick: Pick = .auto
    var custom = Color.white
    var tolerance = 20.0
    var edgesOnly = true
    var softness = 1.0

    var options: AnyView? { AnyView(Options(tool: self)) }

    func run(_ inputs: [URL], _ ctx: JobContext) async throws -> JobOutput {
        var out = JobOutput()
        let customRGB = custom.rgb255
        for (i, url) in inputs.enumerated() {
            try Task.checkCancellation()
            var px = Pixels(try ImageKit.load(url))
            let key = switch pick {
            case .auto: px.dominantBorderColor()
            case .white: (r: 255.0, g: 255.0, b: 255.0)
            case .custom: customRGB
            }
            px.removeColor(key, tolerance: tolerance * 1.8, edgesOnly: edgesOnly, softness: Int(softness.rounded()))
            out.files.append(try saveCutout(px, for: url, ctx, suffix: " no-bg"))
            ctx.progress(Double(i + 1) / Double(inputs.count))
        }
        return out
    }

    struct Options: View {
        @Bindable var tool: SolidBackgroundTool
        var body: some View {
            VStack(alignment: .leading, spacing: 6) {
                OptionRow("Background") {
                    Chips(selection: $tool.pick, options: [(.auto, "Auto-detect"), (.white, "White"), (.custom, "Pick colour")])
                    if tool.pick == .custom { ColorPicker("", selection: $tool.custom, supportsOpacity: false).labelsHidden() }
                }
                OptionRow("Tolerance") { SliderRow(value: $tool.tolerance, range: 1...100) }
                OptionRow("Edge softness") { SliderRow(value: $tool.softness, range: 0...4, step: 1) { "\(Int($0)) px" } }
                OptionRow("Remove") {
                    Chips(selection: $tool.edgesOnly, options: [(true, "Only around the subject"), (false, "Every matching pixel")])
                }
            }
        }
    }
}

// MARK: - Signature

@Observable
final class SignatureTool: FileTool {
    enum Ink: Hashable { case original, black, blue }
    var threshold = 0.72
    var ink: Ink = .original
    var crop = true

    var options: AnyView? { AnyView(Options(tool: self)) }

    func run(_ inputs: [URL], _ ctx: JobContext) async throws -> JobOutput {
        var out = JobOutput()
        for (i, url) in inputs.enumerated() {
            try Task.checkCancellation()
            var px = Pixels(try ImageKit.load(url))
            let color: (r: Double, g: Double, b: Double)? = switch ink {
            case .original: nil
            case .black: (20, 20, 24)
            case .blue: (18, 52, 140)
            }
            px.extractInk(threshold: threshold, color: color)
            let dest = Output.url(for: url, in: ctx.folder(for: url), suffix: " signature", ext: "png")
            var image = try px.makeImage()
            if crop, let bounds = px.opaqueBounds() {
                let pad = 12.0
                let rect = bounds.insetBy(dx: -pad, dy: -pad)
                    .intersection(CGRect(x: 0, y: 0, width: px.width, height: px.height))
                image = image.cropping(to: rect) ?? image
            }
            try ImageKit.write(image, to: dest, type: .png)
            out.files.append(dest)
            ctx.progress(Double(i + 1) / Double(inputs.count))
        }
        return out
    }

    struct Options: View {
        @Bindable var tool: SignatureTool
        var body: some View {
            VStack(alignment: .leading, spacing: 6) {
                OptionRow("Sensitivity") { SliderRow(value: $tool.threshold, range: 0.4...0.95) { "\(Int($0 * 100))" } }
                OptionRow("Ink colour") {
                    Chips(selection: $tool.ink, options: [(.original, "Original"), (.black, "Black"), (.blue, "Blue")])
                }
                OptionRow("Crop") {
                    Toggle("Trim to the signature", isOn: $tool.crop).toggleStyle(.switch).controlSize(.small).font(.system(size: 12.5))
                }
            }
        }
    }
}

// MARK: - Chroma key (photo)

@Observable
final class ChromaKeyImageTool: FileTool {
    var key: KeyColor = .green
    var custom = Color.green
    var tolerance = 45.0
    var softness = 30.0
    var despill = true

    var options: AnyView? { AnyView(Options(tool: self)) }

    func run(_ inputs: [URL], _ ctx: JobContext) async throws -> JobOutput {
        var out = JobOutput()
        let rgb = key == .custom ? custom.rgb255 : key.rgb
        for (i, url) in inputs.enumerated() {
            try Task.checkCancellation()
            var px = Pixels(try ImageKit.load(url))
            px.chromaKey(rgb, tolerance: tolerance * 0.9, softness: softness * 0.6,
                         despill: despill ? key : nil)
            out.files.append(try saveCutout(px, for: url, ctx, suffix: " keyed"))
            ctx.progress(Double(i + 1) / Double(inputs.count))
        }
        return out
    }

    struct Options: View {
        @Bindable var tool: ChromaKeyImageTool
        var body: some View {
            VStack(alignment: .leading, spacing: 6) {
                OptionRow("Screen") {
                    Chips(selection: $tool.key, options: [(.green, "Green"), (.blue, "Blue"), (.custom, "Pick colour")])
                    if tool.key == .custom { ColorPicker("", selection: $tool.custom, supportsOpacity: false).labelsHidden() }
                }
                OptionRow("Tolerance") { SliderRow(value: $tool.tolerance, range: 5...100) }
                OptionRow("Edge softness") { SliderRow(value: $tool.softness, range: 0...100) }
                if tool.key != .custom {
                    OptionRow("Spill") {
                        Toggle("Remove coloured fringe on edges", isOn: $tool.despill)
                            .toggleStyle(.switch).controlSize(.small).font(.system(size: 12.5))
                    }
                }
            }
        }
    }
}

// MARK: - Chroma key (video)

@Observable
final class ChromaKeyVideoTool: FileTool {
    var key: KeyColor = .green
    var similarity = 0.18
    var blend = 0.08
    var prores = true

    var options: AnyView? { AnyView(Options(tool: self)) }

    func run(_ inputs: [URL], _ ctx: JobContext) async throws -> JobOutput {
        var out = JobOutput()
        let filter = String(format: "chromakey=%@:%.3f:%.3f", key.hex, similarity, blend)
        for (i, url) in inputs.enumerated() {
            let dest = Output.url(for: url, in: ctx.folder(for: url), suffix: " keyed", ext: prores ? "mov" : "webm")
            let args = prores
                ? ["-vf", filter + ",format=yuva444p10le", "-c:v", "prores_ks", "-profile:v", "4444", "-c:a", "aac"]
                : ["-vf", filter + ",format=yuva420p", "-c:v", "libvpx-vp9", "-crf", "30", "-b:v", "0", "-row-mt", "1", "-c:a", "libopus"]
            try await FFmpeg.convert(url, args, to: dest, ctx.part(i, of: inputs.count))
            out.files.append(dest)
        }
        return out
    }

    struct Options: View {
        @Bindable var tool: ChromaKeyVideoTool
        var body: some View {
            VStack(alignment: .leading, spacing: 6) {
                OptionRow("Screen") { Chips(selection: $tool.key, options: [(.green, "Green"), (.blue, "Blue")]) }
                OptionRow("Tolerance") { SliderRow(value: $tool.similarity, range: 0.02...0.5) { "\(Int($0 * 100))" } }
                OptionRow("Edge softness") { SliderRow(value: $tool.blend, range: 0...0.3) { "\(Int($0 * 100))" } }
                OptionRow("Output") {
                    Chips(selection: $tool.prores, options: [(true, "ProRes 4444 · editing"), (false, "WebM · web")])
                }
            }
        }
    }
}

// MARK: - Pixel algorithms

extension Pixels {
    typealias RGB = (r: Double, g: Double, b: Double)

    /// The most common colour along the image border.
    func dominantBorderColor() -> RGB {
        var buckets: [Int: (n: Int, r: Double, g: Double, b: Double)] = [:]
        func sample(_ i: Int) {
            let c = color(i)
            guard c.a > 0.5 else { return }
            let key = (Int(c.r) >> 4) << 8 | (Int(c.g) >> 4) << 4 | (Int(c.b) >> 4)
            var e = buckets[key] ?? (0, 0, 0, 0)
            e.n += 1; e.r += c.r; e.g += c.g; e.b += c.b
            buckets[key] = e
        }
        for x in 0..<width { sample(x); sample((height - 1) * width + x) }
        for y in 0..<height { sample(y * width); sample(y * width + width - 1) }
        guard let best = buckets.values.max(by: { $0.n < $1.n }) else { return (255, 255, 255) }
        let n = Double(best.n)
        return (best.r / n, best.g / n, best.b / n)
    }

    /// Makes pixels close to `key` transparent, flood-filled from the edges, or everywhere.
    mutating func removeColor(_ key: RGB, tolerance: Double, edgesOnly: Bool, softness: Int) {
        let n = count, w = width
        let t2 = tolerance * tolerance
        var remove = [Bool](repeating: false, count: n)

        func close(_ i: Int) -> Bool {
            let c = color(i)
            if c.a < 0.02 { return true }
            let dr = c.r - key.r, dg = c.g - key.g, db = c.b - key.b
            return dr * dr + dg * dg + db * db <= t2
        }

        if edgesOnly {
            var stack: [Int] = []
            func seed(_ i: Int) {
                if !remove[i] && close(i) { remove[i] = true; stack.append(i) }
            }
            for x in 0..<w { seed(x); seed((height - 1) * w + x) }
            for y in 0..<height { seed(y * w); seed(y * w + w - 1) }
            while let i = stack.popLast() {
                let x = i % w
                if x > 0 { seed(i - 1) }
                if x < w - 1 { seed(i + 1) }
                if i >= w { seed(i - w) }
                if i + w < n { seed(i + w) }
            }
        } else {
            for i in 0..<n where close(i) { remove[i] = true }
        }

        var alpha = remove.map { $0 ? Float(0) : Float(1) }
        if softness > 0 {
            alpha = boxBlur(alpha, radius: softness)
            for i in 0..<n where remove[i] { alpha[i] = 0 }
        }
        multiplyAlpha(alpha)
    }

    /// Keeps dark strokes, turning paper transparent.
    mutating func extractInk(threshold: Double, color ink: RGB?) {
        for i in 0..<count {
            let c = color(i)
            guard c.a > 0 else { continue }
            let luma = (0.299 * c.r + 0.587 * c.g + 0.114 * c.b) / 255
            let a = min(max((threshold - luma) / 0.18, 0), 1) * c.a
            let rgb = ink ?? (c.r, c.g, c.b)
            set(i, r: rgb.r, g: rgb.g, b: rgb.b, a: a)
        }
    }

    /// Chroma distance in YCbCr space, so shadows on the screen still key out.
    mutating func chromaKey(_ key: RGB, tolerance: Double, softness: Double, despill: KeyColor?) {
        func cbcr(_ r: Double, _ g: Double, _ b: Double) -> (Double, Double) {
            (-0.168736 * r - 0.331264 * g + 0.5 * b, 0.5 * r - 0.418688 * g - 0.081312 * b)
        }
        let (kcb, kcr) = cbcr(key.r, key.g, key.b)
        let soft = max(softness, 0.001)
        for i in 0..<count {
            var c = color(i)
            guard c.a > 0 else { continue }
            let (cb, cr) = cbcr(c.r, c.g, c.b)
            let d = ((cb - kcb) * (cb - kcb) + (cr - kcr) * (cr - kcr)).squareRoot()
            let t = min(max((d - tolerance) / soft, 0), 1)
            let a = t * t * (3 - 2 * t) * c.a
            switch despill {
            case .green?: c.g = min(c.g, max(c.r, c.b))
            case .blue?: c.b = min(c.b, max(c.r, c.g))
            default: break
            }
            set(i, r: c.r, g: c.g, b: c.b, a: a)
        }
    }
}
