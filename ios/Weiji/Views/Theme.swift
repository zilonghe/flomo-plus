import SwiftUI
import UIKit

enum Theme {
    static let green = Color(red: 16 / 255, green: 185 / 255, blue: 129 / 255)
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
    func noteCard() -> some View {
        padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.paper, in: .rect(cornerRadius: 14))
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
