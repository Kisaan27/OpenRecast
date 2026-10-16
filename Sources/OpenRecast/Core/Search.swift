import Foundation

/// Finds tools from a few loose words: names, summaries, file formats and everyday synonyms all count,
/// and small typos are forgiven, so "shrink vid", "mp3 from movie" or "remvoe backround" all land.
enum ToolSearch {
    /// Extra words people use for each tool, beyond its name and summary.
    static let keywords: [String: [String]] = [
        "video-convert": ["change format", "transcode", "export", "movie", "clip", "film", "footage", "mp4", "mov", "mkv", "webm", "avi", "m4v", "quicktime"],
        "video-compress": ["shrink", "smaller", "reduce size", "file size", "squash", "email", "discord", "whatsapp", "upload", "lighter", "hevc", "h265", "movie", "clip"],
        "video-trim": ["cut", "clip", "shorten", "crop length", "split", "snip", "start end", "section", "part", "movie", "footage"],
        "video-remux": ["container", "rewrap", "remux", "mov to mp4", "mkv to mp4", "lossless", "no re-encode", "fast"],
        "video-gif": ["gif", "animated", "animation", "meme", "loop", "reaction"],
        "video-audio": ["movie", "film", "clip", "soundtrack", "sound", "music", "mp3", "rip audio", "voice", "podcast", "strip audio", "audio from video"],
        "audio-convert": ["change format", "mp3", "m4a", "wav", "flac", "aiff", "ogg", "opus", "aac", "music", "song", "sound", "recording"],
        "audio-trim": ["cut", "shorten", "clip", "ringtone", "snip", "section", "song", "recording", "voice memo", "podcast"],
        "audio-normalize": ["loudness", "louder", "quieter", "volume", "level", "gain", "lufs", "even out", "boost", "podcast"],
        "audio-to-video": ["youtube", "instagram", "waveform", "cover art", "album art", "visualizer", "music video", "mp4"],
        "image-convert": ["change format", "jpg", "jpeg", "png", "heic", "webp", "avif", "tiff", "gif", "bmp", "ico", "icon", "photo", "picture", "screenshot"],
        "image-resize": ["scale", "smaller", "bigger", "dimensions", "pixels", "width", "height", "thumbnail", "downscale", "photo", "picture"],
        "image-compress": ["shrink", "smaller", "reduce size", "file size", "optimise", "optimize", "web", "email", "photo", "picture", "jpg"],
        "image-strip": ["exif", "gps", "location", "privacy", "metadata", "camera info", "anonymise", "anonymize", "scrub", "clean"],
        "bg-solid": ["background", "cutout", "cut out", "transparent", "remove bg", "erase background", "subject", "isolate", "product photo", "portrait", "logo", "png", "ai"],
        "bg-signature": ["signature", "sign", "stamp", "ink", "handwriting", "scan", "transparent", "autograph"],
        "bg-chroma": ["green screen", "chroma key", "blue screen", "key", "transparent", "backdrop", "photo"],
        "bg-chroma-video": ["green screen", "chroma key", "blue screen", "key", "transparent", "backdrop", "prores", "alpha", "footage"],
        "pdf-merge": ["combine", "join", "append", "together", "one file", "stitch", "pages"],
        "pdf-split": ["separate", "extract pages", "break up", "pages", "ranges", "divide"],
        "pdf-compress": ["shrink", "smaller", "reduce size", "file size", "email", "optimise", "optimize"],
        "pdf-rotate": ["turn", "sideways", "upside down", "orientation", "landscape", "portrait", "flip"],
        "pdf-password": ["lock", "unlock", "protect", "encrypt", "decrypt", "secure", "remove password"],
        "images-to-pdf": ["scan", "photos to pdf", "jpg to pdf", "png to pdf", "combine images", "picture", "document"],
        "pdf-to-images": ["pdf to jpg", "pdf to png", "export pages", "pictures", "screenshot", "image"],
        "doc-edit": ["edit", "editor", "write", "fix", "change text", "typo", "proofread", "find replace", "word", "docx", "rtf", "text", "tidy", "clean up", "format"],
        "doc-convert": ["word", "docx", "doc", "odt", "rtf", "html", "txt", "markdown", "text", "change format", "pages", "libreoffice", "openoffice"],
        "doc-pdf": ["print", "save as pdf", "word to pdf", "docx to pdf", "export pdf", "paginate"],
        "archive-create": ["zip", "7z", "tar", "gz", "bundle", "pack", "folder", "compress files", "archive"],
        "archive-extract": ["unzip", "unpack", "open zip", "rar", "7z", "tar", "decompress", "iso", "unarchive"],
        "checksum": ["hash", "sha256", "sha-256", "md5", "sha1", "fingerprint", "integrity", "digest"],
        "verify": ["check download", "hash", "checksum", "tampered", "integrity", "sha256", "md5", "compare"],
    ]

    /// Words that carry no meaning for picking a tool.
    private static let stopwords: Set<String> = [
        "a", "an", "the", "to", "into", "in", "of", "for", "from", "and", "or", "my", "me", "i", "it", "this", "that",
        "want", "need", "how", "do", "can", "please", "file", "files", "with", "on", "as", "some", "make",
    ]

    private struct Entry {
        let tool: ToolInfo
        let order: Int
        let name: String
        let terms: [(word: String, weight: Double)]
    }

    private static let index: [Entry] = Toolbox.all.enumerated().map { order, tool in
        var terms: [(String, Double)] = []
        func add(_ text: String, _ weight: Double) {
            for w in words(text) where !terms.contains(where: { $0.0 == w && $0.1 >= weight }) { terms.append((w, weight)) }
        }
        add(tool.name, 3)
        add(tool.category.title, 2)
        for k in keywords[tool.id] ?? [] { add(k, 2) }
        for e in tool.extensions { add(e, 1.5) }
        add(tool.summary, 1)
        return Entry(tool: tool, order: order, name: tool.name.lowercased(), terms: terms)
    }

    static func words(_ text: String) -> [String] {
        text.lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
    }

    /// Best matches first. Empty for an empty query.
    static func search(_ query: String, limit: Int = 8) -> [ToolInfo] {
        let all = words(query)
        let tokens = all.filter { !stopwords.contains($0) }
        let useful = tokens.isEmpty ? all : tokens
        guard !useful.isEmpty else { return [] }
        let phrase = query.lowercased().trimmingCharacters(in: .whitespaces)

        let scored: [(Entry, Double)] = index.compactMap { entry in
            var total = 0.0, matched = 0
            for token in useful {
                let best = entry.terms.reduce(0.0) { max($0, $1.weight * match(token, $1.word)) }
                if best > 0 { matched += 1; total += best }
            }
            guard matched > 0 else { return nil }
            // Every word should count: tools that explain only part of the query sink.
            var score = total * Double(matched) / Double(useful.count)
            if matched < useful.count && useful.count > 1 && matched * 2 < useful.count { return nil }
            if entry.name == phrase { score += 6 } else if entry.name.hasPrefix(phrase) { score += 3 }
            return (entry, score)
        }
        return scored
            .sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0.order < $1.0.order }
            .prefix(limit)
            .map(\.0.tool)
    }

    /// How well a typed word matches an indexed word, 0...1.
    private static func match(_ token: String, _ word: String) -> Double {
        if token == word { return 1 }
        if word.hasPrefix(token) { return token.count >= 2 ? 0.85 : 0.4 }
        if token.count >= 4 && word.hasPrefix(String(token.dropLast())) && word.count > token.count { return 0.7 }
        if token.count >= 3 && word.count >= 4 && word.contains(token) { return 0.5 }
        // Allow one typo per five letters; shorter words are too often other real words ("heic" vs "hevc").
        if token.count >= 5 && abs(token.count - word.count) <= 2 {
            let limit = token.count / 5
            if distance(token, word, limit: limit) <= limit { return 0.65 }
        }
        // Typos inside a partly typed word: "backr" for "background".
        if token.count >= 5 && word.count > token.count {
            let head = String(word.prefix(token.count))
            if distance(token, head, limit: 1) <= 1 { return 0.55 }
        }
        return 0
    }

    /// Edit distance where a swapped pair of letters counts as one typo, giving up once it passes `limit`.
    private static func distance(_ a: String, _ b: String, limit: Int) -> Int {
        let a = Array(a), b = Array(b)
        guard !a.isEmpty, !b.isEmpty else { return max(a.count, b.count) }
        var before = [Int](), prev = Array(0...b.count)
        for i in 1...a.count {
            var cur = [i] + Array(repeating: 0, count: b.count)
            var rowMin = i
            for j in 1...b.count {
                cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
                if i > 1, j > 1, a[i - 1] == b[j - 2], a[i - 2] == b[j - 1] {
                    cur[j] = min(cur[j], before[j - 2] + 1)
                }
                rowMin = min(rowMin, cur[j])
            }
            if rowMin > limit { return limit + 1 }
            before = prev
            prev = cur
        }
        return prev[b.count]
    }
}
