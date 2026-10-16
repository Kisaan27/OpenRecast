import SwiftUI

struct HomeView: View {
    @Environment(AppModel.self) private var app
    @State private var hovered: Category?
    @State private var dropActive = false
    @State private var dropped: DroppedFiles?

    private let categories = Category.allCases
    private let span = 62.0 // degrees either side of the dial's left-pointing axis
    private let margin: CGFloat = 68 // keeps the first folder clear of the title bar

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            let center = CGPoint(x: w - 4, y: h / 2)
            let radius = (h / 2 - margin) / CGFloat(sin(span * .pi / 180))

            ZStack(alignment: .topLeading) {
                Dial(center: center, radius: radius, tint: hovered?.tint)

                BrandPanel(hovered: hovered)
                    .frame(width: 440, height: h, alignment: .leading)
                    .padding(.leading, 58)

                ForEach(Array(categories.enumerated()), id: \.element) { index, category in
                    FolderButton(category: category, isHovered: hovered == category) { inside in
                        if inside { hovered = category } else if hovered == category { hovered = nil }
                    } action: {
                        app.open(category)
                    } onDrop: { urls in
                        let tool = Toolbox.tools(in: category).first { t in urls.contains(where: t.accepts) }
                        app.open(category, tool: tool?.id, files: urls)
                    }
                    .position(point(index, center: center, radius: radius))
                }
            }
            .frame(width: w, height: h)
        }
        .overlay {
            if dropActive {
                RoundedRectangle(cornerRadius: 18)
                    .strokeBorder(Theme.accent.opacity(0.7), style: StrokeStyle(lineWidth: 2, dash: [7, 6]))
                    .padding(10)
                    .allowsHitTesting(false)
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard !urls.isEmpty else { return false }
            dropped = DroppedFiles(urls: urls)
            return true
        } isTargeted: { dropActive = $0 }
        .sheet(item: $dropped) { DropSuggestions(urls: $0.urls) }
    }

    /// Folders sit at equal steps along the arc, so every gap between neighbours is the same.
    private func point(_ index: Int, center: CGPoint, radius: CGFloat) -> CGPoint {
        let n = Double(categories.count - 1)
        let a = ((180 - span) + Double(index) * (2 * span / n)) * .pi / 180
        return CGPoint(x: center.x + radius * CGFloat(cos(a)), y: center.y - radius * CGFloat(sin(a)))
    }
}

struct DroppedFiles: Identifiable {
    let id = UUID()
    let urls: [URL]
}

// MARK: - Left side

private struct BrandPanel: View {
    let hovered: Category?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Spacer(minLength: 0)
            Text("PRIVATE FILE STUDIO").eyebrow()
            Text("OpenRecast")
                .font(.system(size: 66, weight: .regular, design: .serif))
                .tracking(-1.5)
                .foregroundStyle(Theme.ink)
                .padding(.top, 4)
            Text("Convert, compress and clean up files right on your Mac. No uploads, no accounts, no limits.")
                .font(.system(size: 14.5))
                .lineSpacing(3)
                .foregroundStyle(Theme.muted)
                .frame(maxWidth: 360, alignment: .leading)
                .padding(.top, 6)

            PeekCard(category: hovered)
                .frame(height: 196, alignment: .top)
                .padding(.top, 34)

            Spacer(minLength: 0)
            HStack(spacing: 8) {
                Badge(symbol: "lock.fill", text: "Works offline")
                Badge(symbol: "infinity", text: "Unlimited")
                Badge(symbol: "eye.slash.fill", text: "Nothing leaves your Mac")
            }
            .padding(.bottom, 34)
        }
    }
}

private struct PeekCard: View {
    let category: Category?

    var body: some View {
        ZStack(alignment: .topLeading) {
            if let category {
                let tools = Toolbox.tools(in: category)
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 8) {
                        Circle().fill(category.tint).frame(width: 8, height: 8)
                        Text(category.title.uppercased()).eyebrow().foregroundStyle(Theme.ink)
                        Text("· \(tools.count) tools").eyebrow()
                    }
                    Text(category.blurb)
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                    LazyVGrid(columns: [GridItem(.flexible(), alignment: .leading), GridItem(.flexible(), alignment: .leading)],
                              alignment: .leading, spacing: 9) {
                        ForEach(tools) { tool in
                            Label {
                                Text(tool.name).font(.system(size: 12.5, weight: .medium)).lineLimit(1)
                            } icon: {
                                Image(systemName: tool.symbol).font(.system(size: 10.5)).foregroundStyle(category.tint)
                            }
                            .foregroundStyle(Theme.ink.opacity(0.88))
                        }
                    }
                    .padding(.top, 4)
                }
                .padding(18)
                .frame(width: 380, alignment: .topLeading)
                .background(RoundedRectangle(cornerRadius: 16).fill(Theme.panel.opacity(0.7)))
                .overlay(RoundedRectangle(cornerRadius: 16).stroke(Theme.line))
                .id(category)
                .transition(.opacity.combined(with: .offset(y: 6)))
            } else {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "hand.point.right")
                        .font(.system(size: 15))
                        .foregroundStyle(Theme.accent)
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Hover a folder to peek inside.")
                            .font(.system(size: 13.5, weight: .medium))
                            .foregroundStyle(Theme.ink.opacity(0.85))
                        Text("Or drop any file on this window and OpenRecast will suggest what it can become.")
                            .font(.system(size: 12.5))
                            .foregroundStyle(Theme.muted)
                            .frame(maxWidth: 320, alignment: .leading)
                    }
                }
                .padding(.top, 6)
                .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.18), value: category)
    }
}

// MARK: - Right side

private struct Dial: View {
    let center: CGPoint
    let radius: CGFloat
    let tint: Color?

    private let hub: CGFloat = 104

    var body: some View {
        let outer = radius + 82
        ZStack {
            Circle()
                .fill(Theme.disc)
                .overlay(Grain(opacity: 0.08).clipShape(Circle()))
                .overlay(Circle().stroke(Theme.line))
                .frame(width: outer * 2, height: outer * 2)
                .position(center)
                .shadow(color: .black.opacity(0.25), radius: 30, x: -6)
            Circle()
                .fill(RadialGradient(colors: [(tint ?? Theme.accent).opacity(0.28), .clear],
                                     center: .center, startRadius: 0, endRadius: radius))
                .frame(width: radius * 2, height: radius * 2)
                .position(center)
                .animation(.easeOut(duration: 0.25), value: tint)
            Circle()
                .stroke(Theme.ink.opacity(0.14), style: StrokeStyle(lineWidth: 1, dash: [2, 7]))
                .frame(width: radius * 2, height: radius * 2)
                .position(center)
            Circle()
                .stroke(Theme.ink.opacity(0.06), lineWidth: 1)
                .frame(width: (radius - 58) * 2, height: (radius - 58) * 2)
                .position(center)
            Circle()
                .fill(Theme.bg)
                .overlay(Circle().stroke(Theme.line))
                .frame(width: hub * 2, height: hub * 2)
                .position(center)
            // Centred in the visible half of the hub.
            VStack(alignment: .center, spacing: 2) {
                Text("\(Toolbox.all.count)")
                    .font(.system(size: 34, weight: .regular, design: .serif))
                    .foregroundStyle(Theme.ink)
                Text("TOOLS").eyebrow()
            }
            .fixedSize()
            .position(x: center.x - hub * 0.4, y: center.y)
        }
        .allowsHitTesting(false)
    }
}

private struct FolderButton: View {
    let category: Category
    let isHovered: Bool
    let onHover: (Bool) -> Void
    let action: () -> Void
    let onDrop: ([URL]) -> Void
    @State private var dropTarget = false

    var body: some View {
        let active = isHovered || dropTarget
        Button(action: action) {
            FolderIcon(category: category, open: active, size: 62)
                .padding(6)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .scaleEffect(active ? 1.14 : 1)
        // The name label sits just left of the folder, outside its hit area.
        .overlay(alignment: .trailing) {
            if active {
                HStack(spacing: 0) {
                    Text(category.title)
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(Theme.bg)
                        .padding(.horizontal, 11)
                        .padding(.vertical, 5)
                        .background(Capsule().fill(Theme.ink))
                    Color.clear.frame(width: 88)
                }
                .fixedSize()
                .allowsHitTesting(false)
                .transition(.opacity.combined(with: .offset(x: 8)))
            }
        }
        .onHover(perform: onHover)
        .dropDestination(for: URL.self) { urls, _ in
            guard !urls.isEmpty else { return false }
            onDrop(urls)
            return true
        } isTargeted: { dropTarget = $0 }
        .animation(.spring(response: 0.32, dampingFraction: 0.68), value: active)
        .help(category.blurb)
    }
}

// MARK: - Drop suggestions

private struct DropSuggestions: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    let urls: [URL]

    var body: some View {
        let tools = Toolbox.matching(urls)
        VStack(alignment: .leading, spacing: 0) {
            Text("WHAT SHOULD IT BECOME?").eyebrow()
            Text(urls.count == 1 ? urls[0].lastPathComponent : "\(urls.count) files")
                .font(.system(size: 22, weight: .regular, design: .serif))
                .lineLimit(1)
                .truncationMode(.middle)
                .padding(.top, 4)
                .padding(.bottom, 14)

            if tools.isEmpty {
                Text("No tool handles this kind of file yet.")
                    .foregroundStyle(Theme.muted)
                    .frame(maxWidth: .infinity, minHeight: 120)
            } else {
                ScrollView {
                    VStack(spacing: 4) {
                        ForEach(tools) { tool in
                            Button {
                                dismiss()
                                app.open(tool.category, tool: tool.id, files: urls.filter(tool.accepts))
                            } label: {
                                ToolRowLabel(tool: tool, selected: false)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .frame(height: 320)
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.buttonStyle(QuietButtonStyle()).keyboardShortcut(.cancelAction)
            }
            .padding(.top, 14)
        }
        .padding(24)
        .frame(width: 420)
        .background(Backdrop())
    }
}

struct ToolRowLabel: View {
    let tool: ToolInfo
    let selected: Bool
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 11) {
            Image(systemName: tool.symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(tool.category.tint)
                .frame(width: 30, height: 30)
                .background(RoundedRectangle(cornerRadius: 8).fill(tool.category.tint.opacity(0.15)))
            VStack(alignment: .leading, spacing: 2) {
                Text(tool.name).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.ink)
                Text(tool.summary).font(.system(size: 11)).foregroundStyle(Theme.muted).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(7)
        .background(RoundedRectangle(cornerRadius: 11).fill(Theme.ink.opacity(selected ? 0.08 : hovering ? 0.04 : 0)))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }
}
