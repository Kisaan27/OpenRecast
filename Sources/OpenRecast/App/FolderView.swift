import SwiftUI

struct FolderView: View {
    @Environment(AppModel.self) private var app
    let category: Category
    let toolID: String?

    private var tools: [ToolInfo] { Toolbox.tools(in: category) }
    private var current: ToolInfo { tools.first { $0.id == toolID } ?? tools[0] }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: 270)
                .background(Theme.panel.opacity(0.55))
            Rectangle().fill(Theme.line).frame(width: 1)
            ToolPanel(info: current)
                .id(current.id)
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { app.goHome() } label: {
                HStack(spacing: 5) {
                    Image(systemName: "chevron.left").font(.system(size: 10, weight: .bold))
                    Text("OpenRecast").font(.system(size: 12.5, weight: .medium))
                }
            }
            .buttonStyle(QuietButtonStyle())
            .keyboardShortcut("[", modifiers: .command)
            .padding(.top, 44)

            HStack(spacing: 14) {
                FolderIcon(category: category, open: true, size: 48)
                VStack(alignment: .leading, spacing: 2) {
                    Text(category.title)
                        .font(.system(size: 28, weight: .regular, design: .serif))
                        .foregroundStyle(Theme.ink)
                    Text("\(tools.count) TOOLS").eyebrow()
                }
            }
            .padding(.top, 24)

            Text(category.blurb)
                .font(.system(size: 12))
                .foregroundStyle(Theme.muted)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 12)

            ScrollView {
                VStack(spacing: 3) {
                    ForEach(tools) { tool in
                        Button {
                            app.route = .folder(category, toolID: tool.id)
                        } label: {
                            ToolRowLabel(tool: tool, selected: tool.id == current.id)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(.top, 16)
            .padding(.horizontal, -7)

            Spacer(minLength: 8)

            HStack(spacing: 9) {
                ForEach(Category.allCases) { other in
                    Button { app.open(other) } label: {
                        FolderIcon(category: other, size: 20)
                            .opacity(other == category ? 1 : 0.55)
                    }
                    .buttonStyle(.plain)
                    .help(other.title)
                }
            }
        }
        .padding(.horizontal, 22)
        .padding(.bottom, 20)
    }
}
