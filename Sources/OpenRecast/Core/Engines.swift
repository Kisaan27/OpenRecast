import Foundation

// MARK: - Output naming

enum Output {
    static func url(for input: URL, in dir: URL, suffix: String = "", ext: String) -> URL {
        named(input.deletingPathExtension().lastPathComponent + suffix, in: dir, ext: ext)
    }

    static func named(_ name: String, in dir: URL, ext: String) -> URL {
        var url = dir.appendingPathComponent(name)
        if !ext.isEmpty { url.appendPathExtension(ext) }
        return unique(url)
    }

    /// Never overwrite: "photo.png" becomes "photo 2.png", "photo 3.png"…
    static func unique(_ url: URL) -> URL {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return url }
        let dir = url.deletingLastPathComponent()
        let ext = url.pathExtension
        let base = url.deletingPathExtension().lastPathComponent
        var n = 2
        while true {
            var candidate = dir.appendingPathComponent("\(base) \(n)")
            if !ext.isEmpty { candidate.appendPathExtension(ext) }
            if !fm.fileExists(atPath: candidate.path) { return candidate }
            n += 1
        }
    }

    static func folder(named name: String, in dir: URL) throws -> URL {
        let url = unique(dir.appendingPathComponent(name, isDirectory: true))
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func size(_ url: URL) -> Int64 {
        Int64((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
    }

    static func bytes(_ n: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: n, countStyle: .file)
    }

    static func change(from a: URL, to b: URL) -> String {
        let x = size(a), y = size(b)
        let pct = x > 0 ? Int(((Double(y) / Double(x)) - 1) * 100) : 0
        return "\(a.lastPathComponent): \(bytes(x)) → \(bytes(y)) (\(pct > 0 ? "+" : "")\(pct)%)"
    }

    static func temporary(ext: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("openrecast-" + UUID().uuidString)
            .appendingPathExtension(ext)
    }
}

// MARK: - Processes

struct ShellResult {
    let status: Int32
    let stdout: String
    let stderr: String
}

/// Collects a pipe's output (keeping only the tail) and optionally reports it line by line.
private final class Collector: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    private var partial = Data()
    private let onLine: (@Sendable (String) -> Void)?

    init(onLine: (@Sendable (String) -> Void)?) { self.onLine = onLine }

    func append(_ chunk: Data) {
        guard !chunk.isEmpty else { return }
        var lines: [String] = []
        lock.lock()
        data.append(chunk)
        if data.count > 512_000 { data = data.suffix(256_000) }
        if onLine != nil {
            partial.append(chunk)
            while let i = partial.firstIndex(of: 10) {
                lines.append(String(decoding: partial[partial.startIndex..<i], as: UTF8.self))
                partial = Data(partial[partial.index(after: i)...])
            }
        }
        lock.unlock()
        for line in lines { onLine?(line) }
    }

    var text: String {
        lock.lock()
        defer { lock.unlock() }
        return String(decoding: data, as: UTF8.self)
    }
}

enum Shell {
    /// Runs a program to completion. Cancelling the calling task terminates it.
    static func run(_ executable: URL, _ args: [String],
                    onStdoutLine: (@Sendable (String) -> Void)? = nil) async throws -> ShellResult {
        let process = Process()
        process.executableURL = executable
        process.arguments = args
        process.standardInput = FileHandle.nullDevice
        let outPipe = Pipe(), errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        let out = Collector(onLine: onStdoutLine), err = Collector(onLine: nil)
        outPipe.fileHandleForReading.readabilityHandler = { out.append($0.availableData) }
        errPipe.fileHandleForReading.readabilityHandler = { err.append($0.availableData) }

        let status: Int32 = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { cont in
                process.terminationHandler = { cont.resume(returning: $0.terminationStatus) }
                do {
                    try process.run()
                    if Task.isCancelled { process.terminate() }
                } catch {
                    process.terminationHandler = nil
                    cont.resume(throwing: error)
                }
            }
        } onCancel: {
            if process.isRunning { process.terminate() }
        }

        outPipe.fileHandleForReading.readabilityHandler = nil
        errPipe.fileHandleForReading.readabilityHandler = nil
        out.append(outPipe.fileHandleForReading.readDataToEndOfFile())
        err.append(errPipe.fileHandleForReading.readDataToEndOfFile())
        try Task.checkCancellation()
        return ShellResult(status: status, stdout: out.text, stderr: err.text)
    }
}

// MARK: - ffmpeg

struct MediaInfo {
    var duration: Double?
    var sampleRate: Int?
}

enum FFmpeg {
    static let binary: URL? = {
        var candidates: [URL] = []
        if let res = Bundle.main.resourceURL { candidates.append(res.appendingPathComponent("bin/ffmpeg")) }
        if let exe = Bundle.main.executableURL?.deletingLastPathComponent() {
            candidates.append(exe.appendingPathComponent("bin/ffmpeg"))
        }
        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        candidates.append(cwd.appendingPathComponent("Resources/bin/ffmpeg"))
        candidates += ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg"].map(URL.init(fileURLWithPath:))
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }()

    private static func requireBinary() throws -> URL {
        guard let binary else {
            throw ToolError("OpenRecast's media engine (ffmpeg) is missing. If you built from source, run scripts/fetch_binaries.sh.")
        }
        return binary
    }

    /// Reads duration and sample rate from ffmpeg's own banner, so no separate ffprobe is needed.
    static func probe(_ input: URL) async -> MediaInfo {
        guard let binary,
              let r = try? await Shell.run(binary, ["-hide_banner", "-nostdin", "-i", input.path])
        else { return MediaInfo() }
        var info = MediaInfo()
        if let m = r.stderr.firstMatch(of: durationPattern),
           let h = Double(m.output[1].substring ?? ""), let mi = Double(m.output[2].substring ?? ""),
           let s = Double(m.output[3].substring ?? "") {
            info.duration = h * 3600 + mi * 60 + s
        }
        if let m = r.stderr.firstMatch(of: ratePattern), let hz = Int(m.output[1].substring ?? "") {
            info.sampleRate = hz
        }
        return info
    }

    private static let durationPattern = try! Regex(#"Duration: (\d+):(\d+):([\d.]+)"#)
    private static let ratePattern = try! Regex(#"Audio:.*?, (\d+) Hz"#)

    /// Runs ffmpeg with `args`, writing `output`. Reports progress when `duration` is known.
    static func run(_ args: [String], output: URL, duration: Double?, _ ctx: JobContext) async throws {
        let binary = try requireBinary()
        let full = ["-hide_banner", "-nostdin", "-y", "-nostats", "-progress", "pipe:1"] + args + [output.path]
        do {
            let result = try await Shell.run(binary, full, onStdoutLine: { line in
                guard let d = duration, d > 0, line.hasPrefix("out_time_us="),
                      let us = Double(line.dropFirst("out_time_us=".count)) else { return }
                ctx.progress(us / 1_000_000 / d)
            })
            guard result.status == 0 else { throw ToolError(summarize(result.stderr)) }
            ctx.progress(1)
        } catch {
            try? FileManager.default.removeItem(at: output)
            throw error
        }
    }

    /// Probes `input`, then runs `before + -i input + args`.
    static func convert(_ input: URL, _ args: [String], to output: URL, _ ctx: JobContext,
                        before: [String] = [], duration: Double? = nil) async throws {
        var length = duration
        if length == nil { length = await probe(input).duration }
        try await run(before + ["-i", input.path] + args, output: output, duration: length, ctx)
    }

    private static func summarize(_ stderr: String) -> String {
        let lines = stderr.split(whereSeparator: \.isNewline).map(String.init).filter { !$0.isEmpty }
        let tail = lines.suffix(3).joined(separator: "\n")
        return tail.isEmpty ? "The conversion failed." : "The conversion failed:\n" + tail
    }
}

// MARK: - Time codes

enum TimeCode {
    /// Accepts "90", "1:30", "01:02:03.5".
    static func parse(_ text: String) -> Double? {
        let parts = text.trimmingCharacters(in: .whitespaces).split(separator: ":").map(String.init)
        guard (1...3).contains(parts.count) else { return nil }
        var total = 0.0
        for part in parts {
            guard let v = Double(part), v >= 0 else { return nil }
            total = total * 60 + v
        }
        return total
    }
}
