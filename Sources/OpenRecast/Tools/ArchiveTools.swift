import Foundation
import SwiftUI
import UniformTypeIdentifiers

extension Toolbox {
    static let archive: [ToolInfo] = [
        ToolInfo("archive-create", "Compress", "Bundle files and folders into ZIP, 7Z, TAR.GZ or TAR.XZ.",
                 symbol: "archivebox", category: .archive, types: [.item], runLabel: "Compress") { CreateArchiveTool() },
        ToolInfo("archive-extract", "Extract", "Unpack ZIP, 7Z, RAR, TAR, GZ, BZ2, XZ and ISO.",
                 symbol: "shippingbox.and.arrow.backward", category: .archive, types: [.archive, .zip, .gzip, .bz2, .diskImage],
                 extensions: ArchiveExt.all, runLabel: "Extract") { ExtractArchiveTool() },
    ]
}

enum ArchiveExt {
    static let all = ["zip", "7z", "rar", "tar", "gz", "tgz", "bz2", "tbz", "tbz2", "xz", "txz", "zst", "lz4", "cpio", "iso", "xar", "cab", "lha", "lzh"]
}

/// macOS ships bsdtar (libarchive), which reads and writes all of these.
private let tar = URL(fileURLWithPath: "/usr/bin/tar")

@Observable
final class CreateArchiveTool: FileTool {
    var format = "zip"
    var name = ""

    var options: AnyView? { AnyView(Options(tool: self)) }

    func run(_ inputs: [URL], _ ctx: JobContext) async throws -> JobOutput {
        guard let first = inputs.first else { return JobOutput() }
        let fallback = inputs.count == 1 ? first.deletingPathExtension().lastPathComponent : "Archive"
        let base = name.trimmingCharacters(in: .whitespaces).isEmpty ? fallback : name
        let dest = Output.named(base, in: ctx.folder(for: first), ext: format)
        var args = ["-a", "--no-mac-metadata", "--exclude", ".DS_Store", "-cf", dest.path]
        for url in inputs { args += ["-C", url.deletingLastPathComponent().path, url.lastPathComponent] }
        let result = try await Shell.run(tar, args)
        guard result.status == 0 else {
            try? FileManager.default.removeItem(at: dest)
            throw ToolError("Compression failed:\n" + result.stderr.suffix(400))
        }
        return JobOutput(files: [dest], notes: ["\(inputs.count) \(inputs.count == 1 ? "item" : "items") · \(Output.bytes(Output.size(dest)))"])
    }

    struct Options: View {
        @Bindable var tool: CreateArchiveTool
        var body: some View {
            VStack(alignment: .leading, spacing: 8) {
                OptionRow("Format") {
                    Chips(selection: $tool.format, options: [("zip", "ZIP"), ("7z", "7Z"), ("tar.gz", "TAR.GZ"), ("tar.xz", "TAR.XZ")])
                }
                OptionRow("File name") { TextField("Same as the file", text: $tool.name).fieldStyle() }
            }
        }
    }
}

final class ExtractArchiveTool: FileTool {
    func run(_ inputs: [URL], _ ctx: JobContext) async throws -> JobOutput {
        var out = JobOutput()
        for (i, url) in inputs.enumerated() {
            var base = url.lastPathComponent
            while let dot = base.lastIndex(of: "."), ArchiveExt.all.contains(String(base[base.index(after: dot)...]).lowercased()) {
                base = String(base[..<dot])
            }
            let folder = try Output.folder(named: base.isEmpty ? "Extracted" : base, in: ctx.folder(for: url))
            let result = try await Shell.run(tar, ["-xf", url.path, "-C", folder.path])
            guard result.status == 0 else {
                try? FileManager.default.removeItem(at: folder)
                throw ToolError("Couldn't unpack \(url.lastPathComponent):\n" + result.stderr.suffix(400))
            }
            out.files.append(folder)
            ctx.progress(Double(i + 1) / Double(inputs.count))
        }
        return out
    }
}
