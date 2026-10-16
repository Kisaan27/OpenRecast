import AVFoundation
import AVKit
import SwiftUI

// MARK: - Editor

/// Shows what's being trimmed: a player, a filmstrip or waveform with draggable in/out handles,
/// and buttons to play the whole file or just the part being kept.
struct TrimEditor: View {
    @Bindable var tool: TrimTool
    @State private var playback = Playback()
    @State private var strip: [CGImage] = []
    @State private var peaks: [Float] = []
    @State private var poster: CGImage?
    @State private var isVideo = true

    private var tint: Color { isVideo ? Category.video.tint : Category.audio.tint }

    var body: some View {
        if let url = tool.media {
            VStack(alignment: .leading, spacing: 10) {
                if isVideo {
                    screen(url)
                        .frame(minHeight: 110, maxHeight: .infinity)
                }
                if let duration = tool.duration, duration > 0 {
                    TrimTimeline(duration: duration, start: tool.start, end: tool.endTime, current: playback.current,
                                 strip: isVideo ? strip : [], peaks: peaks, tint: tint,
                                 setStart: { tool.setStart($0); seek($0) },
                                 setEnd: { tool.setEnd($0); seek($0) },
                                 scrub: seek)
                        .frame(height: isVideo ? 66 : nil)
                        .frame(minHeight: 66, maxHeight: isVideo ? 66 : 180)
                    transport(duration)
                } else {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Reading the file…").font(.system(size: 12)).foregroundStyle(Theme.muted)
                    }
                    .frame(maxWidth: .infinity, minHeight: 66)
                }
                if !isVideo, let note = playback.note { Text(note).font(.system(size: 11.5)).foregroundStyle(Theme.muted) }
                OptionRow("Keep") {
                    Text("from").font(.system(size: 12)).foregroundStyle(Theme.muted)
                    TimeField(value: tool.start) { tool.setStart($0); seek(tool.start) }
                    Text("to").font(.system(size: 12)).foregroundStyle(Theme.muted)
                    TimeField(value: tool.endTime) { tool.setEnd($0); seek(tool.endTime) }
                    Text("\(TimeCode.format(tool.endTime - tool.start)) long")
                        .font(.system(size: 12, weight: .medium).monospacedDigit())
                        .foregroundStyle(Theme.ink.opacity(0.8))
                }
                OptionRow("Mode") {
                    Chips(selection: $tool.fast, options: [(true, "Instant · cuts at nearest keyframe"), (false, "Exact · re-encodes")])
                }
            }
            .frame(maxHeight: .infinity, alignment: .top)
            .task(id: url) { await prepare(url) }
            .task(id: posterTime) { await refreshPoster(url) }
            .onDisappear { playback.teardown() }
        } else {
            Text("Drop a file above to see it on a timeline, then drag the handles to choose the part to keep.")
                .font(.system(size: 12.5))
                .foregroundStyle(Theme.muted)
        }
    }

    // MARK: Screen

    @ViewBuilder
    private func screen(_ url: URL) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12).fill(Color.black)
            switch playback.status {
            case .ready:
                if let player = playback.player { PlayerSurface(player: player) }
            case .loading:
                ProgressView().controlSize(.small).tint(.white)
            case .unavailable, .preparing:
                if let poster {
                    Image(decorative: poster, scale: 1).resizable().aspectRatio(contentMode: .fit)
                }
                VStack(spacing: 8) {
                    Spacer()
                    if case .preparing = playback.status {
                        ProgressView(value: max(playback.proxyProgress, 0))
                            .tint(tint)
                            .frame(width: 180)
                        Text("Preparing a playable preview…").font(.system(size: 11.5)).foregroundStyle(.white.opacity(0.85))
                    } else {
                        Text("This format can't play directly. Frames still update as you scrub.")
                            .font(.system(size: 11.5))
                            .foregroundStyle(.white.opacity(0.85))
                        Button("Make a playable preview") { Task { await playback.makeVideoProxy(url) } }
                            .buttonStyle(QuietButtonStyle())
                            .colorScheme(.dark)
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity)
                .background(alignment: .bottom) {
                    LinearGradient(colors: [.clear, .black.opacity(0.7)], startPoint: .top, endPoint: .bottom).frame(height: 70)
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .contentShape(Rectangle())
        .onTapGesture { togglePlay() }
    }

    // MARK: Transport

    private func transport(_ duration: Double) -> some View {
        HStack(spacing: 6) {
            TransportButton(symbol: playback.playing && playback.stopAt == nil ? "pause.fill" : "play.fill",
                            help: "Play or pause") { togglePlay() }
                .disabled(!playback.canPlay)
            TransportButton(symbol: "play.square", label: playback.playing && playback.stopAt != nil ? "Stop" : "Play selection",
                            help: "Play just the part you're keeping") {
                if playback.playing && playback.stopAt != nil { playback.pause() } else { playback.play(from: tool.start, to: tool.endTime) }
            }
            .disabled(!playback.canPlay)
            Text("\(TimeCode.format(playback.current)) / \(TimeCode.format(duration))")
                .font(.system(size: 11.5, weight: .medium).monospacedDigit())
                .foregroundStyle(Theme.muted)
                .padding(.leading, 6)
            Spacer(minLength: 6)
            TransportButton(symbol: "arrow.right.to.line", label: "Start here", help: "Start the trim at the playhead") {
                tool.setStart(playback.current)
            }
            TransportButton(symbol: "arrow.left.to.line", label: "End here", help: "End the trim at the playhead") {
                tool.setEnd(playback.current)
            }
            TransportButton(symbol: "arrow.uturn.backward", help: "Keep the whole file") {
                tool.setStart(0)
                tool.end = nil
            }
        }
    }

    // MARK: Actions

    private func togglePlay() {
        guard playback.canPlay else { return }
        if playback.playing { playback.pause() } else { playback.play(from: nil, to: nil) }
    }

    private func seek(_ t: Double) {
        playback.seek(t)
    }

    /// For files AVFoundation can't play, the frame under the playhead comes from ffmpeg instead.
    private var posterTime: Int? {
        guard isVideo, playback.status != .ready, playback.status != .loading else { return nil }
        return Int(playback.current * 4)
    }

    private func refreshPoster(_ url: URL) async {
        guard posterTime != nil else { return }
        try? await Task.sleep(for: .milliseconds(140))
        guard !Task.isCancelled else { return }
        if let frame = await MediaPreview.frame(url, at: playback.current, height: 360), !Task.isCancelled { poster = frame }
    }

    private func prepare(_ url: URL) async {
        let ext = url.pathExtension.lowercased()
        isVideo = !(FileKind.is(url, .audio) || MediaExt.audio.contains(ext))
        strip = []
        peaks = []
        poster = nil
        await playback.load(url, video: isVideo)
        let duration = await FFmpeg.probe(url).duration
        guard !Task.isCancelled else { return }
        async let wave = MediaPreview.peaks(url, duration: duration, count: 900)
        if isVideo, let duration {
            strip = await MediaPreview.filmstrip(url, duration: duration, count: 14, height: 66)
            if poster == nil { poster = strip.first }
        }
        let p = await wave
        if !Task.isCancelled { peaks = p }
    }
}

// MARK: - Timeline

private struct TrimTimeline: View {
    let duration: Double
    let start: Double
    let end: Double
    let current: Double
    let strip: [CGImage]
    let peaks: [Float]
    let tint: Color
    let setStart: (Double) -> Void
    let setEnd: (Double) -> Void
    let scrub: (Double) -> Void

    private let handle: CGFloat = 12

    var body: some View {
        GeometryReader { geo in
            let w = max(geo.size.width - handle * 2, 1), h = geo.size.height
            let x = { (t: Double) in handle + CGFloat(min(max(t / duration, 0), 1)) * w }
            let time = { (px: CGFloat) in Double((px - handle) / w) * duration }
            ZStack(alignment: .topLeading) {
                track(width: w, height: h)
                    .offset(x: handle)
                // Everything outside the kept part is dimmed.
                Rectangle().fill(Color.black.opacity(0.55))
                    .frame(width: max(x(start) - handle, 0), height: h).offset(x: handle)
                Rectangle().fill(Color.black.opacity(0.55))
                    .frame(width: max(handle + w - x(end), 0), height: h).offset(x: x(end))
                // The kept part.
                Rectangle()
                    .strokeBorder(tint, lineWidth: 2.5)
                    .frame(width: max(x(end) - x(start), 2), height: h)
                    .offset(x: x(start))
                    .allowsHitTesting(false)
                Handle(tint: tint, leading: true)
                    .frame(width: handle, height: h)
                    .offset(x: x(start) - handle)
                    .gesture(drag { setStart(time($0)) })
                    .help("Drag to set where the trim starts")
                Handle(tint: tint, leading: false)
                    .frame(width: handle, height: h)
                    .offset(x: x(end))
                    .gesture(drag { setEnd(time($0)) })
                    .help("Drag to set where the trim ends")
                // Playhead.
                Capsule().fill(Color.white)
                    .frame(width: 2.5, height: h + 8)
                    .shadow(color: .black.opacity(0.5), radius: 2)
                    .offset(x: x(current) - 1.25, y: -4)
                    .allowsHitTesting(false)
            }
            .contentShape(Rectangle())
            .gesture(drag { scrub(min(max(time($0), 0), duration)) })
        }
        .coordinateSpace(name: "timeline")
        .padding(.vertical, 4)
    }

    private func drag(_ to: @escaping (CGFloat) -> Void) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named("timeline")).onChanged { to($0.location.x) }
    }

    @ViewBuilder
    private func track(width: CGFloat, height: CGFloat) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 4).fill(Theme.ink.opacity(0.07))
            if !strip.isEmpty {
                HStack(spacing: 0) {
                    ForEach(strip.indices, id: \.self) { i in
                        Image(decorative: strip[i], scale: 1)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: width / CGFloat(strip.count), height: height)
                            .clipped()
                    }
                }
                if !peaks.isEmpty {
                    // A slim waveform along the bottom helps find speech and beats in a clip.
                    Waveform(peaks: peaks, color: .white.opacity(0.85), mirrored: false)
                        .frame(height: height * 0.32)
                        .frame(maxHeight: .infinity, alignment: .bottom)
                        .background(alignment: .bottom) {
                            LinearGradient(colors: [.clear, .black.opacity(0.55)], startPoint: .top, endPoint: .bottom)
                                .frame(height: height * 0.45)
                        }
                }
            } else if !peaks.isEmpty {
                Waveform(peaks: peaks, color: tint, mirrored: true).padding(.vertical, 6)
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: 4))
    }
}

private struct Handle: View {
    let tint: Color
    let leading: Bool
    @State private var hovering = false

    var body: some View {
        UnevenRoundedRectangle(topLeadingRadius: leading ? 5 : 0, bottomLeadingRadius: leading ? 5 : 0,
                               bottomTrailingRadius: leading ? 0 : 5, topTrailingRadius: leading ? 0 : 5)
            .fill(tint.opacity(hovering ? 1 : 0.92))
            .overlay {
                VStack(spacing: 3) {
                    ForEach(0..<3, id: \.self) { _ in Capsule().fill(.white.opacity(0.85)).frame(width: 4, height: 1.5) }
                }
            }
            .contentShape(Rectangle())
            .onHover { inside in
                hovering = inside
                if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
            }
    }
}

private struct Waveform: View {
    let peaks: [Float]
    let color: Color
    let mirrored: Bool

    var body: some View {
        Canvas { ctx, size in
            let n = peaks.count
            guard n > 0 else { return }
            let bar = size.width / CGFloat(n)
            var path = Path()
            for (i, p) in peaks.enumerated() {
                let v = CGFloat(max(p, 0.02))
                let x = CGFloat(i) * bar
                if mirrored {
                    let h = v * size.height
                    path.addRect(CGRect(x: x, y: (size.height - h) / 2, width: max(bar * 0.7, 0.6), height: h))
                } else {
                    let h = v * size.height
                    path.addRect(CGRect(x: x, y: size.height - h, width: max(bar * 0.7, 0.6), height: h))
                }
            }
            ctx.fill(path, with: .color(color))
        }
    }
}

private struct TransportButton: View {
    let symbol: String
    var label: String? = nil
    let help: String
    let action: () -> Void
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: symbol).font(.system(size: 11, weight: .semibold))
                if let label { Text(label) }
            }
            .frame(minWidth: label == nil ? 14 : nil)
        }
        .buttonStyle(QuietButtonStyle())
        .opacity(enabled ? 1 : 0.4)
        .help(help)
    }
}

/// A time box that accepts "90", "1:30" or "1:02:03.5", committing on Return or when focus leaves.
private struct TimeField: View {
    let value: Double
    let commit: (Double) -> Void
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextField("0:00.0", text: $text)
            .fieldStyle(width: 84)
            .font(.system(size: 12.5).monospacedDigit())
            .focused($focused)
            .onSubmit(apply)
            .onChange(of: focused) { if !focused { apply() } }
            .onChange(of: value) { if !focused { text = TimeCode.format(value) } }
            .onAppear { text = TimeCode.format(value) }
    }

    private func apply() {
        if let v = TimeCode.parse(text) { commit(v) }
        text = TimeCode.format(value)
    }
}

private struct PlayerSurface: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .none
        view.videoGravity = .resizeAspect
        view.player = player
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        if view.player !== player { view.player = player }
    }
}

// MARK: - Playback

@MainActor
@Observable
final class Playback {
    enum Status: Equatable { case loading, ready, preparing, unavailable }

    private(set) var player: AVPlayer?
    private(set) var status: Status = .loading
    private(set) var current = 0.0
    private(set) var playing = false
    /// Set while playing just the selection; playback stops here.
    private(set) var stopAt: Double?
    private(set) var proxyProgress = -1.0
    private(set) var note: String?

    @ObservationIgnored private var observer: Any?
    @ObservationIgnored private var proxy: URL?
    @ObservationIgnored private var selectionStart = 0.0

    var canPlay: Bool { status == .ready && player != nil }

    func load(_ url: URL, video: Bool) async {
        teardown()
        status = .loading
        current = 0
        note = nil
        let asset = AVURLAsset(url: url)
        let playable = (try? await asset.load(.isPlayable)) ?? false
        let hasTracks = !((try? await asset.load(.tracks)) ?? []).isEmpty
        if playable && hasTracks {
            attach(AVPlayer(playerItem: AVPlayerItem(asset: asset)))
            return
        }
        guard !video else { status = .unavailable; return }
        // Audio converts to a playable copy in a moment, so do it straight away.
        status = .preparing
        note = "Preparing playback…"
        if await makeProxy(url, video: false) { note = nil } else {
            status = .unavailable
            note = "Playback isn't available for this format, but trimming still works."
        }
    }

    func makeVideoProxy(_ url: URL) async {
        status = .preparing
        if !(await makeProxy(url, video: true)) { status = .unavailable }
    }

    private func makeProxy(_ url: URL, video: Bool) async -> Bool {
        let dest = Output.temporary(ext: video ? "mp4" : "m4a")
        let args = video
            ? ["-map", "0:v:0", "-map", "0:a:0?", "-vf", "scale=-2:'min(480,ih)',\(Encode.evenSize)",
               "-c:v", "h264_videotoolbox", "-q:v", "45", "-c:a", "aac", "-b:a", "128k"]
            : ["-map", "0:a:0", "-vn", "-c:a", "aac", "-b:a", "160k"]
        proxyProgress = -1
        let sink = ProgressSink { [weak self] p in self?.proxyProgress = p }
        do {
            try await FFmpeg.convert(url, args, to: dest, JobContext(outputFolder: nil, sink: sink))
        } catch {
            return false
        }
        proxy = dest
        let at = current
        attach(AVPlayer(url: dest))
        seek(at)
        return true
    }

    private func attach(_ player: AVPlayer) {
        self.player = player
        status = .ready
        observer = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 30), queue: .main) { [weak self] time in
            MainActor.assumeIsolated { self?.tick(time.seconds) }
        }
    }

    private func tick(_ t: Double) {
        guard t.isFinite, let player else { return }
        current = t
        if let stopAt, t >= stopAt {
            pause()
            seek(selectionStart)
            return
        }
        playing = player.rate != 0
    }

    /// Plays from `start` (or the playhead), stopping at `end` if given.
    func play(from start: Double?, to end: Double?) {
        guard let player else { return }
        if let start { seek(start); selectionStart = start }
        stopAt = end
        // Starting at the very end of the file plays from the top instead.
        if let item = player.currentItem, item.duration.isNumeric, current >= item.duration.seconds - 0.05 { seek(0) }
        player.play()
        playing = true
    }

    func pause() {
        player?.pause()
        playing = false
        stopAt = nil
    }

    func seek(_ t: Double) {
        current = max(t, 0)
        if playing && stopAt != nil { stopAt = nil }
        player?.seek(to: CMTime(seconds: current, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func teardown() {
        if let observer, let player { player.removeTimeObserver(observer) }
        observer = nil
        player?.pause()
        player = nil
        playing = false
        stopAt = nil
        if let proxy { try? FileManager.default.removeItem(at: proxy) }
        proxy = nil
    }
}

// MARK: - Thumbnails and waveforms

enum MediaPreview {
    /// One frame at `t` seconds, decoded by ffmpeg so any format works.
    static func frame(_ url: URL, at t: Double, height: Int) async -> CGImage? {
        guard let binary = FFmpeg.binary else { return nil }
        let out = Output.temporary(ext: "jpg")
        defer { try? FileManager.default.removeItem(at: out) }
        let r = try? await Shell.run(binary, ["-hide_banner", "-nostdin", "-v", "error", "-ss", String(format: "%.3f", max(t, 0)),
                                              "-i", url.path, "-frames:v", "1", "-vf", "scale=-2:\(height)", "-q:v", "4", "-y", out.path])
        guard r?.status == 0 else { return nil }
        return try? ImageKit.load(out)
    }

    /// Evenly spaced frames across the clip.
    static func filmstrip(_ url: URL, duration: Double, count: Int, height: Int) async -> [CGImage] {
        let times = (0..<count).map { duration * (Double($0) + 0.5) / Double(count) }
        // AVFoundation seeks fastest when it can read the file.
        let asset = AVURLAsset(url: url)
        if (try? await asset.load(.isPlayable)) == true {
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: height * 4, height: height * 2)
            generator.requestedTimeToleranceBefore = CMTime(seconds: 0.5, preferredTimescale: 600)
            generator.requestedTimeToleranceAfter = CMTime(seconds: 0.5, preferredTimescale: 600)
            var images: [CGImage] = []
            for t in times {
                guard !Task.isCancelled else { return [] }
                if let image = try? await generator.image(at: CMTime(seconds: t, preferredTimescale: 600)).image { images.append(image) }
            }
            if images.count == count { return images }
        }
        return await withTaskGroup(of: (Int, CGImage?).self) { group in
            for (i, t) in times.enumerated() { group.addTask { (i, await frame(url, at: t, height: height * 2)) } }
            var out = [CGImage?](repeating: nil, count: count)
            for await (i, image) in group { out[i] = image }
            return out.compactMap { $0 }
        }
    }

    /// Loudness peaks across the file, 0...1, for drawing a waveform.
    static func peaks(_ url: URL, duration: Double?, count: Int) async -> [Float] {
        guard let binary = FFmpeg.binary else { return [] }
        // Low enough to stay small for long files, high enough to keep the shape of speech and music.
        let d = duration ?? 600
        let rate = d < 3600 ? 8000 : d < 7200 ? 4000 : 2000
        let out = Output.temporary(ext: "raw")
        defer { try? FileManager.default.removeItem(at: out) }
        let r = try? await Shell.run(binary, ["-hide_banner", "-nostdin", "-v", "error", "-i", url.path, "-map", "0:a:0",
                                              "-ac", "1", "-ar", String(rate), "-f", "s16le", "-y", out.path])
        guard r?.status == 0, let data = try? Data(contentsOf: out, options: .mappedIfSafe), data.count >= 2 else { return [] }
        var bins = [Float](repeating: 0, count: count)
        data.withUnsafeBytes { raw in
            let samples = raw.bindMemory(to: Int16.self)
            let n = samples.count
            for i in 0..<n {
                let b = min(i * count / n, count - 1)
                let v = Float(abs(Int32(samples[i])))
                if v > bins[b] { bins[b] = v }
            }
        }
        let top = max(bins.max() ?? 1, 1)
        // A square root keeps quiet passages visible next to loud ones.
        return bins.map { ($0 / top).squareRoot() }
    }
}
