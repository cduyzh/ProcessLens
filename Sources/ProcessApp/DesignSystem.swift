import SwiftUI
import AppKit

enum Palette {
    static let accent = Color(light: 0x168575, dark: 0x62CCB5)
    static let background = Color(light: 0xFAFBFC, dark: 0x191C20)
    static let sidebar = Color(light: 0xF1F4F5, dark: 0x15181C)
    static let surface = Color(light: 0xFFFFFF, dark: 0x22262B)
    static let line = Color.primary.opacity(0.075)
    static let orange = Color(light: 0xC27834, dark: 0xEAB16D)
    static let purple = Color(light: 0x8170C6, dark: 0xB5A0F2)
    static let blue = Color(light: 0x548BC4, dark: 0x89B7EB)
    static let muted = Color(light: 0x707983, dark: 0x929CA7)
}

extension Color {
    init(hex: UInt32) {
        self.init(.sRGB, red: Double((hex >> 16) & 255) / 255,
                  green: Double((hex >> 8) & 255) / 255, blue: Double(hex & 255) / 255, opacity: 1)
    }
    init(light: UInt32, dark: UInt32) {
        self.init(nsColor: NSColor(name: nil) { appearance in
            let hex = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: Double((hex >> 16) & 255) / 255,
                           green: Double((hex >> 8) & 255) / 255,
                           blue: Double(hex & 255) / 255, alpha: 1)
        })
    }
}

extension View {
    func panel(radius: CGFloat = 12) -> some View {
        background(Palette.surface, in: RoundedRectangle(cornerRadius: radius))
            .overlay(RoundedRectangle(cornerRadius: radius).strokeBorder(Palette.line, lineWidth: 1))
    }
}

struct SymbolBadge: View {
    let symbol: String
    var tint: Color = Palette.accent
    var size: CGFloat = 30
    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.46, weight: .medium))
            .foregroundStyle(tint)
            .frame(width: size, height: size)
            .background(tint.opacity(0.09), in: RoundedRectangle(cornerRadius: size * 0.26))
            .accessibilityHidden(true)
    }
}

struct ToolButton: View {
    let symbol: String
    let label: String
    var selected = false
    let action: () -> Void
    var body: some View {
        Button(action: action) { Image(systemName: symbol).frame(width: 32, height: 32) }
            .buttonStyle(QuietButtonStyle(selected: selected))
            .help(label).accessibilityLabel(label)
    }
}

struct QuietButtonStyle: ButtonStyle {
    var selected = false
    func makeBody(configuration: Configuration) -> some View {
        QuietButtonBody(configuration: configuration, selected: selected)
    }
    private struct QuietButtonBody: View {
        let configuration: ButtonStyle.Configuration
        let selected: Bool
        @State private var hover = false
        @Environment(\.isEnabled) private var enabled
        var body: some View {
            configuration.label
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(selected ? Palette.accent : Color.secondary)
                .background(Color.primary.opacity(configuration.isPressed ? 0.10 : (hover || selected ? 0.05 : 0)), in: RoundedRectangle(cornerRadius: 7))
                .opacity(enabled ? 1 : 0.35)
                .contentShape(Rectangle())
                .onHover { hover = $0 }
        }
    }
}

struct Sparkline: View {
    let values: [Double]
    var tint: Color = Palette.accent
    var ceiling: Double? = nil
    var body: some View {
        Canvas { context, size in
            guard values.count > 1 else { return }
            let maximum = max(ceiling ?? ((values.max() ?? 1) * 1.18), 1)
            let points = values.enumerated().map { index, value in
                CGPoint(x: size.width * CGFloat(index) / CGFloat(values.count - 1),
                        y: size.height - 2 - CGFloat(min(max(value, 0) / maximum, 1)) * (size.height - 5))
            }
            var line = Path()
            line.addLines(points)
            var area = line
            area.addLine(to: CGPoint(x: size.width, y: size.height))
            area.addLine(to: CGPoint(x: 0, y: size.height))
            area.closeSubpath()
            context.fill(area, with: .linearGradient(Gradient(colors: [tint.opacity(0.2), tint.opacity(0.01)]), startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)))
            context.stroke(line, with: .color(tint), style: StrokeStyle(lineWidth: 1.65, lineCap: .round, lineJoin: .round))
        }
        .accessibilityHidden(true)
    }
}

struct StatusDot: View {
    var color: Color = Palette.accent
    var body: some View { Circle().fill(color).frame(width: 6, height: 6).accessibilityHidden(true) }
}

struct EmptyState: View {
    let symbol: String
    let title: String
    let message: String
    var body: some View {
        VStack(spacing: 12) {
            SymbolBadge(symbol: symbol, size: 48)
            Text(title).font(.system(size: 15, weight: .semibold))
            Text(message).font(.system(size: 12)).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }.padding(32).frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

enum Format {
    static func bytes(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(clamping: bytes), countStyle: .memory)
    }
    static func rate(_ value: Double) -> String { bytes(UInt64(max(0, value))) + "/s" }
    static func percent(_ value: Double) -> String { String(format: "%.1f", value) + "%" }
}
