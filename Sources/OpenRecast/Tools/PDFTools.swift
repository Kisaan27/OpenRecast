import CoreGraphics
import Foundation
import ImageIO
import PDFKit
import SwiftUI

extension Toolbox {
    static let pdf: [ToolInfo] = [
        ToolInfo("pdf-merge", "Merge PDFs", "Combine several PDFs into one, in the order you choose.",
                 symbol: "square.stack.3d.down.right", category: .pdf, types: [.pdf], reorderable: true,
                 minFiles: 2, runLabel: "Merge") { MergePDFTool() },
        ToolInfo("pdf-split", "Split PDF", "Break a PDF into single pages or custom ranges.",
                 symbol: "scissors", category: .pdf, types: [.pdf], runLabel: "Split") { SplitPDFTool() },
        ToolInfo("pdf-compress", "Compress PDF", "Shrink PDFs by optimising the images inside.",
                 symbol: "arrow.down.right.and.arrow.up.left", category: .pdf, types: [.pdf], runLabel: "Compress") { CompressPDFTool() },
        ToolInfo("pdf-rotate", "Rotate Pages", "Turn every page, or just some, by 90° or 180°.",
                 symbol: "rotate.right", category: .pdf, types: [.pdf], runLabel: "Rotate") { RotatePDFTool() },
        ToolInfo("pdf-password", "Password", "Lock a PDF with a password, or remove one you know.",
                 symbol: "lock", category: .pdf, types: [.pdf], runLabel: "Apply") { PasswordPDFTool() },
        ToolInfo("images-to-pdf", "Images to PDF", "Turn photos, scans and screenshots into a PDF without recompressing.",
                 symbol: "photo.on.rectangle", category: .pdf, types: [.image], reorderable: true,
                 runLabel: "Create PDF") { ImagesToPDFTool() },
        ToolInfo("pdf-to-images", "PDF to Images", "Export every page as a PNG or JPG.",
                 symbol: "rectangle.stack", category: .pdf, types: [.pdf], runLabel: "Export") { PDFToImagesTool() },
    ]
}

enum PDF {
    static func open(_ url: URL) throws -> PDFDocument {
        guard let doc = PDFDocument(url: url) else { throw ToolError("\(url.lastPathComponent) isn't a readable PDF.") }
        if doc.isLocked {
            throw ToolError("\(url.lastPathComponent) is password-protected. Unlock it with the Password tool first.")
        }
        return doc
    }

    static func save(_ doc: PDFDocument, to url: URL, options: [PDFDocumentWriteOption: Any] = [:]) throws {
        guard doc.write(to: url, withOptions: options) else { throw ToolError("Couldn't save \(url.lastPathComponent).") }
    }

    static func copy(pages range: ClosedRange<Int>, of doc: PDFDocument, into out: PDFDocument) {
        for n in range {
            if let page = doc.page(at: n - 1)?.copy() as? PDFPage { out.insert(page, at: out.pageCount) }
        }
    }

    /// Parses "1-3, 5, 8-" into 1-based page ranges.
    static func ranges(_ text: String, pageCount: Int) throws -> [ClosedRange<Int>] {
        var out: [ClosedRange<Int>] = []
        for piece in text.split(separator: ",") {
            let p = piece.trimmingCharacters(in: .whitespaces)
            if p.isEmpty { continue }
            let bits = p.split(separator: "-", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
            guard bits.count <= 2, let a = Int(bits[0]) else { throw ToolError("“\(p)” isn't a page range. Try 1-3, 5, 8-10.") }
            let b = bits.count == 2 ? (bits[1].isEmpty ? pageCount : Int(bits[1])) : a
            guard let b, a >= 1, b >= a, b <= pageCount else {
                throw ToolError("Pages “\(p)” don't fit a \(pageCount)-page PDF.")
            }
            out.append(a...b)
        }
        if out.isEmpty { throw ToolError("Enter pages like 1-3, 5, 8-10.") }
        return out
    }
}

// MARK: - Merge

@Observable
final class MergePDFTool: FileTool {
    var name = "Merged"

    var options: AnyView? { AnyView(Options(tool: self)) }

    func run(_ inputs: [URL], _ ctx: JobContext) async throws -> JobOutput {
        let merged = PDFDocument()
        var sources: [PDFDocument] = []
        for (i, url) in inputs.enumerated() {
            try Task.checkCancellation()
            let doc = try PDF.open(url)
            sources.append(doc)
            if doc.pageCount > 0 { PDF.copy(pages: 1...doc.pageCount, of: doc, into: merged) }
            ctx.progress(Double(i + 1) / Double(inputs.count + 1))
        }
        let dest = Output.named(name.isEmpty ? "Merged" : name, in: ctx.folder(for: inputs[0]), ext: "pdf")
        try PDF.save(merged, to: dest)
        return JobOutput(files: [dest], notes: ["\(merged.pageCount) pages from \(inputs.count) PDFs"])
    }

    struct Options: View {
        @Bindable var tool: MergePDFTool
        var body: some View {
            OptionRow("File name") { TextField("Merged", text: $tool.name).fieldStyle() }
        }
    }
}

// MARK: - Split

@Observable
final class SplitPDFTool: FileTool {
    enum Mode: Hashable { case every, chunks, custom }
    var mode: Mode = .every
    var chunk = 2
    var ranges = "1-3, 4-"

    var options: AnyView? { AnyView(Options(tool: self)) }

    func run(_ inputs: [URL], _ ctx: JobContext) async throws -> JobOutput {
        var out = JobOutput()
        for (i, url) in inputs.enumerated() {
            let doc = try PDF.open(url)
            let count = doc.pageCount
            let pieces: [ClosedRange<Int>] = switch mode {
            case .every: (1...max(count, 1)).map { $0...$0 }
            case .chunks: stride(from: 1, through: count, by: chunk).map { $0...min($0 + chunk - 1, count) }
            case .custom: try PDF.ranges(ranges, pageCount: count)
            }
            let base = url.deletingPathExtension().lastPathComponent
            let folder = try Output.folder(named: "\(base) (split)", in: ctx.folder(for: url))
            for (j, range) in pieces.enumerated() {
                try Task.checkCancellation()
                let part = PDFDocument()
                PDF.copy(pages: range, of: doc, into: part)
                let label = range.count == 1 ? "page \(range.lowerBound)" : "pages \(range.lowerBound)-\(range.upperBound)"
                try PDF.save(part, to: Output.named("\(base) \(label)", in: folder, ext: "pdf"))
                ctx.part(i, of: inputs.count).progress(Double(j + 1) / Double(pieces.count))
            }
            out.files.append(folder)
            out.notes.append("\(url.lastPathComponent): \(pieces.count) files")
        }
        return out
    }

    struct Options: View {
        @Bindable var tool: SplitPDFTool
        var body: some View {
            VStack(alignment: .leading, spacing: 8) {
                OptionRow("Split into") {
                    Chips(selection: $tool.mode, options: [(.every, "Single pages"), (.chunks, "Every N pages"), (.custom, "Custom ranges")])
                }
                if tool.mode == .chunks {
                    OptionRow("Pages per file") {
                        Stepper("\(tool.chunk)", value: $tool.chunk, in: 2...500).font(.system(size: 12.5))
                    }
                }
                if tool.mode == .custom {
                    OptionRow("Ranges") { TextField("1-3, 5, 8-", text: $tool.ranges).fieldStyle() }
                }
            }
        }
    }
}

// MARK: - Compress

@Observable
final class CompressPDFTool: FileTool {
    var strong = false
    var stripInfo = true

    var options: AnyView? { AnyView(Options(tool: self)) }

    func run(_ inputs: [URL], _ ctx: JobContext) async throws -> JobOutput {
        var out = JobOutput()
        for (i, url) in inputs.enumerated() {
            try Task.checkCancellation()
            let doc = try PDF.open(url)
            if stripInfo { doc.documentAttributes = [:] }
            var opts: [PDFDocumentWriteOption: Any] = [.saveImagesAsJPEGOption: true]
            if strong { opts[.optimizeImagesForScreenOption] = true }
            let dest = Output.url(for: url, in: ctx.folder(for: url), suffix: " compressed", ext: "pdf")
            try PDF.save(doc, to: dest, options: opts)
            if Output.size(dest) >= Output.size(url) {
                try? FileManager.default.removeItem(at: dest)
                out.notes.append("\(url.lastPathComponent): already as small as it gets, left unchanged")
            } else {
                out.files.append(dest)
                out.notes.append(Output.change(from: url, to: dest))
            }
            ctx.progress(Double(i + 1) / Double(inputs.count))
        }
        return out
    }

    struct Options: View {
        @Bindable var tool: CompressPDFTool
        var body: some View {
            VStack(alignment: .leading, spacing: 8) {
                OptionRow("Strength") {
                    Chips(selection: $tool.strong, options: [(false, "Balanced · print quality"), (true, "Strong · screen quality")])
                }
                OptionRow("Metadata") {
                    Toggle("Remove author, title and app info", isOn: $tool.stripInfo)
                        .toggleStyle(.switch).controlSize(.small).font(.system(size: 12.5))
                }
            }
        }
    }
}

// MARK: - Rotate

@Observable
final class RotatePDFTool: FileTool {
    var angle = 90
    var allPages = true
    var ranges = "1"

    var options: AnyView? { AnyView(Options(tool: self)) }

    func run(_ inputs: [URL], _ ctx: JobContext) async throws -> JobOutput {
        var out = JobOutput()
        for url in inputs {
            try Task.checkCancellation()
            let doc = try PDF.open(url)
            let targets = allPages ? [1...max(doc.pageCount, 1)] : try PDF.ranges(ranges, pageCount: doc.pageCount)
            for range in targets {
                for n in range {
                    if let page = doc.page(at: n - 1) { page.rotation = (page.rotation + angle) % 360 }
                }
            }
            let dest = Output.url(for: url, in: ctx.folder(for: url), suffix: " rotated", ext: "pdf")
            try PDF.save(doc, to: dest)
            out.files.append(dest)
        }
        return out
    }

    struct Options: View {
        @Bindable var tool: RotatePDFTool
        var body: some View {
            VStack(alignment: .leading, spacing: 8) {
                OptionRow("Turn") {
                    Chips(selection: $tool.angle, options: [(90, "90° right"), (180, "180°"), (270, "90° left")])
                }
                OptionRow("Pages") {
                    Chips(selection: $tool.allPages, options: [(true, "All pages"), (false, "Only these")])
                    if !tool.allPages { TextField("1, 3-4", text: $tool.ranges).fieldStyle(width: 120) }
                }
            }
        }
    }
}

// MARK: - Password

@Observable
final class PasswordPDFTool: FileTool {
    var lock = true
    var password = ""
    var confirm = ""

    var options: AnyView? { AnyView(Options(tool: self)) }

    func validate(_ inputs: [URL]) -> String? {
        if password.isEmpty { return "Enter a password." }
        if lock && password != confirm { return "The two passwords don't match." }
        return nil
    }

    func run(_ inputs: [URL], _ ctx: JobContext) async throws -> JobOutput {
        var out = JobOutput()
        for url in inputs {
            try Task.checkCancellation()
            guard let doc = PDFDocument(url: url) else { throw ToolError("\(url.lastPathComponent) isn't a readable PDF.") }
            if lock {
                if doc.isLocked { throw ToolError("\(url.lastPathComponent) is already locked.") }
                let dest = Output.url(for: url, in: ctx.folder(for: url), suffix: " locked", ext: "pdf")
                try PDF.save(doc, to: dest, options: [.userPasswordOption: password, .ownerPasswordOption: password])
                out.files.append(dest)
            } else {
                guard doc.isEncrypted else {
                    out.notes.append("\(url.lastPathComponent) wasn't password-protected.")
                    continue
                }
                if doc.isLocked && !doc.unlock(withPassword: password) {
                    throw ToolError("Wrong password for \(url.lastPathComponent).")
                }
                let plain = PDFDocument()
                if doc.pageCount > 0 { PDF.copy(pages: 1...doc.pageCount, of: doc, into: plain) }
                let dest = Output.url(for: url, in: ctx.folder(for: url), suffix: " unlocked", ext: "pdf")
                try PDF.save(plain, to: dest)
                out.files.append(dest)
            }
        }
        return out
    }

    struct Options: View {
        @Bindable var tool: PasswordPDFTool
        var body: some View {
            VStack(alignment: .leading, spacing: 8) {
                OptionRow("Action") {
                    Chips(selection: $tool.lock, options: [(true, "Add password"), (false, "Remove password")])
                }
                OptionRow("Password") { SecureField("Password", text: $tool.password).fieldStyle() }
                if tool.lock {
                    OptionRow("Confirm") { SecureField("Type it again", text: $tool.confirm).fieldStyle() }
                }
            }
        }
    }
}

// MARK: - Images → PDF

@Observable
final class ImagesToPDFTool: FileTool {
    enum PageSize: Hashable { case original, a4, letter }
    var pageSize: PageSize = .original
    var margins = true
    var onePerImage = false
    var name = "Images"

    var options: AnyView? { AnyView(Options(tool: self)) }

    func run(_ inputs: [URL], _ ctx: JobContext) async throws -> JobOutput {
        if onePerImage {
            var files: [URL] = []
            for (i, url) in inputs.enumerated() {
                let dest = Output.url(for: url, in: ctx.folder(for: url), ext: "pdf")
                try build([url], to: dest, ctx.part(i, of: inputs.count))
                files.append(dest)
            }
            return JobOutput(files: files)
        }
        let dest = Output.named(name.isEmpty ? "Images" : name, in: ctx.folder(for: inputs[0]), ext: "pdf")
        try build(inputs, to: dest, ctx)
        return JobOutput(files: [dest], notes: ["\(inputs.count) pages"])
    }

    /// Upright images are embedded as-is (JPEG data is passed straight through); rotated photos are drawn upright.
    private func build(_ images: [URL], to dest: URL, _ ctx: JobContext) throws {
        guard let pdf = CGContext(dest as CFURL, mediaBox: nil, nil) else { throw ToolError("Couldn't create \(dest.lastPathComponent).") }
        do {
            for (i, url) in images.enumerated() {
                try Task.checkCancellation()
                try autoreleasepool {
                    let src = try ImageKit.source(url)
                    let image: CGImage
                    if ImageKit.orientation(src) == 1, let raw = CGImageSourceCreateImageAtIndex(src, 0, nil) {
                        image = raw
                    } else {
                        image = try ImageKit.load(url)
                    }
                    let props = ImageKit.properties(src)
                    let dpi = (props[kCGImagePropertyDPIWidth] as? Double).flatMap { $0 > 0 ? $0 : nil } ?? 72
                    let natural = CGSize(width: Double(image.width) * 72 / dpi, height: Double(image.height) * 72 / dpi)
                    var box = CGRect(origin: .zero, size: natural)
                    var target = box
                    if pageSize != .original {
                        var page = pageSize == .a4 ? CGSize(width: 595.28, height: 841.89) : CGSize(width: 612, height: 792)
                        if natural.width > natural.height { page = CGSize(width: page.height, height: page.width) }
                        box = CGRect(origin: .zero, size: page)
                        let area = box.insetBy(dx: margins ? 36 : 0, dy: margins ? 36 : 0)
                        let s = min(area.width / natural.width, area.height / natural.height)
                        let w = natural.width * s, h = natural.height * s
                        target = CGRect(x: area.midX - w / 2, y: area.midY - h / 2, width: w, height: h)
                    }
                    pdf.beginPage(mediaBox: &box)
                    pdf.draw(image, in: target)
                    pdf.endPage()
                }
                ctx.progress(Double(i + 1) / Double(images.count))
            }
            pdf.closePDF()
        } catch {
            pdf.closePDF()
            try? FileManager.default.removeItem(at: dest)
            throw error
        }
    }

    struct Options: View {
        @Bindable var tool: ImagesToPDFTool
        var body: some View {
            VStack(alignment: .leading, spacing: 8) {
                OptionRow("Page size") {
                    Chips(selection: $tool.pageSize, options: [(.original, "Match image"), (.a4, "A4"), (.letter, "Letter")])
                    if tool.pageSize != .original {
                        Toggle("Margins", isOn: $tool.margins).toggleStyle(.switch).controlSize(.small).font(.system(size: 12.5))
                    }
                }
                OptionRow("Output") {
                    Chips(selection: $tool.onePerImage, options: [(false, "One PDF"), (true, "One PDF per image")])
                }
                if !tool.onePerImage {
                    OptionRow("File name") { TextField("Images", text: $tool.name).fieldStyle() }
                }
            }
        }
    }
}

// MARK: - PDF → Images

@Observable
final class PDFToImagesTool: FileTool {
    var png = true
    var dpi = 150

    var options: AnyView? { AnyView(Options(tool: self)) }

    func run(_ inputs: [URL], _ ctx: JobContext) async throws -> JobOutput {
        var out = JobOutput()
        let ext = png ? "png" : "jpg"
        for (i, url) in inputs.enumerated() {
            let doc = try PDF.open(url)
            let base = url.deletingPathExtension().lastPathComponent
            let folder = doc.pageCount > 1
                ? try Output.folder(named: "\(base) (images)", in: ctx.folder(for: url))
                : ctx.folder(for: url)
            var written: [URL] = []
            for n in 0..<doc.pageCount {
                try Task.checkCancellation()
                try autoreleasepool {
                    guard let page = doc.page(at: n)?.pageRef else { return }
                    let image = try render(page)
                    let dest = Output.named(doc.pageCount > 1 ? "\(base) \(n + 1)" : base, in: folder, ext: ext)
                    try ImageKit.write(image, to: dest, type: png ? .png : .jpeg, quality: png ? nil : 0.9)
                    written.append(dest)
                }
                ctx.part(i, of: inputs.count).progress(Double(n + 1) / Double(doc.pageCount))
            }
            out.files += doc.pageCount > 1 ? [folder] : written
            out.notes.append("\(url.lastPathComponent): \(doc.pageCount) pages")
        }
        return out
    }

    private func render(_ page: CGPDFPage) throws -> CGImage {
        let box = page.getBoxRect(.cropBox)
        let quarterTurn = page.rotationAngle % 180 != 0
        let size = quarterTurn ? CGSize(width: box.height, height: box.width) : box.size
        let scale = CGFloat(dpi) / 72
        let w = Int(size.width * scale), h = Int(size.height * scale)
        guard w > 0, h > 0,
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: ImageKit.sRGB,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { throw ToolError("A page is too large to render.") }
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.interpolationQuality = .high
        ctx.scaleBy(x: scale, y: scale)
        ctx.concatenate(page.getDrawingTransform(.cropBox, rect: CGRect(origin: .zero, size: size), rotate: 0, preserveAspectRatio: true))
        ctx.drawPDFPage(page)
        guard let image = ctx.makeImage() else { throw ToolError("Couldn't render a page.") }
        return image
    }

    struct Options: View {
        @Bindable var tool: PDFToImagesTool
        var body: some View {
            VStack(alignment: .leading, spacing: 8) {
                OptionRow("Format") { Chips(selection: $tool.png, options: [(true, "PNG"), (false, "JPG")]) }
                OptionRow("Resolution") {
                    Chips(selection: $tool.dpi, options: [(72, "72 dpi · screen"), (150, "150 dpi"), (300, "300 dpi · print")])
                }
            }
        }
    }
}
