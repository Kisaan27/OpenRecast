import AppKit
import SwiftUI

struct ToolPanel: View {
    @Environment(AppModel.self) private var app
    let info: ToolInfo

    @State private var tool: FileTool
    @State private var files: [URL] = []
    @State private var phase: Phase = .idle
    @State private var progress: Double = -1
    @State private var task: Task<Void, Never>?
    @State private var dropActive = false
    @State private var skipped = 0
    @AppStorage("outputFolder") private var outputPath = ""

    enum Phase {
        case idle, running
        case done(JobOutput)
        case failed(String)
    }

    init(info: ToolInfo) {
        self.info = info
        _tool = State(initialValue: info.make())
    }

    private var isRunning: Bool {
        if case .running = phase { return true }
        return false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            inputs.padding(.top, 20)
            if let options = tool.options {
                Text(tool.optionsTitle.uppercased()).eyebrow().padding(.top, 22).padding(.bottom, 8)
                options.disabled(isRunning).layoutPriority(1)
            }
            Spacer(minLength: 12)
            result
            footer.padding(.top, 14)
        }
        .padding(.horizontal, 30)
        .padding(.top, 40)
        .padding(.bottom, 22)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .dropDestination(for: URL.self) { urls, _ in
            add(urls)
            return true
        } isTargeted: { dropActive = $0 }
        .onAppear {
            if !app.preload.isEmpty {
                add(app.preload)
                app.preload = []
            }
        }
        .onChange(of: files) { tool.inputsChanged(files) }
        .onDisappear { task?.cancel() }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 14) {
            Image(systemName: info.symbol)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .background(RoundedRectangle(cornerRadius: 12)
                    .fill(LinearGradient(colors: [info.category.light, info.category.tint], startPoint: .top, endPoint: .bottom)))
                .overlay(Grain(opacity: 0.12).clipShape(RoundedRectangle(cornerRadius: 12)))
            VStack(alignment: .leading, spacing: 3) {
                Text(info.name)
                    .font(.system(size: 24, weight: .regular, design: .serif))
                    .foregroundStyle(Theme.ink)
                Text(info.summary)
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.muted)
            }
        }
    }

    // MARK: Inputs

    @ViewBuilder
    private var inputs: some View {
        if files.isEmpty {
            Button(action: browse) {
                VStack(spacing: 8) {
                    Image(systemName: "arrow.down.doc")
                        .font(.system(size: 24, weight: .light))
                        .foregroundStyle(dropActive ? info.category.tint : Theme.muted)
                    Text(info.multiple ? "Drop files here" : "Drop a file here")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(Theme.ink.opacity(0.85))
                    Text("or click to browse · \(info.acceptsLabel)")
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.muted)
                }
                .frame(maxWidth: .infinity)
                .frame(height: 140)
                .background(RoundedRectangle(cornerRadius: 16).fill(Theme.ink.opacity(dropActive ? 0.06 : 0.025)))
                .overlay(RoundedRectangle(cornerRadius: 16)
                    .strokeBorder(dropActive ? info.category.tint : Theme.ink.opacity(0.16),
                                  style: StrokeStyle(lineWidth: 1.2, dash: [6, 5])))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        } else {
            VStack(spacing: 0) {
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(Array(files.enumerated()), id: \.element) { index, url in
                            FileRow(url: url, index: index, count: files.count, reorderable: info.reorderable && files.count > 1,
                                    move: { move(index, by: $0) }, remove: { files.remove(at: index); phase = .idle })
                        }
                    }
                    .padding(6)
                }
                .frame(height: min(CGFloat(files.count) * 36 + 12, 150))
                Rectangle().fill(Theme.line).frame(height: 1)
                HStack(spacing: 8) {
                    Button(info.multiple ? "Add files…" : "Choose another…", action: browse).buttonStyle(QuietButtonStyle())
                    Button("Clear") { files = []; phase = .idle }.buttonStyle(QuietButtonStyle())
                    Spacer()
                    if skipped > 0 {
                        Text("Skipped \(skipped) unsupported").font(.system(size: 11)).foregroundStyle(Theme.bad)
                    }
                    Text(summaryLine).font(.system(size: 11)).foregroundStyle(Theme.muted)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
            }
            .background(RoundedRectangle(cornerRadius: 14).fill(Theme.ink.opacity(0.03)))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(dropActive ? info.category.tint : Theme.line))
            .disabled(isRunning)
        }
    }

    private var summaryLine: String {
        let total = files.reduce(Int64(0)) { $0 + Output.size($1) }
        return "\(files.count) \(files.count == 1 ? "item" : "items") · \(Output.bytes(total))"
    }

    // MARK: Result + footer

    @ViewBuilder
    private var result: some View {
        switch phase {
        case .done(let out):
            ResultCard(output: out, tint: Theme.good)
        case .failed(let message):
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.bad)
                Text(message)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.ink.opacity(0.85))
                    .textSelection(.enabled)
                    .lineLimit(5)
                Spacer(minLength: 0)
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 12).fill(Theme.bad.opacity(0.1)))
        default:
            EmptyView()
        }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Menu {
                Button("Same folder as the original") { outputPath = "" }
                Button("Choose a folder…", action: chooseOutputFolder)
            } label: {
                Label(outputPath.isEmpty ? "Save next to original" : "Save to \(URL(fileURLWithPath: outputPath).lastPathComponent)",
                      systemImage: "folder")
                    .font(.system(size: 12))
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .foregroundStyle(Theme.muted)

            Spacer()

            if isRunning {
                Group {
                    if progress < 0 {
                        ProgressView().controlSize(.small)
                    } else {
                        ProgressView(value: progress).frame(width: 170)
                        Text("\(Int(progress * 100))%")
                            .font(.system(size: 12, weight: .medium).monospacedDigit())
                            .foregroundStyle(Theme.muted)
                            .frame(width: 36, alignment: .trailing)
                    }
                }
                .tint(info.category.tint)
                Button("Cancel") { task?.cancel() }.buttonStyle(QuietButtonStyle())
            } else {
                Button(action: start) {
                    Text(info.runLabel).frame(minWidth: 96)
                }
                .buttonStyle(PrimaryButtonStyle(tint: info.category.tint))
                .disabled(files.count < info.minFiles)
                .keyboardShortcut(.return, modifiers: .command)
            }
        }
    }

    // MARK: Actions

    private func add(_ urls: [URL]) {
        let accepted = urls.filter(info.accepts)
        skipped = urls.count - accepted.count
        guard !accepted.isEmpty else { return }
        if info.multiple {
            files += accepted.filter { !files.contains($0) }
        } else {
            files = [accepted[0]]
        }
        phase = .idle
    }

    private func move(_ index: Int, by offset: Int) {
        let target = index + offset
        guard files.indices.contains(target) else { return }
        files.swapAt(index, target)
    }

    private func browse() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = info.multiple
        panel.canChooseFiles = true
        panel.canChooseDirectories = info.acceptsFolders
        if !info.pickerTypes.isEmpty { panel.allowedContentTypes = info.pickerTypes }
        if panel.runModal() == .OK { add(panel.urls) }
    }

    private func chooseOutputFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "Save Here"
        if panel.runModal() == .OK, let url = panel.url { outputPath = url.path }
    }

    private func start() {
        let tool = self.tool
        let inputs = files
        if let problem = tool.validate(inputs) {
            phase = .failed(problem)
            return
        }
        let folder = outputPath.isEmpty ? nil : URL(fileURLWithPath: outputPath, isDirectory: true)
        let ctx = JobContext(outputFolder: folder, sink: ProgressSink { value in progress = value })
        progress = -1
        phase = .running
        task = Task.detached(priority: .userInitiated) {
            let outcome: Phase
            do {
                outcome = .done(try await tool.run(inputs, ctx))
            } catch is CancellationError {
                outcome = .idle
            } catch {
                outcome = Task.isCancelled ? .idle : .failed(error.localizedDescription)
            }
            await MainActor.run { phase = outcome }
        }
    }
}

private struct FileRow: View {
    let url: URL
    let index: Int
    let count: Int
    let reorderable: Bool
    let move: (Int) -> Void
    let remove: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            if reorderable {
                Text("\(index + 1)")
                    .font(.system(size: 11, weight: .semibold).monospacedDigit())
                    .foregroundStyle(Theme.muted)
                    .frame(width: 18)
            }
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                .resizable()
                .frame(width: 20, height: 20)
            Text(url.lastPathComponent)
                .font(.system(size: 12.5))
                .foregroundStyle(Theme.ink)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 6)
            Text(Output.bytes(Output.size(url)))
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(Theme.muted)
            if reorderable {
                Button { move(-1) } label: { Image(systemName: "chevron.up") }
                    .disabled(index == 0)
                Button { move(1) } label: { Image(systemName: "chevron.down") }
                    .disabled(index == count - 1)
            }
            Button(action: remove) { Image(systemName: "xmark") }
        }
        .buttonStyle(.plain)
        .font(.system(size: 10, weight: .bold))
        .foregroundStyle(Theme.muted)
        .padding(.horizontal, 8)
        .frame(height: 34)
        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.ink.opacity(hovering ? 0.05 : 0)))
        .onHover { hovering = $0 }
    }
}

private struct ResultCard: View {
    let output: JobOutput
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(tint)
                Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.ink)
                Spacer()
                if !output.notes.isEmpty {
                    Button("Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(output.notes.joined(separator: "\n"), forType: .string)
                    }
                    .buttonStyle(QuietButtonStyle())
                }
                if !output.files.isEmpty {
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting(output.files) }
                        .buttonStyle(QuietButtonStyle())
                }
            }
            if !output.notes.isEmpty {
                ScrollView {
                    Text(output.notes.joined(separator: "\n"))
                        .font(.system(size: 11.5, design: .monospaced))
                        .foregroundStyle(Theme.ink.opacity(0.8))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 76)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12).fill(tint.opacity(0.1)))
    }

    private var title: String {
        switch output.files.count {
        case 0: "Done"
        case 1: "Saved \(output.files[0].lastPathComponent)"
        default: "Saved \(output.files.count) files"
        }
    }
}
