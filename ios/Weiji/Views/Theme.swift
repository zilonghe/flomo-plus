import SwiftUI
import UIKit

enum Theme {
    static let green = Color(red: 16 / 255, green: 185 / 255, blue: 129 / 255)
    static let deepGreen = Color(red: 0.02, green: 0.36, blue: 0.27)
    static let active = adaptive(light: 0x047857, dark: 0x6EE7B7)
    static let canvas = adaptive(light: 0xFAFAFA, dark: 0x171717)
    static let paper = adaptive(light: 0xFFFFFF, dark: 0x262626)
    static let ink = adaptive(light: 0x262626, dark: 0xFAFAFA)
    static let line = adaptive(light: 0xE5E5E5, dark: 0x404040)

    private static func adaptive(light: Int, dark: Int) -> Color {
        Color(uiColor: UIColor { traits in
            let hex = traits.userInterfaceStyle == .dark ? dark : light
            return UIColor(red: CGFloat((hex >> 16) & 255) / 255, green: CGFloat((hex >> 8) & 255) / 255,
                           blue: CGFloat(hex & 255) / 255, alpha: 1)
        })
    }
}

extension View {
    func weijiGlassCard(cornerRadius: CGFloat = 16) -> some View {
        weijiGlassSurface(in: RoundedRectangle(cornerRadius: cornerRadius))
    }

    @ViewBuilder
    func weijiGlassSurface<S: Shape>(in shape: S) -> some View {
        if #available(iOS 26.0, *) {
            glassEffect(.regular, in: shape)
        } else {
            background(.ultraThinMaterial, in: shape)
                .overlay { shape.stroke(Theme.line.opacity(0.75)).allowsHitTesting(false) }
        }
    }

    @ViewBuilder
    func weijiGlassCapsule(interactive: Bool = true) -> some View {
        if #available(iOS 26.0, *) {
            glassEffect(interactive ? .regular.interactive() : .regular, in: .capsule)
        } else {
            background(.ultraThinMaterial, in: .capsule)
                .shadow(color: .black.opacity(0.10), radius: 8, y: 3)
        }
    }

    @ViewBuilder
    func weijiGlassCircle(tint: Color? = nil, interactive: Bool = true) -> some View {
        if #available(iOS 26.0, *) {
            let glass = tint.map { Glass.regular.tint($0) } ?? .regular
            glassEffect(interactive ? glass.interactive() : glass, in: .circle)
        } else {
            background {
                Circle().fill(.ultraThinMaterial)
                    .overlay { Circle().fill(tint?.opacity(0.28) ?? .clear) }
            }
            .shadow(color: .black.opacity(0.12), radius: 8, y: 3)
        }
    }

    func noteCard() -> some View {
        padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.paper.opacity(0.94), in: .rect(cornerRadius: 14))
            .overlay { RoundedRectangle(cornerRadius: 14).strokeBorder(Theme.line, lineWidth: 1).allowsHitTesting(false) }
            .contentShape(Rectangle())
    }

    func screenHeader() -> some View {
        padding(.horizontal, 16).frame(height: 52)
    }
}

struct IconAction: View {
    let symbol: String
    let label: String
    let id: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 19, weight: .medium)).frame(width: 44, height: 44)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityIdentifier(id)
    }
}

struct InlineError: View {
    let message: String?
    var body: some View {
        if let message { Text(message).font(.footnote).foregroundStyle(.red).frame(maxWidth: .infinity, alignment: .leading) }
    }
}
