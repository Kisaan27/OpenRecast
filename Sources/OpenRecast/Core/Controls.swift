import AppKit
import SwiftUI

/// A labelled row in a tool's options.
struct OptionRow<Content: View>: View {
    let label: String
    @ViewBuilder var content: Content

    init(_ label: String, @ViewBuilder content: () -> Content) {
        self.label = label
        self.content = content()
    }

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            Text(label)
                .font(.system(size: 12.5))
                .foregroundStyle(Theme.muted)
                .frame(width: 104, alignment: .leading)
            content
            Spacer(minLength: 0)
        }
        .frame(minHeight: 30)
    }
}

/// A compact pill picker.
struct Chips<Value: Hashable>: View {
    @Binding var selection: Value
    let options: [(Value, String)]
    /// Marked with a small dot as the best choice for the dropped files.
    var recommended: Value? = nil

    var body: some View {
        HStack(spacing: 4) {
            ForEach(options.indices, id: \.self) { i in
                let value = options[i].0
                let selected = value == selection
                Button { selection = value } label: {
                    HStack(spacing: 5) {
                        Text(options[i].1)
                        if value == recommended {
                            Circle().fill(Theme.accent).frame(width: 5, height: 5)
                        }
                    }
                        .font(.system(size: 12, weight: .medium))
                        .padding(.horizontal, 11)
                        .padding(.vertical, 5)
                        .foregroundStyle(selected ? Theme.bg : Theme.ink.opacity(0.85))
                        .background(Capsule().fill(selected ? Theme.ink.opacity(0.92) : Theme.ink.opacity(0.06)))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .help(value == recommended ? "Recommended for this file" : "")
            }
        }
        .animation(.easeOut(duration: 0.15), value: selection)
    }
}

struct SliderRow: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    var step: Double? = nil
    var format: (Double) -> String = { "\(Int($0.rounded()))" }

    var body: some View {
        HStack(spacing: 10) {
            Group {
                if let step {
                    Slider(value: $value, in: range, step: step)
                } else {
                    Slider(value: $value, in: range)
                }
            }
            .controlSize(.small)
            .frame(width: 210)
            Text(format(value))
                .font(.system(size: 12, weight: .medium).monospacedDigit())
                .foregroundStyle(Theme.ink.opacity(0.8))
                .frame(width: 58, alignment: .leading)
        }
    }
}

extension Color {
    /// sRGB components 0...255.
    var rgb255: (r: Double, g: Double, b: Double) {
        let c = NSColor(self).usingColorSpace(.sRGB) ?? .white
        return (Double(c.redComponent) * 255, Double(c.greenComponent) * 255, Double(c.blueComponent) * 255)
    }
}
