import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Folders

enum Category: String, CaseIterable, Identifiable {
    case video, audio, image, background, pdf, documents, archive, security

    var id: String { rawValue }

    var title: String {
        switch self {
        case .video: "Video"
        case .audio: "Audio"
        case .image: "Image"
        case .background: "Background"
        case .pdf: "PDF"
        case .documents: "Documents"
        case .archive: "Archive"
        case .security: "Security"
        }
    }

    var blurb: String {
        switch self {
        case .video: "Convert, compress and trim clips, or turn them into GIFs."
        case .audio: "Convert, trim and level audio, or pair a track with cover art."
        case .image: "Switch formats, resize, and scrub hidden location data."
        case .background: "Cut out solid backgrounds, clean up signatures, key out green screens."
        case .pdf: "Merge, split, compress, lock, or turn images into PDFs."
        case .documents: "Convert Word, OpenDocument, RTF, HTML and text, or print them to PDF."
        case .archive: "Zip things up, or unpack ZIP, 7Z, RAR and TAR files."
        case .security: "Fingerprint any file and prove it hasn't been tampered with."
        }
    }

    var symbol: String {
        switch self {
        case .video: "film.fill"
        case .audio: "waveform"
        case .image: "photo.fill"
        case .background: "scissors"
        case .pdf: "doc.richtext.fill"
        case .documents: "doc.text.fill"
        case .archive: "archivebox.fill"
        case .security: "checkmark.shield.fill"
        }
    }

    var hex: UInt32 {
        switch self {
        case .video: 0xE8875A
        case .audio: 0xE0B04C
        case .image: 0x86B98F
        case .background: 0xB592DE
        case .pdf: 0xDA5F55
        case .documents: 0x7BA4DB
        case .archive: 0xB79A78
        case .security: 0x5CB8B2
        }
    }

    var tint: Color { Color(hex: hex) }
    var deep: Color { Color(nsColor: NSColor(hex: hex).blended(withFraction: 0.38, of: .black) ?? NSColor(hex: hex)) }
    var light: Color { Color(nsColor: NSColor(hex: hex).blended(withFraction: 0.22, of: .white) ?? NSColor(hex: hex)) }
}

// MARK: - Tools

struct JobOutput {
    var files: [URL] = []
    var notes: [String] = []
}

struct ToolError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

/// Thread-safe, throttled progress reporting back to the UI.
final class ProgressSink: @unchecked Sendable {
    private let lock = NSLock()
    private var last = -1.0
    private let handler: (Double) -> Void

    init(_ handler: @escaping (Double) -> Void) { self.handler = handler }

    func send(_ value: Double) {
        lock.lock()
        let changed = abs(value - last) >= 0.004 || value >= 1
        if changed { last = value }
        lock.unlock()
        if changed { DispatchQueue.main.async { self.handler(value) } }
    }
}

struct JobContext: @unchecked Sendable {
    var outputFolder: URL?
    var sink: ProgressSink
    var base = 0.0
    var span = 1.0

    /// Report progress for the current unit of work, 0...1.
    func progress(_ value: Double) {
        sink.send(base + span * min(max(value, 0), 1))
    }

    /// A context covering file `index` of `count`.
    func part(_ index: Int, of count: Int) -> JobContext {
        var c = self
        c.span = span / Double(max(count, 1))
        c.base = base + Double(index) * c.span
        if count > 1 { c.progress(0) }
        return c
    }

    func folder(for input: URL) -> URL {
        outputFolder ?? input.deletingLastPathComponent()
    }
}

/// One feature. Add a class conforming to this, then list it in its folder's `Toolbox` entry.
protocol FileTool: AnyObject {
    var options: AnyView? { get }
    /// Heading shown above `options`.
    var optionsTitle: String { get }
    func validate(_ inputs: [URL]) -> String?
    /// Called whenever the file list changes, so a tool can tailor its options to what was dropped.
    func inputsChanged(_ inputs: [URL])
    func run(_ inputs: [URL], _ ctx: JobContext) async throws -> JobOutput
}

extension FileTool {
    var options: AnyView? { nil }
    var optionsTitle: String { "Options" }
    func validate(_ inputs: [URL]) -> String? { nil }
    func inputsChanged(_ inputs: [URL]) {}
}

/// Orders output formats for the dropped files: best matches first, the files' own format left out.
enum FormatChoice {
    static func order<F: Hashable>(_ all: [F], best: [F], hide: F?) -> [F] {
        var out: [F] = []
        for f in best + all where f != hide && !out.contains(f) { out.append(f) }
        return out
    }

    /// The format every input shares, if they all share one.
    static func shared<F: Hashable>(_ inputs: [URL], _ format: (URL) -> F?) -> F? {
        let formats = Set(inputs.map(format))
        guard formats.count == 1, let only = formats.first else { return nil }
        return only
    }
}

struct ToolInfo: Identifiable {
    let id: String
    let name: String
    let summary: String
    let symbol: String
    let category: Category
    let types: [UTType]
    let extensions: [String]
    let multiple: Bool
    let reorderable: Bool
    let minFiles: Int
    let runLabel: String
    let make: () -> FileTool

    init(_ id: String, _ name: String, _ summary: String, symbol: String, category: Category,
         types: [UTType], extensions: [String] = [], multiple: Bool = true, reorderable: Bool = false,
         minFiles: Int = 1, runLabel: String = "Convert", make: @escaping () -> FileTool) {
        self.id = id
        self.name = name
        self.summary = summary
        self.symbol = symbol
        self.category = category
        self.types = types
        self.extensions = extensions
        self.multiple = multiple
        self.reorderable = reorderable
        self.minFiles = minFiles
        self.runLabel = runLabel
        self.make = make
    }

    var acceptsAnything: Bool { types.contains(.item) }
    var acceptsFolders: Bool { types.contains(.item) || types.contains(.folder) }

    func accepts(_ url: URL) -> Bool {
        if acceptsAnything { return true }
        let ext = url.pathExtension.lowercased()
        if extensions.contains(ext) { return true }
        guard let type = FileKind.type(of: url) else { return false }
        return types.contains { type.conforms(to: $0) }
    }

    var pickerTypes: [UTType] {
        if acceptsAnything { return [] }
        return types + extensions.compactMap { UTType(filenameExtension: $0) }
    }

    var acceptsLabel: String {
        if acceptsAnything { return "any file or folder" }
        if types == [.data] { return "any file" }
        let names = types.map { t -> String in
            if let ext = t.preferredFilenameExtension, t != .image, t != .movie, t != .audio { return ext.uppercased() }
            return (t.localizedDescription ?? t.identifier).lowercased()
        }
        return names.prefix(5).joined(separator: ", ")
    }
}

enum FileKind {
    static func type(of url: URL) -> UTType? {
        (try? url.resourceValues(forKeys: [.contentTypeKey]))?.contentType
            ?? UTType(filenameExtension: url.pathExtension)
    }

    static func `is`(_ url: URL, _ type: UTType) -> Bool {
        self.type(of: url)?.conforms(to: type) ?? false
    }
}

enum Toolbox {
    static let all: [ToolInfo] =
        video + audio + image + background + pdf + documents + archive + security

    static func tools(in category: Category) -> [ToolInfo] {
        all.filter { $0.category == category }
    }

    /// Tools that can take at least one of these files, specific tools first.
    static func matching(_ urls: [URL]) -> [ToolInfo] {
        let hits = all.filter { tool in urls.contains(where: tool.accepts) }
        return hits.filter { !$0.acceptsAnything && $0.types != [.data] }
            + hits.filter { $0.acceptsAnything || $0.types == [.data] }
    }
}
