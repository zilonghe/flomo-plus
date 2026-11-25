import Observation
import SwiftUI
import UIKit

enum ThemeAccent: String, CaseIterable, Identifiable, Sendable {
    case pine, indigo, clay, plum, graphite
    var id: String { rawValue }

    var label: String {
        switch self {
        case .pine: "松针"
        case .indigo: "靛青"
        case .clay: "陶土"
        case .plum: "暮紫"
        case .graphite: "石墨"
        }
    }

    /// Text, icons, and links (WCAG AA >= 4.5:1 on canvas, paper, and accentSoft).
    var active: Color {
        switch self {
        case .pine: Theme.adaptive(light: 0x2D6A4F, dark: 0x7AD4AA)
        case .indigo: Theme.adaptive(light: 0x2553A6, dark: 0x85B0FF)
        case .clay: Theme.adaptive(light: 0x9E4B28, dark: 0xF0A07B)
        case .plum: Theme.adaptive(light: 0x6A4A96, dark: 0xC7ADF2)
        case .graphite: Theme.adaptive(light: 0x363430, dark: 0xDCD9D0)
        }
    }

    /// Solid primary CTA fill behind pure white text/icons (WCAG AA >= 4.5:1 in light & dark).
    var accent: Color {
        switch self {
        case .pine: Theme.adaptive(light: 0x2D6A4F, dark: 0x276E50)
        case .indigo: Theme.adaptive(light: 0x2553A6, dark: 0x2F62BF)
        case .clay: Theme.adaptive(light: 0x9E4B28, dark: 0xA6502C)
        case .plum: Theme.adaptive(light: 0x6A4A96, dark: 0x7755A8)
        case .graphite: Theme.adaptive(light: 0x363430, dark: 0x57544D)
        }
    }

    var accentSoft: Color {
        switch self {
        case .pine: Theme.adaptive(light: 0xE7F1EC, dark: 0x1C3127)
        case .indigo: Theme.adaptive(light: 0xE9EFFB, dark: 0x1A2844)
        case .clay: Theme.adaptive(light: 0xF6EAE4, dark: 0x352119)
        case .plum: Theme.adaptive(light: 0xEFEAF7, dark: 0x292038)
        case .graphite: Theme.adaptive(light: 0xEAE8E1, dark: 0x2E2D29)
        }
    }

    /// Mid-tone accent used for activity heatmap cells and quote edge bars.
    var tone: Color {
        switch self {
        case .pine: Theme.adaptive(light: 0x3A8363, dark: 0x5CC295)
        case .indigo: Theme.adaptive(light: 0x3669C4, dark: 0x6E9EF5)
        case .clay: Theme.adaptive(light: 0xBA5F38, dark: 0xE08A64)
        case .plum: Theme.adaptive(light: 0x7F5CAE, dark: 0xB394E6)
        case .graphite: Theme.adaptive(light: 0x52504A, dark: 0xB5B1A6)
        }
    }
}

@Observable
final class ThemeManager {
    static let storageKey = "weiji.accent"
    static let shared = ThemeManager()

    @ObservationIgnored private let defaults: UserDefaults

    var accent: ThemeAccent {
        didSet {
            guard accent != oldValue else { return }
            defaults.set(accent.rawValue, forKey: Self.storageKey)
        }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        accent = defaults.string(forKey: Self.storageKey).flatMap(ThemeAccent.init(rawValue:)) ?? .pine
    }
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

    static var active: Color { ThemeManager.shared.accent.active }
    static var accent: Color { ThemeManager.shared.accent.accent }
    static var accentSoft: Color { ThemeManager.shared.accent.accentSoft }
    static var green: Color { ThemeManager.shared.accent.tone }

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

    static func adaptive(light: Int, dark: Int) -> Color {
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
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 18)
            .frame(maxWidth: wide ? .infinity : nil, minHeight: wide ? 48 : 36)
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
            .font(.system(size: 15, weight: .medium))
            .foregroundStyle(Theme.ink.opacity(isEnabled ? 1 : 0.35))
            .padding(.horizontal, 16)
            .frame(maxWidth: wide ? .infinity : nil, minHeight: wide ? 48 : 36)
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
            if let symbol { Image(systemName: symbol).font(.system(size: 11, weight: .semibold)).accessibilityHidden(true) }
            Text(text).lineLimit(1)
        }
        .font(Theme.TypeScale.meta.weight(.medium))
        .foregroundStyle(selected ? Theme.active : Theme.ink2)
        .padding(.horizontal, 10).frame(minHeight: 30)
        .background(selected ? Theme.accentSoft : Theme.subtle, in: Capsule())
    }
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
            Image(systemName: symbol).font(.system(size: 18, weight: .medium)).frame(width: 44, height: 44)
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
        if let message { Text(message).font(Theme.TypeScale.meta).foregroundStyle(.red).frame(maxWidth: .infinity, alignment: .leading) }
    }
}
