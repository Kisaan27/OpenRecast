import SwiftUI

/// Query, keyboard selection and results for a tool search box.
@Observable
final class SearchState {
    var query = "" {
        didSet {
            guard query != oldValue else { return }
            results = ToolSearch.search(query)
            selection = 0
        }
    }
    private(set) var results: [ToolInfo] = []
    var selection = 0

    var isActive: Bool { !query.trimmingCharacters(in: .whitespaces).isEmpty }
    var selected: ToolInfo? { results.indices.contains(selection) ? results[selection] : nil }

    func move(_ step: Int) {
        guard !results.isEmpty else { return }
        selection = (selection + step + results.count) % results.count
    }
}

/// A pill-shaped search box. Arrow keys move through results, Return opens, Escape clears.
struct SearchField: View {
    @Bindable var search: SearchState
    var focused: FocusState<Bool>.Binding
    var placeholder = "Search tools: try “shrink video” or “mp3”"
    let onOpen: (ToolInfo) -> Void

    var body: some View {
        let isFocused = focused.wrappedValue
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(isFocused ? Theme.accent : Theme.muted)
            TextField(placeholder, text: $search.query)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .foregroundStyle(Theme.ink)
                .focused(focused)
                .onSubmit { if let tool = search.selected { onOpen(tool) } }
                .onKeyPress(.downArrow) { search.move(1); return .handled }
                .onKeyPress(.upArrow) { search.move(-1); return .handled }
                .onKeyPress(.escape) {
                    if search.query.isEmpty { focused.wrappedValue = false } else { search.query = "" }
                    return .handled
                }
            if search.query.isEmpty {
                Text("⌘K")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(Theme.muted)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(RoundedRectangle(cornerRadius: 5).fill(Theme.ink.opacity(0.06)))
                    .overlay(RoundedRectangle(cornerRadius: 5).stroke(Theme.line))
            } else {
                Button { search.query = "" } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 12)).foregroundStyle(Theme.muted)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 34)
        .background(Capsule().fill(Theme.ink.opacity(isFocused ? 0.07 : 0.045)))
        .overlay(Capsule().stroke(isFocused ? Theme.accent.opacity(0.55) : Theme.line))
        .contentShape(Capsule())
        .onTapGesture { focused.wrappedValue = true }
        .animation(.easeOut(duration: 0.15), value: isFocused)
        // ⌘K jumps to the search box from anywhere on the screen.
        .background {
            Button("") { focused.wrappedValue = true }
                .keyboardShortcut("k", modifiers: .command)
                .opacity(0)
                .frame(width: 0, height: 0)
        }
    }
}

/// The ranked list under a search box.
struct SearchResults: View {
    let search: SearchState
    var showsCategory = true
    let onOpen: (ToolInfo) -> Void

    var body: some View {
        if search.results.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text("Nothing matches “\(search.query)”.")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.ink.opacity(0.85))
                Text("Try what you want to do, like “smaller”, “cut”, “unzip” or a format such as “heic”.")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(Array(search.results.enumerated()), id: \.element.id) { index, tool in
                            Button { onOpen(tool) } label: {
                                ToolRowLabel(tool: tool, selected: index == search.selection, showsCategory: showsCategory)
                            }
                            .buttonStyle(.plain)
                            .id(index)
                        }
                    }
                    .padding(4)
                }
                .onChange(of: search.selection) { proxy.scrollTo(search.selection) }
            }
        }
    }
}
