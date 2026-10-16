import Foundation
import SwiftUI

extension Toolbox {
    static let background: [ToolInfo] = [
        ToolInfo("bg-solid", "Remove Background", "Lift the subject out of any photo with on-device AI, or cut out solid colours.",
                 symbol: "person.and.background.dotted", category: .background, types: [.image], runLabel: "Remove") { RemoveBackgroundTool() },
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
enum KeyColor: Hashable, Sendable {
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

/// Runs a photo tool's processing over each input at full size and saves PNGs.
private func cutouts(_ inputs: [URL], _ ctx: JobContext, suffix: String,
                     _ process: (CGImage, URL) throws -> CGImage) throws -> JobOutput {
    var out = JobOutput()
    for (i, url) in inputs.enumerated() {
        try Task.checkCancellation()
        let image = try process(ImageKit.load(url), url)
        let dest = Output.url(for: url, in: ctx.folder(for: url), suffix: suffix, ext: "png")
        try ImageKit.write(image, to: dest, type: .png)
        out.files.append(dest)
        ctx.progress(Double(i + 1) / Double(inputs.count))
    }
    return out
}

/// The live preview shown at the top of each photo tool's options.
private func preview(_ url: URL?, _ key: AnyHashable, render: @escaping PreviewRender) -> some View {
    CutoutPreview(url: url, key: key, tint: Category.background.tint, render: render)
        .frame(minHeight: 150, maxHeight: .infinity)
}

// MARK: - Remove background

@Observable
final class RemoveBackgroundTool: FileTool {
    enum Method: Hashable, Sendable { case subject, solid }
    enum Pick: Hashable, Sendable { case auto, white, custom }
    enum Fill: Hashable, Sendable { case transparent, white, custom }

    var method: Method = .subject
    // Subject
    var shift = 0.0
    var feather = 0.5
    var cleanEdges = true
    // Solid colour
    var pick: Pick = .auto
    var custom = Color.white
    var tolerance = 20.0
    var edgesOnly = true
    var softness = 1.0
    // Result
    var fill: Fill = .transparent
    var fillColor = Color.white
    var crop = false

    var first: URL?

    struct Settings: Hashable, Sendable {
        var method: Method
        var shift, feather: Double
        var cleanEdges: Bool
        var pick: Pick
        var custom: Swatch
        var tolerance: Double
        var edgesOnly: Bool
        var softness: Double
        var fill: Swatch?
        var crop: Bool
    }

    var settings: Settings {
        Settings(method: method, shift: shift, feather: feather, cleanEdges: cleanEdges, pick: pick, custom: Swatch(custom),
                 tolerance: tolerance, edgesOnly: edgesOnly, softness: softness,
                 fill: fill == .transparent ? nil : fill == .white ? .white : Swatch(fillColor), crop: crop)
    }

    var options: AnyView? { AnyView(Options(tool: self)) }

    func inputsChanged(_ inputs: [URL]) { first = inputs.first }

    func run(_ inputs: [URL], _ ctx: JobContext) async throws -> JobOutput {
        let s = await MainActor.run { settings }
        return try cutouts(inputs, ctx, suffix: " no-bg") { image, _ in try Self.process(image, s, scale: 1, cacheKey: nil) }
    }

    /// `scale` shrinks pixel-sized settings for the downscaled preview.
    static func process(_ image: CGImage, _ s: Settings, scale: Double, cacheKey: String?) throws -> CGImage {
        var px = Pixels(image)
        switch s.method {
        case .subject:
            let mask = try SubjectMask.alpha(for: image, cacheKey: cacheKey)
            px.multiplyAlpha(px.refine(mask, shift: s.shift * scale, feather: s.feather * scale))
            if s.cleanEdges { px.cleanEdges(radius: max(Int((4 * scale).rounded()), 2)) }
        case .solid:
            let key = switch s.pick {
            case .auto: px.dominantBorderColor()
            case .white: (r: 255.0, g: 255.0, b: 255.0)
            case .custom: s.custom.rgb
            }
            px.removeColor(key, tolerance: s.tolerance * 1.8, edgesOnly: s.edgesOnly, softness: Int((s.softness * scale).rounded()))
        }
        let bounds = s.crop ? px.subjectBounds(padding: 12 * scale) : nil
        if let fill = s.fill { px.fill(fill) }
        let out = try px.makeImage()
        return bounds.flatMap { out.cropping(to: $0) } ?? out
    }

    struct Options: View {
        @Bindable var tool: RemoveBackgroundTool

        var body: some View {
            let s = tool.settings
            VStack(alignment: .leading, spacing: 4) {
                preview(tool.first, s) { req in
                    try RemoveBackgroundTool.process(req.image, s, scale: req.scale, cacheKey: req.url.path)
                }
                .padding(.bottom, 6)
                OptionRow("Method") {
                    Chips(selection: $tool.method, options: [(.subject, "Subject · AI"), (.solid, "Solid colour")])
                }
                if tool.method == .subject {
                    OptionRow("Edge") {
                        SliderRow(value: $tool.shift, range: -5...5, step: 0.5) { v in
                            v == 0 ? "As found" : String(format: "%@%.1f px", v > 0 ? "+" : "−", abs(v))
                        }
                        .help("Pull the edge in to drop leftover background, or push it out to keep fine detail.")
                    }
                    OptionRow("Softness") {
                        SliderRow(value: $tool.feather, range: 0...6, step: 0.5) { String(format: "%.1f px", $0) }
                        Toggle("Clean edge colour", isOn: $tool.cleanEdges)
                            .toggleStyle(.switch).controlSize(.mini).font(.system(size: 12))
                            .help("Removes the old background's tint from hair and soft edges.")
                    }
                } else {
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
                OptionRow("Result") {
                    Chips(selection: $tool.fill, options: [(.transparent, "Transparent"), (.white, "White"), (.custom, "Colour")])
                    if tool.fill == .custom { ColorPicker("", selection: $tool.fillColor, supportsOpacity: false).labelsHidden() }
                    Toggle("Crop to subject", isOn: $tool.crop).toggleStyle(.switch).controlSize(.mini).font(.system(size: 12))
                }
            }
            .frame(maxHeight: .infinity)
        }
    }
}

// MARK: - Signature

@Observable
final class SignatureTool: FileTool {
    enum Ink: Hashable, Sendable { case original, black, blue }
    var threshold = 0.72
    var ink: Ink = .original
    var crop = true
    var first: URL?

    struct Settings: Hashable, Sendable {
        var threshold: Double
        var ink: Ink
        var crop: Bool
    }

    var settings: Settings { Settings(threshold: threshold, ink: ink, crop: crop) }
    var options: AnyView? { AnyView(Options(tool: self)) }

    func inputsChanged(_ inputs: [URL]) { first = inputs.first }

    func run(_ inputs: [URL], _ ctx: JobContext) async throws -> JobOutput {
        let s = await MainActor.run { settings }
        return try cutouts(inputs, ctx, suffix: " signature") { image, _ in try Self.process(image, s, scale: 1) }
    }

    static func process(_ image: CGImage, _ s: Settings, scale: Double) throws -> CGImage {
        var px = Pixels(image)
        let color: (r: Double, g: Double, b: Double)? = switch s.ink {
        case .original: nil
        case .black: (20, 20, 24)
        case .blue: (18, 52, 140)
        }
        px.extractInk(threshold: s.threshold, color: color)
        let out = try px.makeImage()
        guard s.crop, let bounds = px.subjectBounds(padding: 12 * scale) else { return out }
        return out.cropping(to: bounds) ?? out
    }

    struct Options: View {
        @Bindable var tool: SignatureTool
        var body: some View {
            let s = tool.settings
            VStack(alignment: .leading, spacing: 4) {
                preview(tool.first, s) { req in try SignatureTool.process(req.image, s, scale: req.scale) }
                    .padding(.bottom, 6)
                OptionRow("Sensitivity") { SliderRow(value: $tool.threshold, range: 0.4...0.95) { "\(Int($0 * 100))" } }
                OptionRow("Ink colour") {
                    Chips(selection: $tool.ink, options: [(.original, "Original"), (.black, "Black"), (.blue, "Blue")])
                }
                OptionRow("Crop") {
                    Toggle("Trim to the signature", isOn: $tool.crop).toggleStyle(.switch).controlSize(.small).font(.system(size: 12.5))
                }
            }
            .frame(maxHeight: .infinity)
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
    var first: URL?

    struct Settings: Hashable, Sendable {
        var key: KeyColor
        var custom: Swatch
        var tolerance, softness: Double
        var despill: Bool
    }

    var settings: Settings { Settings(key: key, custom: Swatch(custom), tolerance: tolerance, softness: softness, despill: despill) }
    var options: AnyView? { AnyView(Options(tool: self)) }

    func inputsChanged(_ inputs: [URL]) { first = inputs.first }

    func run(_ inputs: [URL], _ ctx: JobContext) async throws -> JobOutput {
        let s = await MainActor.run { settings }
        return try cutouts(inputs, ctx, suffix: " keyed") { image, _ in try Self.process(image, s) }
    }

    static func process(_ image: CGImage, _ s: Settings) throws -> CGImage {
        var px = Pixels(image)
        px.chromaKey(s.key == .custom ? s.custom.rgb : s.key.rgb, tolerance: s.tolerance * 0.9, softness: s.softness * 0.6,
                     despill: s.despill && s.key != .custom ? s.key : nil)
        return try px.makeImage()
    }

    struct Options: View {
        @Bindable var tool: ChromaKeyImageTool
        var body: some View {
            let s = tool.settings
            VStack(alignment: .leading, spacing: 4) {
                preview(tool.first, s) { req in try ChromaKeyImageTool.process(req.image, s) }
                    .padding(.bottom, 6)
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
            .frame(maxHeight: .infinity)
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
