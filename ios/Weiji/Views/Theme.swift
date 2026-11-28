import SwiftUI
import UIKit

enum ThemeAccent: String, CaseIterable, Identifiable, Sendable {
    case pine, indigo, clay, plum, graphite
    var id: String { rawValue }

}

final class ThemeManager {
    static let storageKey = "weiji.accent"
    let accent: ThemeAccent = .pine

    // A legacy preference must never change the paper-and-ink palette.
    init(defaults: UserDefaults = .standard) {}
}

enum Theme {
    /// Strict shared typography scale across all tabs using Dynamic Type semantic styles.
    enum TypeScale {
        static let pageTitle = Font.system(.title2, weight: .bold)
        static let sectionTitle = Font.system(.footnote, weight: .semibold)
        static let itemTitle = Font.system(.headline)
        static let body = Font.system(.subheadline)
        static let meta = Font.system(.footnote)
    }

    static let canvas = adaptive(light: 0xFAF8F4, dark: 0x151514)
    static let paper = adaptive(light: 0xF2EFE8, dark: 0x1F1E1C)
    static let subtle = adaptive(light: 0xEAE6DC, dark: 0x272623)
    static let ink = adaptive(light: 0x1C1B19, dark: 0xE8E5DE, highLight: 0x11100E, highDark: 0xF5F3EE)
    static let ink2 = adaptive(light: 0x4E4B45, dark: 0xB0ACA3, highLight: 0x3A3833, highDark: 0xCFCBC3)
    static let ink3 = ink2
    static let inverseBg = adaptive(light: 0x1C1B19, dark: 0xE8E5DE)
    static let inverseText = canvas
    static let active = adaptive(light: 0x1D4D3A, dark: 0x9AC4AE, highLight: 0x14382A, highDark: 0xB8DEC9)
    static let accent = adaptive(light: 0x1D4D3A, dark: 0x1F5640, highLight: 0x14382A, highDark: 0x174432)
    static let danger = adaptive(light: 0x9A2620, dark: 0xF59C95, highLight: 0x7A1A15, highDark: 0xFFB8B2)
    static let line = hairline
    static let hairline = inkAlpha(light: 0.10, dark: 0.12, highLight: 0.24, highDark: 0.28)
    static let quoteBar = inkAlpha(light: 0.24, dark: 0.28)

    static func heat(level: Int) -> Color {
        let level = min(4, max(0, level))
        return inkAlpha(light: [0.06, 0.20, 0.38, 0.62, 0.88][level],
                        dark: [0.08, 0.22, 0.42, 0.66, 0.90][level])
    }

    private static func inkAlpha(light: CGFloat, dark: CGFloat, highLight: CGFloat? = nil, highDark: CGFloat? = nil) -> Color {
        Color(uiColor: UIColor { traits in
            let isDark = traits.userInterfaceStyle == .dark
            let high = traits.accessibilityContrast == .high
            return isDark
                ? UIColor(red: 232/255, green: 229/255, blue: 222/255, alpha: high ? highDark ?? dark : dark)
                : UIColor(red: 28/255, green: 27/255, blue: 25/255, alpha: high ? highLight ?? light : light)
        })
    }

    static func adaptive(light: Int, dark: Int, highLight: Int? = nil, highDark: Int? = nil) -> Color {
        Color(uiColor: UIColor { traits in
            let isDark = traits.userInterfaceStyle == .dark
            let high = traits.accessibilityContrast == .high
            let hex = isDark ? (high ? highDark ?? dark : dark) : (high ? highLight ?? light : light)
            return UIColor(red: CGFloat((hex >> 16) & 255) / 255, green: CGFloat((hex >> 8) & 255) / 255,
                           blue: CGFloat(hex & 255) / 255, alpha: 1)
        })
    }
}

extension View {
    func minTapHeight() -> some View {
        frame(minHeight: 44).contentShape(Rectangle())
    }

    func minTouchTarget() -> some View {
        frame(minWidth: 44, minHeight: 44).contentShape(Rectangle())
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
            .foregroundStyle(Theme.inverseText)
            .padding(.horizontal, 18)
            .frame(maxWidth: wide ? .infinity : nil, minHeight: wide ? 48 : 44)
            .background {
                RoundedRectangle(cornerRadius: wide ? 14 : 18)
                    .fill(Theme.inverseBg.opacity(isEnabled ? 1 : 0.35))
            }
            .minTouchTarget()
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
            .frame(maxWidth: wide ? .infinity : nil, minHeight: wide ? 48 : 44)
            .background(Theme.subtle, in: .rect(cornerRadius: wide ? 14 : 18))
            .minTouchTarget()
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

struct SectionLabel: View {
    let title: String
    init(_ title: String) { self.title = title }
    var body: some View {
        Text(title).font(Theme.TypeScale.sectionTitle).foregroundStyle(Theme.ink3)
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
            Image(systemName: symbol).font(.body.weight(.medium)).minTouchTarget()
                .foregroundStyle(Theme.ink)
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
        if let message { Text(message).font(Theme.TypeScale.meta).foregroundStyle(Theme.danger).frame(maxWidth: .infinity, alignment: .leading) }
    }
}
