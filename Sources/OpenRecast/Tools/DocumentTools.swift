import AppKit
import Foundation
import SwiftUI
import UniformTypeIdentifiers

extension Toolbox {
    static let documents: [ToolInfo] = [
        ToolInfo("doc-convert", "Convert Document", "Word, OpenDocument, RTF, HTML and plain text to each other or PDF.",
                 symbol: "arrow.triangle.2.circlepath", category: .documents, types: DocumentFormat.readable,
                 extensions: ["docx", "doc", "odt", "rtf", "txt", "md", "markdown", "html", "htm", "webarchive"]) { ConvertDocumentTool() },
        ToolInfo("doc-pdf", "Print to PDF", "Lay out documents as clean, paginated PDFs.",
                 symbol: "printer", category: .documents, types: DocumentFormat.readable,
                 extensions: ["docx", "doc", "odt", "rtf", "txt", "md", "markdown", "html", "htm", "webarchive"],
                 runLabel: "Create PDF") { ConvertDocumentTool(format: .pdf, fixed: true) },
    ]
}

enum DocumentFormat: String, CaseIterable {
    case pdf, docx, doc, odt, rtf, html, txt

    var title: String { rawValue.uppercased() }

    static func of(_ url: URL) -> DocumentFormat? {
        switch url.pathExtension.lowercased() {
        case "htm": .html
        case "md", "markdown": .txt
        case let ext: DocumentFormat(rawValue: ext)
        }
    }

    static func best(for url: URL) -> [DocumentFormat] {
        switch of(url) {
        case .docx: [.pdf, .odt, .rtf]
        case .doc, .odt, .rtf: [.pdf, .docx]
        case .html: [.pdf, .docx, .txt]
        default: [.pdf, .docx, .rtf]
        }
    }

    static let readable: [UTType] = [.rtf, .rtfd, .plainText, .html, .webArchive]
        + ["org.openxmlformats.wordprocessingml.document", "com.microsoft.word.doc", "org.oasis-open.opendocument.text"]
            .compactMap { UTType($0) }
}

@Observable
final class ConvertDocumentTool: FileTool {
    var format: DocumentFormat
    var paper = "a4"
    var choices = DocumentFormat.allCases
    var best: DocumentFormat?
    let fixed: Bool

    init(format: DocumentFormat = .pdf, fixed: Bool = false) {
        self.format = format
        self.fixed = fixed
    }

    var options: AnyView? { AnyView(Options(tool: self)) }

    func inputsChanged(_ inputs: [URL]) {
        guard !fixed else { return }
        guard let first = inputs.first else { choices = DocumentFormat.allCases; best = nil; return }
        choices = FormatChoice.order(DocumentFormat.allCases, best: DocumentFormat.best(for: first),
                                     hide: FormatChoice.shared(inputs, DocumentFormat.of) ?? nil)
        best = choices.first
        if let best { format = best }
    }

    func run(_ inputs: [URL], _ ctx: JobContext) async throws -> JobOutput {
        var out = JobOutput()
        for (i, url) in inputs.enumerated() {
            try Task.checkCancellation()
            let dest = Output.url(for: url, in: ctx.folder(for: url), ext: format.rawValue)
            if format == .pdf {
                let paper = self.paper
                try await MainActor.run { try Self.printPDF(url, to: dest, paper: paper) }
            } else {
                // textutil ships with macOS and handles every format in this list.
                var args = ["-convert", format.rawValue, "-output", dest.path]
                if ["md", "markdown", "txt"].contains(url.pathExtension.lowercased()) { args = ["-format", "txt"] + args }
                let result = try await Shell.run(URL(fileURLWithPath: "/usr/bin/textutil"), args + [url.path])
                guard result.status == 0, FileManager.default.fileExists(atPath: dest.path) else {
                    throw ToolError("Couldn't convert \(url.lastPathComponent).\n" + result.stderr.suffix(300))
                }
            }
            out.files.append(dest)
            ctx.progress(Double(i + 1) / Double(inputs.count))
        }
        return out
    }

    @MainActor
    private static func printPDF(_ url: URL, to dest: URL, paper: String) throws {
        var options: [NSAttributedString.DocumentReadingOptionKey: Any] = [:]
        if ["md", "markdown", "txt"].contains(url.pathExtension.lowercased()) {
            options[.documentType] = NSAttributedString.DocumentType.plain
        }
        let text: NSAttributedString
        do { text = try NSAttributedString(url: url, options: options, documentAttributes: nil) } catch {
            throw ToolError("Couldn't read \(url.lastPathComponent).")
        }

        let info = NSPrintInfo(dictionary: [.jobSavingURL: dest])
        info.jobDisposition = .save
        info.paperSize = paper == "a4" ? NSSize(width: 595.28, height: 841.89) : NSSize(width: 612, height: 792)
        info.topMargin = 54; info.bottomMargin = 54; info.leftMargin = 54; info.rightMargin = 54
        info.horizontalPagination = .fit
        info.verticalPagination = .automatic
        info.isHorizontallyCentered = false
        info.isVerticallyCentered = false

        let width = info.paperSize.width - info.leftMargin - info.rightMargin
        let view = NSTextView(frame: NSRect(x: 0, y: 0, width: width, height: 100))
        view.appearance = NSAppearance(named: .aqua) // print dark text on white, even in Dark Mode
        view.backgroundColor = .white
        view.textContainerInset = .zero
        view.textStorage?.setAttributedString(text)
        if text.length > 0, text.attribute(.foregroundColor, at: 0, effectiveRange: nil) == nil {
            view.textStorage?.addAttribute(.foregroundColor, value: NSColor.black, range: NSRange(location: 0, length: text.length))
        }
        view.isVerticallyResizable = true
        view.layoutManager?.ensureLayout(for: view.textContainer!)
        view.sizeToFit()

        let op = NSPrintOperation(view: view, printInfo: info)
        op.showsPrintPanel = false
        op.showsProgressPanel = false
        guard op.run(), FileManager.default.fileExists(atPath: dest.path) else {
            throw ToolError("Couldn't create a PDF from \(url.lastPathComponent).")
        }
    }

    struct Options: View {
        @Bindable var tool: ConvertDocumentTool
        var body: some View {
            VStack(alignment: .leading, spacing: 8) {
                if !tool.fixed {
                    OptionRow("Convert to") {
                        Chips(selection: $tool.format, options: tool.choices.map { ($0, $0.title) }, recommended: tool.best)
                    }
                }
                if tool.format == .pdf {
                    OptionRow("Paper") { Chips(selection: $tool.paper, options: [("a4", "A4"), ("letter", "US Letter")]) }
                }
            }
        }
    }
}
