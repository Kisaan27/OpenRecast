import CryptoKit
import Foundation
import SwiftUI

extension Toolbox {
    static let security: [ToolInfo] = [
        ToolInfo("checksum", "Checksum", "Fingerprint files with SHA-256, SHA-512, SHA-1 or MD5.",
                 symbol: "number", category: .security, types: [.data], runLabel: "Calculate") { ChecksumTool() },
        ToolInfo("verify", "Verify Download", "Check a file against the hash its author published.",
                 symbol: "checkmark.seal", category: .security, types: [.data], multiple: false, runLabel: "Verify") { VerifyTool() },
    ]
}

enum HashAlgorithm: String, CaseIterable {
    case sha256 = "SHA-256", sha512 = "SHA-512", sha1 = "SHA-1", md5 = "MD5"

    var fileExtension: String { rawValue.lowercased().replacingOccurrences(of: "-", with: "") }

    /// Guesses the algorithm from a hex digest's length.
    init?(digestLength: Int) {
        switch digestLength {
        case 64: self = .sha256
        case 128: self = .sha512
        case 40: self = .sha1
        case 32: self = .md5
        default: return nil
        }
    }
}

enum Hashing {
    /// Streams the file in 4 MB chunks, so memory stays flat even for huge files.
    static func digest(of url: URL, _ algorithm: HashAlgorithm, progress: (Double) -> Void) throws -> String {
        switch algorithm {
        case .sha256: try stream(url, SHA256(), progress)
        case .sha512: try stream(url, SHA512(), progress)
        case .sha1: try stream(url, Insecure.SHA1(), progress)
        case .md5: try stream(url, Insecure.MD5(), progress)
        }
    }

    private static func stream<H: HashFunction>(_ url: URL, _ initial: H, _ progress: (Double) -> Void) throws -> String {
        var hasher = initial
        let handle: FileHandle
        do { handle = try FileHandle(forReadingFrom: url) } catch {
            throw ToolError("Couldn't open \(url.lastPathComponent).")
        }
        defer { try? handle.close() }
        let total = Double(max(Output.size(url), 1))
        var done = 0.0
        while true {
            try Task.checkCancellation()
            let chunk = try autoreleasepool { try handle.read(upToCount: 4 << 20) } ?? Data()
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
            done += Double(chunk.count)
            progress(done / total)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

@Observable
final class ChecksumTool: FileTool {
    var algorithm: HashAlgorithm = .sha256
    var saveFile = false

    var options: AnyView? { AnyView(Options(tool: self)) }

    func run(_ inputs: [URL], _ ctx: JobContext) async throws -> JobOutput {
        var out = JobOutput()
        for (i, url) in inputs.enumerated() {
            let part = ctx.part(i, of: inputs.count)
            let hash = try Hashing.digest(of: url, algorithm) { part.progress($0) }
            out.notes.append("\(hash)  \(url.lastPathComponent)")
            if saveFile {
                let dest = Output.named(url.lastPathComponent, in: ctx.folder(for: url), ext: algorithm.fileExtension)
                try "\(hash)  \(url.lastPathComponent)\n".write(to: dest, atomically: true, encoding: .utf8)
                out.files.append(dest)
            }
        }
        return out
    }

    struct Options: View {
        @Bindable var tool: ChecksumTool

        var body: some View {
            VStack(alignment: .leading, spacing: 8) {
                OptionRow("Algorithm") {
                    Chips(selection: $tool.algorithm, options: HashAlgorithm.allCases.map { ($0, $0.rawValue) })
                }
                OptionRow("Checksum file") {
                    Toggle("Save a .\(tool.algorithm.fileExtension) file next to each", isOn: $tool.saveFile)
                        .toggleStyle(.switch).controlSize(.small).font(.system(size: 12.5))
                }
            }
        }
    }
}

@Observable
final class VerifyTool: FileTool {
    var expected = ""

    var options: AnyView? { AnyView(Options(tool: self)) }

    private var cleaned: String {
        let raw = expected.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        // Accept "hash  filename" lines pasted from .sha256 files.
        return String(raw.split(whereSeparator: \.isWhitespace).first ?? "")
    }

    func validate(_ inputs: [URL]) -> String? {
        let hash = cleaned
        guard !hash.isEmpty else { return "Paste the hash the author published first." }
        guard hash.allSatisfy(\.isHexDigit), HashAlgorithm(digestLength: hash.count) != nil else {
            return "That doesn't look like an MD5, SHA-1, SHA-256 or SHA-512 hash."
        }
        return nil
    }

    func run(_ inputs: [URL], _ ctx: JobContext) async throws -> JobOutput {
        let expected = cleaned
        guard let url = inputs.first, let algorithm = HashAlgorithm(digestLength: expected.count) else { return JobOutput() }
        let actual = try Hashing.digest(of: url, algorithm) { ctx.progress($0) }
        guard actual == expected else {
            throw ToolError("Mismatch. This file is NOT the one the author published. It may be corrupted or modified.\nExpected \(expected)\nActual   \(actual)")
        }
        return JobOutput(notes: ["Match ✓ \(algorithm.rawValue) verified. The file is intact.", actual])
    }

    struct Options: View {
        @Bindable var tool: VerifyTool

        var body: some View {
            OptionRow("Expected hash") {
                TextField("Paste SHA-256, SHA-512, SHA-1 or MD5", text: $tool.expected)
                    .fieldStyle(width: 380)
            }
        }
    }
}
