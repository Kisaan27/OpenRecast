# OpenRecast

**A private file studio for macOS.** Convert, compress and clean up video, audio, images, PDFs, documents and archives, right on your Mac. No uploads, no accounts, no limits.

- **Private:** your files never leave your computer. There's no network code anywhere in the app.
- **Free and unlimited:** no file-size caps, no daily quotas, no watermarks.
- **Light:** about 25 MB of memory while idle and a 32 MB download. Heavy work runs in a separate engine process that exits when the job is done.
- **Native:** built with SwiftUI for macOS 14 Sonoma and later, optimised for Apple Silicon (hardware video encoding).

## Download

Grab the latest `OpenRecast-x.y.z.dmg` from [Releases](../../releases), open it, and drag **OpenRecast** into **Applications**.

> First launch: OpenRecast isn't notarized by Apple yet, so macOS will block it the first time.
> Open **System Settings → Privacy & Security**, scroll down, and click **Open Anyway**. You only need to do this once.

## What it does

| Folder | Tools |
|---|---|
| 🎬 **Video** | Convert (MP4, MOV, MKV, WebM, AVI, GIF) · Compress · Trim on a visual timeline with playback · Change container without re-encoding · Video to GIF · Extract audio |
| 🎵 **Audio** | Convert (MP3, M4A, WAV, FLAC, AIFF, OGG, Opus) · Trim on a waveform with playback · Normalize loudness · Audio + image → MP4 |
| 🖼 **Image** | Convert (JPG, PNG, HEIC, WebP, AVIF, TIFF, GIF, BMP, ICO) · Resize · Compress · Remove location and camera metadata |
| ✂️ **Background** | Remove backgrounds with on-device AI (Apple Vision) or by colour, with a live before/after preview · Signature cleanup · Green screen photo · Green screen video (ProRes 4444 / WebM with alpha) |
| 📕 **PDF** | Merge · Split · Compress · Rotate · Add or remove password · Images → PDF (no recompression) · PDF → images |
| 📄 **Documents** | Edit documents (formatting, find & replace, automatic tidy-ups) · DOCX, DOC, ODT, RTF, HTML and TXT to each other · Print to PDF |
| 📦 **Archive** | Create ZIP, 7Z, TAR.GZ, TAR.XZ · Extract ZIP, 7Z, RAR, TAR, GZ, BZ2, XZ, ISO |
| 🛡 **Security** | SHA-256 / SHA-512 / SHA-1 / MD5 checksums (streamed, works on huge files) · Verify a download against a published hash |

Hover a folder on the home screen to see what's inside. Drop any file onto the window and OpenRecast suggests what it can become, or drop it straight onto a folder.

## Build from source

Requires Xcode 15+ (Swift 5.10+) on an Apple Silicon Mac.

```bash
git clone <this repo> && cd OpenRecast
./build_app.sh          # → dist/OpenRecast.app and dist/OpenRecast-0.1.0.dmg
```

`build_app.sh` downloads a pinned ffmpeg build, checks its SHA-256, compiles the app, bundles everything into `OpenRecast.app`, signs it ad-hoc and packages a drag-to-install DMG. Set `VERSION=1.2.3` to change the version number.

For development:

```bash
./scripts/fetch_binaries.sh   # once, to get ffmpeg into Resources/bin
swift run                     # or: open Package.swift in Xcode
```

## Adding a tool

Every feature is a single class that conforms to `FileTool`:

```swift
@Observable
final class MyTool: FileTool {
    var quality = 0.8
    var options: AnyView? { AnyView(Options(tool: self)) }   // optional

    func run(_ inputs: [URL], _ ctx: JobContext) async throws -> JobOutput {
        // write files into ctx.folder(for: input), report ctx.progress(0...1)
    }
}
```

Then add one `ToolInfo(...)` entry to its folder's list (for example `Toolbox.image` in `Sources/OpenRecast/Tools/ImageTools.swift`). It shows up in the folder, on hover, and in the drop suggestions automatically. To add a whole new folder, add a case to `Category` in `Core/Tool.swift`.

## Project layout

```
Sources/OpenRecast/
  App/      window, home dial, folder view, tool panel, theme
  Core/     tool protocol, process runner, ffmpeg wrapper, image helpers, controls
  Tools/    one file per folder: Video, Audio, Image, Background, PDF, Documents, Archive, Security
scripts/    fetch_binaries.sh (pinned + verified ffmpeg), make_icon.swift
build_app.sh  one-click .app + .dmg
docs/       landing page (GitHub Pages)
```

## Engines

| Engine | Used for | Source |
|---|---|---|
| ffmpeg 9.0.2 (bundled) | video, audio, WebP/AVIF, green screen video | [ffmpeg.martin-riedl.de](https://ffmpeg.martin-riedl.de), pinned and SHA-256 verified |
| PDFKit / Core Graphics | PDF tools | built into macOS |
| ImageIO | image formats and metadata | built into macOS |
| CryptoKit | checksums | built into macOS |
| textutil, NSAttributedString | document conversion | built into macOS |
| bsdtar (libarchive) | archives | built into macOS |

## Roadmap

- Full-fidelity Office conversion (XLSX, PPTX) as an optional add-on
- On-device image upscaler and subject cutout
- OCR (searchable PDFs)
- Intel build and Apple notarization

## License

OpenRecast's source code is MIT licensed (see [LICENSE](LICENSE)). The bundled ffmpeg binary is a separate program distributed under the GPL; its source is available from [ffmpeg.org](https://ffmpeg.org).
