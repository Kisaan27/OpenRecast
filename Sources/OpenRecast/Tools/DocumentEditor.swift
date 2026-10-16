import AppKit
import SwiftUI

// MARK: - Edit Document

/// Opens the dropped document straight into an editable page, then saves the edited copy in any format.
@Observable
final class EditDocumentTool: FileTool {
    var format: DocumentFormat = .docx
    var original: DocumentFormat?
    var paper = "a4"
    var loaded: URL?
    var loadError: String?
    @ObservationIgnored let storage = NSTextStorage()
    @ObservationIgnored let editor = EditorController()

    var optionsTitle: String { "Edit" }
    var options: AnyView? { AnyView(Options(tool: self)) }

    func inputsChanged(_ inputs: [URL]) {
        guard let url = inputs.first else {
            loaded = nil
            storage.setAttributedString(NSAttributedString())
            editor.refresh()
            return
        }
        guard url != loaded else { return }
        loaded = url
        do {
            storage.setAttributedString(try DocumentText.read(url))
            loadError = nil
        } catch {
            storage.setAttributedString(NSAttributedString())
            loadError = error.localizedDescription
        }
        original = DocumentFormat.of(url)
        format = original ?? .docx
        editor.didLoad()
    }

    func validate(_ inputs: [URL]) -> String? { loadError }

    func run(_ inputs: [URL], _ ctx: JobContext) async throws -> JobOutput {
        guard let url = inputs.first else { return JobOutput() }
        let format = await MainActor.run { self.format }
        let dest = Output.url(for: url, in: ctx.folder(for: url), suffix: " edited", ext: format.rawValue)
        // The text lives in the editor, so save it from the main thread.
        try await MainActor.run {
            if format == .pdf {
                try DocumentText.printPDF(storage, to: dest, paper: paper, name: url.lastPathComponent)
            } else {
                try DocumentText.write(storage, as: format, to: dest)
            }
        }
        ctx.progress(1)
        return JobOutput(files: [dest], notes: format == .txt ? ["Plain text keeps the words but drops the styling."] : [])
    }

    struct Options: View {
        @Bindable var tool: EditDocumentTool

        var body: some View {
            if let error = tool.loadError {
                Text(error).font(.system(size: 12.5)).foregroundStyle(Theme.bad)
            } else if tool.loaded == nil {
                Text("Drop a Word, OpenDocument, RTF, HTML or text file above. It opens here, ready to edit.")
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.muted)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    EditorToolbar(editor: tool.editor)
                    DocumentEditorView(storage: tool.storage, editor: tool.editor)
                        .frame(minHeight: 150, maxHeight: .infinity)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.line))
                    OptionRow("Save as") {
                        Chips(selection: $tool.format, options: DocumentFormat.allCases.map { ($0, $0.title) },
                              recommended: tool.original)
                        if tool.format == .pdf {
                            Chips(selection: $tool.paper, options: [("a4", "A4"), ("letter", "Letter")])
                        }
                    }
                }
                .frame(maxHeight: .infinity)
            }
        }
    }
}

// MARK: - Editor controller

/// Formatting commands and live stats for the text view behind the editor.
@Observable
final class EditorController {
    @ObservationIgnored weak var textView: NSTextView?
    private(set) var words = 0
    private(set) var characters = 0
    private(set) var edited = false
    /// The result of the last tidy-up, shown briefly in the toolbar.
    var message: String?

    static let defaultFont = NSFont(name: "Helvetica", size: 12) ?? .systemFont(ofSize: 12)

    func didLoad() {
        edited = false
        message = nil
        refresh()
        textView?.undoManager?.removeAllActions()
        textView?.scrollRangeToVisible(NSRange(location: 0, length: 0))
    }

    func textChanged() {
        edited = true
        refresh()
    }

    func refresh() {
        let text = textView?.textStorage?.string ?? ""
        words = text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).count
        characters = text.count
    }

    // Styling

    func toggle(_ trait: NSFontTraitMask) {
        let fm = NSFontManager.shared
        restyleFonts { fonts in
            let all = fonts.allSatisfy { fm.traits(of: $0).contains(trait) }
            return { all ? fm.convert($0, toNotHaveTrait: trait) : fm.convert($0, toHaveTrait: trait) }
        }
    }

    func resize(by delta: CGFloat) {
        restyleFonts { _ in { NSFontManager.shared.convert($0, toSize: min(max($0.pointSize + delta, 6), 96)) } }
    }

    func toggleUnderline() {
        guard let tv = textView, let storage = tv.textStorage else { return }
        let range = tv.selectedRange()
        if range.length == 0 {
            let on = (tv.typingAttributes[.underlineStyle] as? Int ?? 0) != 0
            tv.typingAttributes[.underlineStyle] = on ? 0 : NSUnderlineStyle.single.rawValue
            return
        }
        var all = true
        storage.enumerateAttribute(.underlineStyle, in: range) { v, _, _ in if (v as? Int ?? 0) == 0 { all = false } }
        change(range) {
            if all { storage.removeAttribute(.underlineStyle, range: range) }
            else { storage.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: range) }
        }
    }

    func align(_ alignment: NSTextAlignment) {
        guard let tv = textView else { return }
        switch alignment {
        case .center: tv.alignCenter(nil)
        case .right: tv.alignRight(nil)
        case .justified: tv.alignJustified(nil)
        default: tv.alignLeft(nil)
        }
    }

    /// Adds "• " to each selected paragraph, or takes it away if they all have one.
    func toggleBullets() {
        guard let tv = textView, let storage = tv.textStorage else { return }
        let text = storage.string as NSString
        let whole = text.paragraphRange(for: tv.selectedRange())
        var starts: [Int] = []
        text.enumerateSubstrings(in: whole, options: [.byParagraphs, .substringNotRequired]) { _, r, _, _ in starts.append(r.location) }
        guard !starts.isEmpty else { return }
        let bullet = "• "
        let all = starts.allSatisfy { text.length >= $0 + 2 && text.substring(with: NSRange(location: $0, length: 2)) == bullet }
        group {
            for start in starts.reversed() {
                let r = all ? NSRange(location: start, length: 2) : NSRange(location: start, length: 0)
                replace(r, with: all ? "" : bullet)
            }
        }
    }

    func clearFormatting() {
        guard let tv = textView, let storage = tv.textStorage else { return }
        var range = tv.selectedRange()
        if range.length == 0 { range = NSRange(location: 0, length: storage.length) }
        change(range) {
            storage.setAttributes([.font: Self.defaultFont, .foregroundColor: NSColor.black], range: range)
        }
    }

    func showFind(replace: Bool) {
        guard let tv = textView else { return }
        tv.window?.makeFirstResponder(tv)
        let item = NSMenuItem()
        item.tag = (replace ? NSTextFinder.Action.showReplaceInterface : .showFindInterface).rawValue
        tv.performTextFinderAction(item)
    }

    // Automatic tidy-ups

    enum Tidy: CaseIterable {
        case all, doubleSpaces, trailingSpaces, blankLines, spaceBeforePunctuation, smartQuotes, capitalise

        var title: String {
            switch self {
            case .all: "Tidy everything"
            case .doubleSpaces: "Fix double spaces"
            case .trailingSpaces: "Remove spaces at line ends"
            case .blankLines: "Collapse extra blank lines"
            case .spaceBeforePunctuation: "Remove spaces before punctuation"
            case .smartQuotes: "Use curly quotes"
            case .capitalise: "Capitalise sentences"
            }
        }
    }

    func tidy(_ kind: Tidy) {
        var fixed = 0
        group {
            switch kind {
            case .all:
                for k in Tidy.allCases where k != .all && k != .smartQuotes { fixed += apply(k) }
            default:
                fixed = apply(kind)
            }
        }
        message = fixed == 0 ? "Nothing to fix" : "Fixed \(fixed) \(fixed == 1 ? "spot" : "spots")"
        let shown = message
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            if self?.message == shown { self?.message = nil }
        }
    }

    private func apply(_ kind: Tidy) -> Int {
        switch kind {
        case .all: 0
        case .doubleSpaces: replaceAll(#"(?<=\S)[ \t]{2,}(?=\S)"#) { _ in " " }
        case .trailingSpaces: replaceAll(#"[ \t]+$"#, lines: true) { _ in "" }
        case .blankLines: replaceAll(#"\n[ \t]*\n(?:[ \t]*\n)+"#) { _ in "\n\n" }
        case .spaceBeforePunctuation: replaceAll(#"(?<=\w)[ \t]+(?=[,.;:!?](?:\s|$))"#) { _ in "" }
        case .smartQuotes:
            replaceAll("(?:^|(?<=[\\s(\\[{—–-]))\"", lines: true) { _ in "“" }
                + replaceAll("\"") { _ in "”" }
                + replaceAll("(?:^|(?<=[\\s(\\[{—–-]))'", lines: true) { _ in "‘" }
                + replaceAll("'") { _ in "’" }
        case .capitalise:
            replaceAll(#"(?:^|(?<=[.!?][\s ]))\p{Ll}"#, lines: true) { $0.uppercased() }
        }
    }

    /// Replaces each match, keeping the formatting around it, as one undoable step. Returns the count.
    @discardableResult
    private func replaceAll(_ pattern: String, lines: Bool = false, _ transform: (String) -> String) -> Int {
        guard let tv = textView, let storage = tv.textStorage,
              let regex = try? NSRegularExpression(pattern: pattern, options: lines ? [.anchorsMatchLines] : [])
        else { return 0 }
        let text = storage.string as NSString
        let matches = regex.matches(in: storage.string, range: NSRange(location: 0, length: text.length))
        var count = 0
        for m in matches.reversed() {
            let old = text.substring(with: m.range)
            let new = transform(old)
            guard new != old else { continue }
            replace(m.range, with: new)
            count += 1
        }
        return count
    }

    // Plumbing

    /// Applies a font change to the selection, or to what's typed next when nothing is selected.
    private func restyleFonts(_ make: ([NSFont]) -> (NSFont) -> NSFont) {
        guard let tv = textView, let storage = tv.textStorage else { return }
        let range = tv.selectedRange()
        if range.length == 0 {
            let font = tv.typingAttributes[.font] as? NSFont ?? Self.defaultFont
            tv.typingAttributes[.font] = make([font])(font)
            return
        }
        var fonts: [NSFont] = []
        storage.enumerateAttribute(.font, in: range) { v, _, _ in fonts.append(v as? NSFont ?? Self.defaultFont) }
        let convert = make(fonts)
        change(range) {
            storage.enumerateAttribute(.font, in: range) { v, r, _ in
                storage.addAttribute(.font, value: convert(v as? NSFont ?? Self.defaultFont), range: r)
            }
        }
    }

    /// An undoable attribute change.
    private func change(_ range: NSRange, _ body: () -> Void) {
        guard let tv = textView, let storage = tv.textStorage,
              tv.shouldChangeText(in: range, replacementString: nil) else { return }
        storage.beginEditing()
        body()
        storage.endEditing()
        tv.didChangeText()
    }

    /// An undoable text replacement.
    private func replace(_ range: NSRange, with string: String) {
        guard let tv = textView, let storage = tv.textStorage,
              tv.shouldChangeText(in: range, replacementString: string) else { return }
        storage.replaceCharacters(in: range, with: string)
        tv.didChangeText()
    }

    private func group(_ body: () -> Void) {
        let undo = textView?.undoManager
        undo?.beginUndoGrouping()
        body()
        undo?.endUndoGrouping()
    }
}

// MARK: - Views

private struct EditorToolbar: View {
    let editor: EditorController

    var body: some View {
        HStack(spacing: 2) {
            ToolbarIcon("bold", "Bold") { editor.toggle(.boldFontMask) }
            ToolbarIcon("italic", "Italic") { editor.toggle(.italicFontMask) }
            ToolbarIcon("underline", "Underline") { editor.toggleUnderline() }
            divider
            ToolbarIcon("textformat.size.smaller", "Smaller text") { editor.resize(by: -1) }
            ToolbarIcon("textformat.size.larger", "Larger text") { editor.resize(by: 1) }
            divider
            ToolbarIcon("text.alignleft", "Align left") { editor.align(.left) }
            ToolbarIcon("text.aligncenter", "Centre") { editor.align(.center) }
            ToolbarIcon("text.alignright", "Align right") { editor.align(.right) }
            ToolbarIcon("text.justify", "Justify") { editor.align(.justified) }
            ToolbarIcon("list.bullet", "Bulleted list") { editor.toggleBullets() }
            divider
            ToolbarIcon("magnifyingglass", "Find and replace (⌘F)") { editor.showFind(replace: true) }
            Menu {
                ForEach(EditorController.Tidy.allCases, id: \.self) { kind in
                    Button(kind.title) { editor.tidy(kind) }
                    if kind == .all { Divider() }
                }
            } label: {
                Label("Tidy up", systemImage: "wand.and.stars").font(.system(size: 12, weight: .medium))
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .padding(.horizontal, 6)
            .help("Fix spacing, quotes and capitals automatically")
            ToolbarIcon("eraser", "Clear formatting") { editor.clearFormatting() }

            Spacer(minLength: 8)

            Group {
                if let message = editor.message {
                    Text(message).foregroundStyle(Theme.good)
                } else {
                    Text("\(editor.words.formatted()) words · \(editor.characters.formatted()) characters")
                        .foregroundStyle(Theme.muted)
                }
            }
            .font(.system(size: 11).monospacedDigit())
            .lineLimit(1)
        }
    }

    private var divider: some View {
        Rectangle().fill(Theme.line).frame(width: 1, height: 16).padding(.horizontal, 4)
    }
}

private struct ToolbarIcon: View {
    let symbol: String
    let help: String
    let action: () -> Void
    @State private var hovering = false

    init(_ symbol: String, _ help: String, action: @escaping () -> Void) {
        self.symbol = symbol
        self.help = help
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.ink.opacity(0.8))
                .frame(width: 26, height: 24)
                .background(RoundedRectangle(cornerRadius: 6).fill(Theme.ink.opacity(hovering ? 0.08 : 0)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
    }
}

/// A white page backed by the tool's text storage, so edits survive the view being rebuilt.
private struct DocumentEditorView: NSViewRepresentable {
    let storage: NSTextStorage
    let editor: EditorController

    final class Coordinator {
        var layout: NSLayoutManager?
        var observer: NSObjectProtocol?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let layout = NSLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        layout.addTextContainer(container)

        let tv = NSTextView(frame: NSRect(x: 0, y: 0, width: 500, height: 300), textContainer: container)
        tv.minSize = .zero
        tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.autoresizingMask = [.width]
        tv.isRichText = true
        tv.importsGraphics = true
        tv.allowsUndo = true
        tv.usesFindBar = true
        tv.isIncrementalSearchingEnabled = true
        tv.usesFontPanel = true
        tv.isContinuousSpellCheckingEnabled = true
        tv.textContainerInset = NSSize(width: 26, height: 22)
        // Documents are printed dark on white, so edit them that way even in Dark Mode.
        tv.drawsBackground = true
        tv.backgroundColor = .white
        tv.insertionPointColor = .black
        tv.typingAttributes[.font] = EditorController.defaultFont
        tv.typingAttributes[.foregroundColor] = NSColor.black

        let scroll = NSScrollView()
        scroll.appearance = NSAppearance(named: .aqua)
        scroll.documentView = tv
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = true
        scroll.backgroundColor = .white

        context.coordinator.layout = layout
        context.coordinator.observer = NotificationCenter.default.addObserver(
            forName: NSText.didChangeNotification, object: tv, queue: .main) { [weak editor] _ in editor?.textChanged() }
        editor.textView = tv
        editor.refresh()
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        if let tv = scroll.documentView as? NSTextView, editor.textView !== tv { editor.textView = tv }
    }

    static func dismantleNSView(_ scroll: NSScrollView, coordinator: Coordinator) {
        if let observer = coordinator.observer { NotificationCenter.default.removeObserver(observer) }
        if let layout = coordinator.layout { layout.textStorage?.removeLayoutManager(layout) }
    }
}
