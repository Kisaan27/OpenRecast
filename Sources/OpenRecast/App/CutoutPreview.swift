import AppKit
import SwiftUI

/// What a live preview hands to a tool's renderer.
struct PreviewRequest: @unchecked Sendable {
    let url: URL
    /// The image, downscaled for speed.
    let image: CGImage
    /// Preview width ÷ full width, for scaling pixel-sized settings.
    let scale: Double
}

typealias PreviewRender = @Sendable (PreviewRequest) throws -> CGImage

/// A live before/after view of a cut-out. Re-renders whenever `key` changes; drag the divider to compare,
/// switch the backdrop to check edges, double-click to zoom in where you click.
struct CutoutPreview: View {
    let url: URL?
    let key: AnyHashable
    var tint: Color = Theme.accent
    let render: PreviewRender

    @State private var source: CGImage?
    @State private var scale = 1.0
    @State private var result: CGImage?
    @State private var busy = false
    @State private var failure: String?
    @State private var split: CGFloat = 0.5
    @State private var backdrop: Backdrop = .checker
    @State private var zoom: UnitPoint?

    enum Backdrop: Hashable { case checker, white, black }

    private struct RenderID: Hashable {
        let url: URL?
        let key: AnyHashable
        let ready: Bool
    }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                RoundedRectangle(cornerRadius: 12).fill(Theme.ink.opacity(0.035))
                if let source {
                    let size = fitted(CGSize(width: source.width, height: source.height), in: geo.size)
                    stage(source: source, size: size)
                } else if url != nil {
                    ProgressView().controlSize(.small)
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.line))
        .overlay(alignment: .topTrailing) { if source != nil { controls.padding(8) } }
        .overlay(alignment: .bottomLeading) { status.padding(8) }
        .task(id: url) { await load() }
        .task(id: RenderID(url: url, key: key, ready: source != nil)) { await refresh() }
    }

    // MARK: Pieces

    private func stage(source: CGImage, size: CGSize) -> some View {
        let after = result ?? source
        let comparing = result != nil && zoom == nil
        return ZStack {
            backdropFill
            Image(decorative: after, scale: 1).resizable().interpolation(.high)
            if comparing {
                Image(decorative: source, scale: 1).resizable().interpolation(.high)
                    .mask(alignment: .leading) { Rectangle().frame(width: size.width * split) }
            }
        }
        .frame(width: size.width, height: size.height)
        .scaleEffect(zoom == nil ? 1 : 3, anchor: zoom ?? .center)
        .frame(width: size.width, height: size.height)
        .clipped()
        .overlay { if comparing { divider(width: size.width) } }
        .onTapGesture(count: 2, coordinateSpace: .local) { point in
            withAnimation(.easeOut(duration: 0.2)) {
                zoom = zoom == nil ? UnitPoint(x: point.x / size.width, y: point.y / size.height) : nil
            }
        }
        .help("Drag the handle to compare. Double-click to zoom.")
    }

    private func divider(width: CGFloat) -> some View {
        GeometryReader { geo in
            let x = width * split
            ZStack {
                Rectangle().fill(.white).frame(width: 2).shadow(color: .black.opacity(0.4), radius: 2)
                Circle()
                    .fill(.white)
                    .frame(width: 22, height: 22)
                    .shadow(color: .black.opacity(0.3), radius: 3, y: 1)
                    .overlay(Image(systemName: "arrow.left.and.right").font(.system(size: 9, weight: .bold)).foregroundStyle(.black.opacity(0.7)))
            }
            .frame(width: 30, height: geo.size.height)
            .contentShape(Rectangle())
            .position(x: x, y: geo.size.height / 2)
            .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("stage")).onChanged { g in
                split = min(max(g.location.x / max(width, 1), 0), 1)
            })
            .onHover { inside in if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() } }
        }
        .coordinateSpace(name: "stage")
    }

    @ViewBuilder
    private var backdropFill: some View {
        switch backdrop {
        case .checker: Checkerboard()
        case .white: Color.white
        case .black: Color.black
        }
    }

    private var controls: some View {
        HStack(spacing: 4) {
            ForEach([Backdrop.checker, .white, .black], id: \.self) { b in
                Button { backdrop = b } label: {
                    Group {
                        switch b {
                        case .checker: Checkerboard(square: 3)
                        case .white: Color.white
                        case .black: Color.black
                        }
                    }
                    .frame(width: 14, height: 14)
                    .clipShape(Circle())
                    .overlay(Circle().stroke(backdrop == b ? tint : .black.opacity(0.25), lineWidth: backdrop == b ? 2 : 0.6))
                }
                .buttonStyle(.plain)
                .help(b == .checker ? "Show transparency" : b == .white ? "Check edges on white" : "Check edges on black")
            }
            if zoom != nil {
                Button { withAnimation(.easeOut(duration: 0.2)) { zoom = nil } } label: {
                    Image(systemName: "minus.magnifyingglass").font(.system(size: 11, weight: .semibold))
                }
                .buttonStyle(.plain)
                .help("Zoom out")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(Capsule().fill(.ultraThinMaterial))
    }

    @ViewBuilder
    private var status: some View {
        if let failure {
            Label(failure, systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: 11))
                .foregroundStyle(Theme.bad)
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(Capsule().fill(.ultraThinMaterial))
                .lineLimit(2)
        } else if busy {
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text(result == nil ? "Finding the subject…" : "Updating…").font(.system(size: 11))
            }
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(Capsule().fill(.ultraThinMaterial))
        } else if result != nil && zoom == nil {
            HStack(spacing: 0) {
                Text("Before ◂ ▸ After").font(.system(size: 10.5, weight: .medium))
            }
            .foregroundStyle(Theme.ink.opacity(0.75))
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(Capsule().fill(.ultraThinMaterial))
        }
    }

    // MARK: Work

    private func fitted(_ image: CGSize, in box: CGSize) -> CGSize {
        let s = min(box.width / max(image.width, 1), box.height / max(image.height, 1))
        return CGSize(width: image.width * s, height: image.height * s)
    }

    @MainActor
    private func load() async {
        source = nil
        result = nil
        failure = nil
        zoom = nil
        guard let url else { return }
        let loaded = await Task.detached(priority: .userInitiated) { () -> (CGImage, Double)? in
            guard let image = try? ImageKit.load(url, maxPixel: 1400),
                  let full = try? ImageKit.pixelSize(ImageKit.source(url)) else { return nil }
            return (image, Double(image.width) / Double(max(full.width, 1)))
        }.value
        guard !Task.isCancelled else { return }
        if let loaded {
            source = loaded.0
            scale = loaded.1
        } else {
            failure = "Couldn't open this image for a preview."
        }
    }

    @MainActor
    private func refresh() async {
        guard let source, let url else { return }
        // Let a slider settle before re-rendering.
        try? await Task.sleep(for: .milliseconds(80))
        guard !Task.isCancelled else { return }
        busy = true
        let request = PreviewRequest(url: url, image: source, scale: scale)
        let render = self.render
        let outcome = await Task.detached(priority: .userInitiated) { () -> Result<CGImage, Error> in
            Result { try render(request) }
        }.value
        guard !Task.isCancelled else { return }
        busy = false
        switch outcome {
        case .success(let image): result = image; failure = nil
        case .failure(let error): failure = error.localizedDescription
        }
    }
}

/// The grey-and-white grid that stands for transparency.
struct Checkerboard: View {
    var square: CGFloat = 8

    var body: some View {
        Canvas { ctx, size in
            ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Color(white: 1)))
            let cols = Int(ceil(size.width / square)), rows = Int(ceil(size.height / square))
            var path = Path()
            for y in 0..<rows {
                for x in 0..<cols where (x + y) % 2 == 0 {
                    path.addRect(CGRect(x: CGFloat(x) * square, y: CGFloat(y) * square, width: square, height: square))
                }
            }
            ctx.fill(path, with: .color(Color(white: 0.84)))
        }
    }
}
