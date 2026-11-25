import SwiftUI
import UIKit

enum Theme {
    /// Accent for text, icons and links (brighter in dark mode for contrast on charcoal).
    static let active = adaptive(light: 0x147A5B, dark: 0x5CC8A0)
    /// Solid fill behind white text/icons.
    static let accent = adaptive(light: 0x147A5B, dark: 0x167E5C)
    static let accentSoft = adaptive(light: 0xE2F0E9, dark: 0x1D3229)
    static let green = adaptive(light: 0x1F9D72, dark: 0x3FBF8F)
    static let canvas = adaptive(light: 0xF6F5F0, dark: 0x171614)
    static let paper = adaptive(light: 0xFFFFFF, dark: 0x22211E)
    static let subtle = adaptive(light: 0xEEECE5, dark: 0x2B2A26)
    static let ink = adaptive(light: 0x1C1B18, dark: 0xEDEBE5)
    static let ink2 = adaptive(light: 0x55524A, dark: 0xB5B0A6)
    static let ink3 = adaptive(light: 0x6F6B63, dark: 0x8F8A80)
    static let line = adaptive(light: 0xE6E3DA, dark: 0x3A3833)
    static let hairline = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark ? UIColor(white: 1, alpha: 0.08) : UIColor(white: 0, alpha: 0.06)
    })

    private static func adaptive(light: Int, dark: Int) -> Color {
        Color(uiColor: UIColor { traits in
            let hex = traits.userInterfaceStyle == .dark ? dark : light
            return UIColor(red: CGFloat((hex >> 16) & 255) / 255, green: CGFloat((hex >> 8) & 255) / 255,
                           blue: CGFloat(hex & 255) / 255, alpha: 1)
        })
    }
}

extension View {
    func noteCard(padding: CGFloat = 14, cornerRadius: CGFloat = 16) -> some View {
        self.padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: cornerRadius)
                    .fill(Theme.paper)
                    .shadow(color: .black.opacity(0.04), radius: 10, y: 3)
            }
            .overlay { RoundedRectangle(cornerRadius: cornerRadius).strokeBorder(Theme.hairline).allowsHitTesting(false) }
            .contentShape(Rectangle())
    }

    func screenHeader() -> some View {
        padding(.horizontal, 16).frame(height: 52)
    }

    /// Opaque canvas behind sheets and forms so they match the app instead of system grey.
    func weijiSheetBackground() -> some View {
        scrollContentBackground(.hidden).background(Theme.canvas)
    }
}

struct WeijiPrimaryButtonStyle: ButtonStyle {
    var wide = false
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 18)
            .frame(maxWidth: wide ? .infinity : nil, minHeight: wide ? 50 : 36)
            .background {
                RoundedRectangle(cornerRadius: wide ? 14 : 18)
                    .fill(Theme.accent.opacity(isEnabled ? 1 : 0.35))
                    .shadow(color: Theme.accent.opacity(isEnabled ? 0.22 : 0), radius: 8, y: 3)
            }
            .contentShape(Rectangle())
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .opacity(configuration.isPressed ? 0.88 : 1)
            .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
    }
}

struct WeijiSecondaryButtonStyle: ButtonStyle {
    var wide = false
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.medium))
            .foregroundStyle(Theme.ink.opacity(isEnabled ? 1 : 0.35))
            .padding(.horizontal, 16)
            .frame(maxWidth: wide ? .infinity : nil, minHeight: wide ? 50 : 36)
            .background(Theme.subtle, in: .rect(cornerRadius: wide ? 14 : 18))
            .contentShape(Rectangle())
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}

extension ButtonStyle where Self == WeijiPrimaryButtonStyle {
    static var weijiPrimary: Self { .init() }
    static var weijiPrimaryWide: Self { .init(wide: true) }
}

extension ButtonStyle where Self == WeijiSecondaryButtonStyle {
    static var weijiSecondary: Self { .init() }
}

/// Small rounded chip used for tags, pins and filters.
struct Chip: View {
    let text: String
    var symbol: String? = nil
    var selected = false

    var body: some View {
        HStack(spacing: 4) {
            if let symbol { Image(systemName: symbol).font(.caption2.weight(.semibold)).accessibilityHidden(true) }
            Text(text).lineLimit(1)
        }
        .font(.footnote.weight(.medium))
        .foregroundStyle(selected ? Theme.active : Theme.ink2)
        .padding(.horizontal, 10).frame(minHeight: 30)
        .background(selected ? Theme.accentSoft : Theme.subtle, in: Capsule())
    }
}

struct SectionLabel: View {
    let title: String
    init(_ title: String) { self.title = title }
    var body: some View {
        Text(title).font(.footnote.weight(.semibold)).foregroundStyle(Theme.ink3)
            .padding(.horizontal, 4)
            .accessibilityAddTraits(.isHeader)
    }
}

struct IconAction: View {
    let symbol: String
    let label: String
    let id: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 18, weight: .medium)).frame(width: 44, height: 44)
                .contentShape(Rectangle())
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
