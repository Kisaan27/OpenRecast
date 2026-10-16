import Foundation
import SwiftUI

extension Toolbox {
    static let audio: [ToolInfo] = [
        ToolInfo("audio-convert", "Convert Audio", "MP3, M4A, WAV, FLAC, AIFF, OGG, Opus, or an MP4 video.",
                 symbol: "arrow.triangle.2.circlepath", category: .audio, types: [.audio], extensions: MediaExt.audio) { ConvertAudioTool() },
        ToolInfo("audio-trim", "Trim", "Cut a recording down to the part you want.",
                 symbol: "timeline.selection", category: .audio, types: [.audio], extensions: MediaExt.audio,
                 multiple: false, runLabel: "Trim") { TrimTool() },
        ToolInfo("audio-normalize", "Normalize Volume", "Even out loudness to streaming or podcast standards.",
                 symbol: "speaker.wave.2", category: .audio, types: [.audio], extensions: MediaExt.audio,
                 runLabel: "Normalize") { NormalizeAudioTool() },
        ToolInfo("audio-to-video", "Audio to Video", "Turn a track into an MP4 with cover art or a moving waveform.",
                 symbol: "play.rectangle", category: .audio, types: [.audio, .image], extensions: MediaExt.audio,
                 runLabel: "Make Video") { AudioToVideoTool() },
    ]
}

enum AudioFormat: String, CaseIterable {
    case mp3, m4a, wav, flac, aiff, ogg, opus
    /// A video with a moving waveform, for sites that only take video.
    case mp4

    static let bitrates: [(Int, String)] = [(320, "320 kbps"), (256, "256"), (192, "192"), (128, "128")]

    var title: String { self == .mp4 ? "MP4 VIDEO" : rawValue.uppercased() }
    var lossy: Bool { [.mp3, .m4a, .ogg, .opus].contains(self) }

    func args(bitrate: Int) -> [String] {
        switch self {
        case .mp3: ["-c:a", "libmp3lame", "-b:a", "\(bitrate)k", "-id3v2_version", "3"]
        case .m4a: ["-c:a", "aac", "-b:a", "\(bitrate)k"]
        case .wav: ["-c:a", "pcm_s16le"]
        case .flac: ["-c:a", "flac"]
        case .aiff: ["-c:a", "pcm_s16be"]
        case .ogg: ["-c:a", "libvorbis", "-q:a", String(bitrate >= 320 ? 9 : bitrate >= 256 ? 8 : bitrate >= 192 ? 6 : 4)]
        case .opus: ["-c:a", "libopus", "-b:a", "\(min(bitrate, 256))k"]
        case .mp4: ["-c:a", "aac", "-b:a", "192k"]
        }
    }

    static func best(for url: URL) -> [AudioFormat] {
        switch AudioFormat(url: url) {
        case .wav, .aiff, .flac: [.mp3, .m4a, .flac]
        case .mp3: [.mp4, .m4a, .wav]
        case .m4a: [.mp3, .mp4, .wav]
        default: [.mp3, .m4a, .mp4]
        }
    }

    init?(url: URL) {
        switch url.pathExtension.lowercased() {
        case "aif": self = .aiff
        case "aac": self = .m4a
        case let ext: self.init(rawValue: ext)
        }
    }
}

@Observable
final class ConvertAudioTool: FileTool {
    var format: AudioFormat = .mp3
    var bitrate = 320
    var choices = AudioFormat.allCases
    var best: AudioFormat?

    var options: AnyView? { AnyView(Options(tool: self)) }

    func inputsChanged(_ inputs: [URL]) {
        guard let first = inputs.first else { choices = AudioFormat.allCases; best = nil; return }
        choices = FormatChoice.order(AudioFormat.allCases, best: AudioFormat.best(for: first),
                                     hide: FormatChoice.shared(inputs) { AudioFormat(url: $0) } ?? nil)
        best = choices.first
        if let best { format = best }
    }

    func run(_ inputs: [URL], _ ctx: JobContext) async throws -> JobOutput {
        var out = JobOutput()
        for (i, url) in inputs.enumerated() {
            let dest = Output.url(for: url, in: ctx.folder(for: url), ext: format.rawValue)
            if format == .mp4 {
                try await AudioVideo.make(audio: url, image: nil, height: 720, to: dest, ctx.part(i, of: inputs.count))
            } else {
                try await FFmpeg.convert(url, ["-map", "0:a:0", "-vn"] + format.args(bitrate: bitrate), to: dest, ctx.part(i, of: inputs.count))
            }
            out.files.append(dest)
        }
        return out
    }

    struct Options: View {
        @Bindable var tool: ConvertAudioTool
        var body: some View {
            VStack(alignment: .leading, spacing: 8) {
                OptionRow("Convert to") {
                    Chips(selection: $tool.format, options: tool.choices.map { ($0, $0.title) }, recommended: tool.best)
                }
                if tool.format.lossy {
                    OptionRow("Bitrate") { Chips(selection: $tool.bitrate, options: AudioFormat.bitrates) }
                }
            }
        }
    }
}

@Observable
final class NormalizeAudioTool: FileTool {
    var target = -14

    var options: AnyView? { AnyView(Options(tool: self)) }

    func run(_ inputs: [URL], _ ctx: JobContext) async throws -> JobOutput {
        var out = JobOutput()
        for (i, url) in inputs.enumerated() {
            let info = await FFmpeg.probe(url)
            let format = AudioFormat(url: url) ?? .m4a
            let dest = Output.url(for: url, in: ctx.folder(for: url), suffix: " normalized", ext: format.rawValue)
            // loudnorm resamples internally; put the original sample rate back.
            let args = ["-map", "0:a:0", "-vn", "-af", "loudnorm=I=\(target):TP=-1.5:LRA=11",
                        "-ar", String(info.sampleRate ?? 48000)] + format.args(bitrate: 320)
            try await FFmpeg.convert(url, args, to: dest, ctx.part(i, of: inputs.count), duration: info.duration)
            out.files.append(dest)
        }
        return out
    }

    struct Options: View {
        @Bindable var tool: NormalizeAudioTool
        var body: some View {
            OptionRow("Target") {
                Chips(selection: $tool.target, options: [(-14, "Music & streaming"), (-16, "Podcast"), (-23, "Broadcast")])
            }
        }
    }
}

/// Builds an MP4 from an audio track plus a still image, or a moving waveform when there's no image.
enum AudioVideo {
    /// `height` 0 keeps the image's own size (or 720p for a waveform).
    static func make(audio: URL, image: URL?, height: Int, to dest: URL, _ ctx: JobContext) async throws {
        let duration = await FFmpeg.probe(audio).duration
        let video = ["-c:a", "aac", "-b:a", "192k", "-movflags", "+faststart"]
        if let image {
            let still = Output.temporary(ext: "png")
            defer { try? FileManager.default.removeItem(at: still) }
            try ImageKit.write(ImageKit.load(image, maxPixel: 3840), to: still, type: .png)
            let w = height * 16 / 9
            let filter = height > 0
                ? "scale=\(w):\(height):force_original_aspect_ratio=decrease,pad=\(w):\(height):(ow-iw)/2:(oh-ih)/2:color=black,format=yuv420p"
                : "\(Encode.evenSize),format=yuv420p"
            try await FFmpeg.run(["-loop", "1", "-framerate", "2", "-i", still.path, "-i", audio.path,
                                  "-map", "0:v", "-map", "1:a", "-vf", filter,
                                  "-c:v", "libx264", "-tune", "stillimage", "-preset", "medium", "-crf", "20", "-shortest"] + video,
                                 output: dest, duration: duration, ctx)
        } else {
            let h = height > 0 ? height : 720, w = h * 16 / 9
            let graph = "color=c=0x121110:s=\(w)x\(h):r=30[bg];" +
                "[0:a]showwaves=s=\(w)x\(h * 5 / 12):mode=cline:draw=full:colors=white:scale=sqrt:rate=30," +
                // showwaves mis-renders custom colours, so draw white and tint it to the accent.
                "format=rgba,colorchannelmixer=rr=0.898:gg=0.541:bb=0.361[wave];" +
                "[bg][wave]overlay=0:(H-h)/2:shortest=1,format=yuv420p[v]"
            try await FFmpeg.run(["-i", audio.path, "-filter_complex", graph, "-map", "[v]", "-map", "0:a",
                                  "-c:v", "h264_videotoolbox", "-q:v", "60"] + video,
                                 output: dest, duration: duration, ctx)
        }
    }
}

@Observable
final class AudioToVideoTool: FileTool {
    var size = 0

    var options: AnyView? { AnyView(Options(tool: self)) }

    private func split(_ inputs: [URL]) -> (audio: URL?, image: URL?) {
        (inputs.first { !FileKind.is($0, .image) }, inputs.first { FileKind.is($0, .image) })
    }

    func validate(_ inputs: [URL]) -> String? {
        split(inputs).audio == nil ? "Add an audio file (and optionally an image for the picture)." : nil
    }

    func run(_ inputs: [URL], _ ctx: JobContext) async throws -> JobOutput {
        let parts = split(inputs)
        guard let audio = parts.audio else { return JobOutput() }
        let dest = Output.url(for: audio, in: ctx.folder(for: audio), ext: "mp4")
        try await AudioVideo.make(audio: audio, image: parts.image, height: size, to: dest, ctx)
        return JobOutput(files: [dest], notes: [parts.image == nil ? "No image added, so it uses a moving waveform." : "Uses \(parts.image!.lastPathComponent) as the picture."])
    }

    struct Options: View {
        @Bindable var tool: AudioToVideoTool
        var body: some View {
            VStack(alignment: .leading, spacing: 8) {
                OptionRow("Frame") {
                    Chips(selection: $tool.size, options: [(0, "Auto"), (1080, "1080p"), (720, "720p")])
                }
                Text("Add an image for the picture, or leave it out for a moving waveform.")
                    .font(.system(size: 11.5)).foregroundStyle(Theme.muted)
            }
        }
    }
}
