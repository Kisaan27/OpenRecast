import Foundation
import SwiftUI

extension Toolbox {
    static let video: [ToolInfo] = [
        ToolInfo("video-convert", "Convert Video", "MP4, MOV, MKV, WebM, AVI or animated GIF.",
                 symbol: "arrow.triangle.2.circlepath", category: .video, types: [.movie], extensions: MediaExt.video) { ConvertVideoTool() },
        ToolInfo("video-compress", "Compress Video", "Shrink clips for sharing, with hardware encoding.",
                 symbol: "arrow.down.right.and.arrow.up.left", category: .video, types: [.movie], extensions: MediaExt.video,
                 runLabel: "Compress") { CompressVideoTool() },
        ToolInfo("video-trim", "Trim", "Cut a clip down to the part you want.",
                 symbol: "timeline.selection", category: .video, types: [.movie], extensions: MediaExt.video,
                 multiple: false, runLabel: "Trim") { TrimTool() },
        ToolInfo("video-remux", "Change Container", "Swap .mov ↔ .mp4 ↔ .mkv instantly, without re-encoding.",
                 symbol: "shippingbox", category: .video, types: [.movie], extensions: MediaExt.video) { RemuxTool() },
        ToolInfo("video-gif", "Video to GIF", "Turn a clip into a crisp, looping GIF.",
                 symbol: "photo.stack", category: .video, types: [.movie], extensions: MediaExt.video,
                 runLabel: "Make GIF") { ConvertVideoTool(format: .gif, fixed: true) },
        ToolInfo("video-audio", "Extract Audio", "Pull the soundtrack out as MP3, M4A, WAV or FLAC.",
                 symbol: "music.note", category: .video, types: [.movie], extensions: MediaExt.video,
                 runLabel: "Extract") { ExtractAudioTool() },
    ]
}

enum MediaExt {
    static let video = ["mkv", "webm", "flv", "wmv", "ts", "mts", "m2ts", "3gp", "ogv", "vob", "mpg", "mpeg", "m4v", "avi", "mov", "mp4"]
    static let audio = ["mp3", "m4a", "aac", "wav", "flac", "aiff", "aif", "ogg", "oga", "opus", "wma", "amr", "ape", "mka", "caf"]
}

enum VideoFormat: String, CaseIterable {
    case mp4, mov, mkv, webm, avi, gif

    var title: String { rawValue.uppercased() }
    var hardware: Bool { [.mp4, .mov, .mkv].contains(self) }

    static func of(_ url: URL) -> VideoFormat? {
        let ext = url.pathExtension.lowercased()
        return ext == "m4v" ? .mp4 : VideoFormat(rawValue: ext)
    }

    static func best(for url: URL) -> [VideoFormat] {
        switch of(url) {
        case .mov: [.mp4, .gif, .mkv]
        case .mp4: [.mov, .gif, .webm]
        case .webm: [.mp4, .gif]
        default: [.mp4, .mov, .gif]
        }
    }
}

enum Encode {
    static let evenSize = "scale=trunc(iw/2)*2:trunc(ih/2)*2"

    /// Encoder arguments. `quality` runs 0 (smallest) … 1 (best).
    static func video(_ format: VideoFormat, quality: Double, hevc: Bool, filter: String? = nil) -> [String] {
        let streams = ["-map", "0:v:0", "-map", "0:a:0?"]
        switch format {
        case .mp4, .mov, .mkv:
            var a = streams + ["-vf", filter ?? evenSize,
                               "-c:v", hevc ? "hevc_videotoolbox" : "h264_videotoolbox",
                               "-q:v", String(Int(30 + quality * 50)), "-pix_fmt", "yuv420p"]
            if hevc && format != .mkv { a += ["-tag:v", "hvc1"] }
            a += ["-c:a", "aac", "-b:a", "192k"]
            if format != .mkv { a += ["-movflags", "+faststart"] }
            return a
        case .webm:
            return streams + (filter.map { ["-vf", $0] } ?? [])
                + ["-c:v", "libvpx-vp9", "-crf", String(Int(44 - quality * 20)), "-b:v", "0", "-row-mt", "1",
                   "-deadline", "good", "-cpu-used", "4", "-c:a", "libopus", "-b:a", "128k"]
        case .avi:
            return streams + ["-vf", filter ?? evenSize, "-c:v", "mpeg4", "-q:v", String(Int(8 - quality * 6)),
                              "-c:a", "libmp3lame", "-q:a", "3"]
        case .gif:
            return gif(width: 480, fps: 12)
        }
    }

    static func gif(width: Int, fps: Int) -> [String] {
        ["-vf", "fps=\(fps),scale='min(\(width),iw)':-1:flags=lanczos,split[a][b];[a]palettegen=stats_mode=diff[p];[b][p]paletteuse=dither=bayer:bayer_scale=4",
         "-loop", "0", "-an"]
    }
}

enum VideoQuality: Double, CaseIterable {
    case best = 0.85, balanced = 0.55, small = 0.25

    var title: String {
        switch self {
        case .best: "Best"
        case .balanced: "Balanced"
        case .small: "Smallest"
        }
    }
}

// MARK: - Convert

@Observable
final class ConvertVideoTool: FileTool {
    var format: VideoFormat
    var quality: VideoQuality = .balanced
    var hevc = false
    var gifWidth = 480
    var gifFPS = 12
    var choices = VideoFormat.allCases
    var best: VideoFormat?
    let fixed: Bool

    init(format: VideoFormat = .mp4, fixed: Bool = false) {
        self.format = format
        self.fixed = fixed
    }

    var options: AnyView? { AnyView(Options(tool: self)) }

    func inputsChanged(_ inputs: [URL]) {
        guard !fixed else { return }
        guard let first = inputs.first else { choices = VideoFormat.allCases; best = nil; return }
        choices = FormatChoice.order(VideoFormat.allCases, best: VideoFormat.best(for: first),
                                     hide: FormatChoice.shared(inputs, VideoFormat.of) ?? nil)
        best = choices.first
        if let best { format = best }
    }

    func run(_ inputs: [URL], _ ctx: JobContext) async throws -> JobOutput {
        var out = JobOutput()
        for (i, url) in inputs.enumerated() {
            let dest = Output.url(for: url, in: ctx.folder(for: url), ext: format.rawValue)
            let args = format == .gif
                ? Encode.gif(width: gifWidth, fps: gifFPS)
                : Encode.video(format, quality: quality.rawValue, hevc: hevc)
            try await FFmpeg.convert(url, args, to: dest, ctx.part(i, of: inputs.count))
            out.files.append(dest)
        }
        return out
    }

    struct Options: View {
        @Bindable var tool: ConvertVideoTool
        var body: some View {
            VStack(alignment: .leading, spacing: 8) {
                if !tool.fixed {
                    OptionRow("Convert to") {
                        Chips(selection: $tool.format, options: tool.choices.map { ($0, $0.title) }, recommended: tool.best)
                    }
                }
                if tool.format == .gif {
                    OptionRow("Width") { Chips(selection: $tool.gifWidth, options: [(320, "320 px"), (480, "480 px"), (720, "720 px")]) }
                    OptionRow("Frame rate") { Chips(selection: $tool.gifFPS, options: [(10, "10 fps"), (12, "12 fps"), (20, "20 fps")]) }
                } else {
                    OptionRow("Quality") { Chips(selection: $tool.quality, options: VideoQuality.allCases.map { ($0, $0.title) }) }
                    if tool.format.hardware {
                        OptionRow("Codec") {
                            Chips(selection: $tool.hevc, options: [(false, "H.264 · plays anywhere"), (true, "HEVC · smaller")])
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Compress

@Observable
final class CompressVideoTool: FileTool {
    var height = 0
    var quality = 0.45
    var hevc = true

    var options: AnyView? { AnyView(Options(tool: self)) }

    func run(_ inputs: [URL], _ ctx: JobContext) async throws -> JobOutput {
        var out = JobOutput()
        let filter = height > 0 ? "scale=-2:'min(\(height),ih)',\(Encode.evenSize)" : Encode.evenSize
        for (i, url) in inputs.enumerated() {
            let dest = Output.url(for: url, in: ctx.folder(for: url), suffix: " compressed", ext: "mp4")
            try await FFmpeg.convert(url, Encode.video(.mp4, quality: quality, hevc: hevc, filter: filter),
                                     to: dest, ctx.part(i, of: inputs.count))
            out.files.append(dest)
            out.notes.append(Output.change(from: url, to: dest))
        }
        return out
    }

    struct Options: View {
        @Bindable var tool: CompressVideoTool
        var body: some View {
            VStack(alignment: .leading, spacing: 8) {
                OptionRow("Max size") {
                    Chips(selection: $tool.height, options: [(0, "Keep"), (1080, "1080p"), (720, "720p"), (480, "480p")])
                }
                OptionRow("Quality") {
                    SliderRow(value: $tool.quality, range: 0...1) { v in v < 0.34 ? "Small" : v < 0.67 ? "Medium" : "High" }
                }
                OptionRow("Codec") {
                    Chips(selection: $tool.hevc, options: [(true, "HEVC · smallest"), (false, "H.264 · plays anywhere")])
                }
            }
        }
    }
}

// MARK: - Trim (video & audio)

@Observable
final class TrimTool: FileTool {
    var start = "0:00"
    var end = ""
    var fast = true

    var options: AnyView? { AnyView(Options(tool: self)) }

    func validate(_ inputs: [URL]) -> String? {
        guard let s = TimeCode.parse(start) else { return "Start time should look like 1:30 or 90." }
        if !end.isEmpty {
            guard let e = TimeCode.parse(end) else { return "End time should look like 2:45 or 165." }
            if e <= s { return "End time must be after the start." }
        }
        return nil
    }

    func run(_ inputs: [URL], _ ctx: JobContext) async throws -> JobOutput {
        guard let url = inputs.first, let s = TimeCode.parse(start) else { return JobOutput() }
        let e = end.isEmpty ? nil : TimeCode.parse(end)
        let total = await FFmpeg.probe(url).duration
        var args: [String] = []
        if let e { args += ["-t", String(e - s)] }
        if fast {
            args += ["-map", "0:v?", "-map", "0:a?", "-c", "copy", "-avoid_negative_ts", "make_zero"]
        }
        let length = (e ?? total ?? 0) - s
        let dest = Output.url(for: url, in: ctx.folder(for: url), suffix: " trimmed", ext: url.pathExtension.lowercased())
        try await FFmpeg.convert(url, args, to: dest, ctx, before: ["-ss", String(s)], duration: length > 0 ? length : nil)
        return JobOutput(files: [dest])
    }

    struct Options: View {
        @Bindable var tool: TrimTool
        var body: some View {
            VStack(alignment: .leading, spacing: 8) {
                OptionRow("Start") { TextField("0:00", text: $tool.start).fieldStyle(width: 110) }
                OptionRow("End") {
                    TextField("end of file", text: $tool.end).fieldStyle(width: 110)
                    Text("e.g. 1:30 or 01:02:03.5").font(.system(size: 11.5)).foregroundStyle(Theme.muted)
                }
                OptionRow("Mode") {
                    Chips(selection: $tool.fast, options: [(true, "Instant · cuts at nearest keyframe"), (false, "Exact · re-encodes")])
                }
            }
        }
    }
}

// MARK: - Remux

@Observable
final class RemuxTool: FileTool {
    var container: VideoFormat = .mp4

    var options: AnyView? { AnyView(Options(tool: self)) }

    func run(_ inputs: [URL], _ ctx: JobContext) async throws -> JobOutput {
        var out = JobOutput()
        for (i, url) in inputs.enumerated() {
            let part = ctx.part(i, of: inputs.count)
            let same = url.pathExtension.lowercased() == container.rawValue
            let dest = Output.url(for: url, in: ctx.folder(for: url), suffix: same ? " remuxed" : "", ext: container.rawValue)
            let faststart = container == .mkv ? [] : ["-movflags", "+faststart"]
            do {
                try await FFmpeg.convert(url, ["-map", "0:v", "-map", "0:a?", "-c", "copy"] + faststart, to: dest, part)
                out.notes.append("\(url.lastPathComponent): streams copied, no quality loss")
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // Usually the audio codec isn't allowed in the new container, so convert just the audio.
                try await FFmpeg.convert(url, ["-map", "0:v", "-map", "0:a?", "-c:v", "copy", "-c:a", "aac", "-b:a", "256k"] + faststart,
                                         to: dest, part)
                out.notes.append("\(url.lastPathComponent): video copied, audio converted to AAC for compatibility")
            }
            out.files.append(dest)
        }
        return out
    }

    struct Options: View {
        @Bindable var tool: RemuxTool
        var body: some View {
            OptionRow("New container") {
                Chips(selection: $tool.container, options: [VideoFormat.mp4, .mov, .mkv].map { ($0, $0.title) })
            }
        }
    }
}

// MARK: - Extract audio

@Observable
final class ExtractAudioTool: FileTool {
    var format: AudioFormat = .mp3
    var bitrate = 256

    var options: AnyView? { AnyView(Options(tool: self)) }

    func run(_ inputs: [URL], _ ctx: JobContext) async throws -> JobOutput {
        var out = JobOutput()
        for (i, url) in inputs.enumerated() {
            let dest = Output.url(for: url, in: ctx.folder(for: url), ext: format.rawValue)
            try await FFmpeg.convert(url, ["-vn", "-map", "0:a:0"] + format.args(bitrate: bitrate), to: dest, ctx.part(i, of: inputs.count))
            out.files.append(dest)
        }
        return out
    }

    struct Options: View {
        @Bindable var tool: ExtractAudioTool
        var body: some View {
            VStack(alignment: .leading, spacing: 8) {
                OptionRow("Format") {
                    Chips(selection: $tool.format, options: [AudioFormat.mp3, .m4a, .wav, .flac].map { ($0, $0.title) })
                }
                if tool.format.lossy {
                    OptionRow("Bitrate") { Chips(selection: $tool.bitrate, options: AudioFormat.bitrates) }
                }
            }
        }
    }
}
