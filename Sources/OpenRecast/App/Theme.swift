import AppKit
import SwiftUI

extension NSColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                  green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255,
                  alpha: alpha)
    }
}

extension Color {
    init(hex: UInt32) { self.init(nsColor: NSColor(hex: hex)) }

    static func adaptive(_ light: UInt32, _ dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(hex: dark) : NSColor(hex: light)
        })
    }
}

enum Theme {
    static let bg = Color.adaptive(0xEEEAE3, 0x121110)
    static let panel = Color.adaptive(0xE5E0D6, 0x1A1917)
    static let disc = Color.adaptive(0xE3DDD2, 0x1C1A18)
    static let ink = Color.adaptive(0x1D1B18, 0xEDE8E0)
    static let muted = Color.adaptive(0x6F685E, 0x8E877C)
    static let accent = Color.adaptive(0xC8643B, 0xE58A5C)
    static let good = Color.adaptive(0x3F8F5A, 0x7FC492)
    static let bad = Color.adaptive(0xB8433A, 0xE6766B)
    static var line: Color { ink.opacity(0.09) }
}

// MARK: - Grain

/// A tiled film-grain overlay. The tile is generated once and shared.
struct Grain: View {
    var opacity: Double = 0.07

    private static let tile: CGImage = {
        let n = 128
        var bytes = [UInt8](repeating: 0, count: n * n)
        for i in bytes.indices { bytes[i] = UInt8.random(in: 0...255) }
        return bytes.withUnsafeMutableBytes { raw in
            CGContext(data: raw.baseAddress, width: n, height: n, bitsPerComponent: 8, bytesPerRow: n,
                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
                .makeImage()!
        }
    }()

    var body: some View {
        Image(decorative: Self.tile, scale: 2)
            .resizable(resizingMode: .tile)
            .opacity(opacity)
            .allowsHitTesting(false)
    }
}

struct Backdrop: View {
    var body: some View {
        ZStack {
            Theme.bg
            RadialGradient(colors: [Theme.accent.opacity(0.10), .clear],
                           center: UnitPoint(x: 0.92, y: 0.5), startRadius: 20, endRadius: 560)
            RadialGradient(colors: [Theme.ink.opacity(0.035), .clear],
                           center: .topLeading, startRadius: 0, endRadius: 640)
            Grain()
        }
        .ignoresSafeArea()
    }
}

// MARK: - Folder icon

private struct FolderBackShape: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        let c = CGSize(width: r.width * 0.08, height: r.width * 0.08)
        p.addRoundedRect(in: CGRect(x: r.minX, y: r.minY, width: r.width * 0.44, height: r.height * 0.4), cornerSize: c)
        p.addRoundedRect(in: CGRect(x: r.minX, y: r.minY + r.height * 0.13, width: r.width, height: r.height * 0.87), cornerSize: c)
        return p
    }
}

private struct FolderFrontShape: Shape {
    func path(in r: CGRect) -> Path {
        Path(roundedRect: CGRect(x: r.minX, y: r.minY + r.height * 0.3, width: r.width, height: r.height * 0.7),
             cornerSize: CGSize(width: r.width * 0.08, height: r.width * 0.08))
    }
}

struct FolderIcon: View {
    let category: Category
    var open = false
    var size: CGFloat = 64

    var body: some View {
        let w = size, h = size * 0.82
        ZStack {
            FolderBackShape()
                .fill(LinearGradient(colors: [category.deep, category.deep.opacity(0.85)], startPoint: .top, endPoint: .bottom))
            RoundedRectangle(cornerRadius: w * 0.05)
                .fill(Color(hex: 0xF6F1E8))
                .overlay(alignment: .top) {
                    VStack(alignment: .leading, spacing: h * 0.06) {
                        ForEach(0..<3, id: \.self) { i in
                            Capsule().fill(Color.black.opacity(0.12)).frame(width: w * (i == 2 ? 0.34 : 0.54), height: max(1, h * 0.03))
                        }
                    }
                    .padding(.top, h * 0.09)
                }
                .frame(width: w * 0.76, height: h * 0.6)
                .offset(y: open ? -h * 0.2 : -h * 0.08)
                .shadow(color: .black.opacity(0.18), radius: 1, y: 0.5)
            FolderFrontShape()
                .fill(LinearGradient(colors: [category.light, category.tint], startPoint: .top, endPoint: .bottom))
                .overlay(Grain(opacity: 0.16).clipShape(FolderFrontShape()))
                .overlay(FolderFrontShape().stroke(Color.white.opacity(0.22), lineWidth: 0.7))
                .overlay {
                    Image(systemName: category.symbol)
                        .font(.system(size: w * 0.22, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.93))
                        .shadow(color: .black.opacity(0.15), radius: 1, y: 1)
                        .offset(y: h * 0.15)
                }
                .rotation3DEffect(.degrees(open ? -26 : 0), axis: (x: 1, y: 0, z: 0), anchor: .bottom, perspective: 0.5)
        }
        .frame(width: w, height: h)
        .shadow(color: .black.opacity(open ? 0.32 : 0.22), radius: open ? 14 : 5, y: open ? 9 : 3)
    }
}

// MARK: - Small pieces

extension View {
    func eyebrow() -> some View {
        font(.system(size: 10.5, weight: .semibold)).tracking(1.8).foregroundStyle(Theme.muted)
    }

    func fieldStyle(width: CGFloat = 220) -> some View {
        textFieldStyle(.plain)
            .font(.system(size: 12.5))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 8).fill(Theme.ink.opacity(0.06)))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.line))
            .frame(width: width)
    }
}

struct Badge: View {
    let symbol: String
    let text: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: symbol).font(.system(size: 9.5, weight: .bold))
            Text(text).font(.system(size: 11.5, weight: .medium))
        }
        .foregroundStyle(Theme.ink.opacity(0.75))
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Capsule().fill(Theme.ink.opacity(0.05)))
        .overlay(Capsule().stroke(Theme.line))
    }
}

struct PrimaryButtonStyle: ButtonStyle {
    var tint: Color

    func makeBody(configuration: Configuration) -> some View {
        PrimaryLabel(configuration: configuration, tint: tint)
    }

    private struct PrimaryLabel: View {
        let configuration: ButtonStyleConfiguration
        let tint: Color
        @Environment(\.isEnabled) private var enabled

        var body: some View {
            configuration.label
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 20)
                .padding(.vertical, 9)
                .background(Capsule().fill(tint))
                .overlay(Capsule().stroke(.white.opacity(0.2), lineWidth: 0.6))
                .opacity(enabled ? (configuration.isPressed ? 0.8 : 1) : 0.38)
                .scaleEffect(configuration.isPressed ? 0.97 : 1)
                .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
        }
    }
}

struct QuietButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(Theme.ink.opacity(configuration.isPressed ? 0.5 : 0.8))
            .padding(.horizontal, 11)
            .padding(.vertical, 5)
            .background(Capsule().fill(Theme.ink.opacity(0.06)))
            .contentShape(Capsule())
    }
}
