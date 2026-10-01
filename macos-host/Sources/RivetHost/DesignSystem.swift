import SwiftUI
import AppKit

// The regexmate.design tokens from docs/styles.css, ported to SwiftUI:
// "Neutrals first, one accent, generous whitespace, hairline structure."
enum RM {
    static let radiusL: CGFloat = 22
    static let radiusM: CGFloat = 16
    static let radiusS: CGFloat = 10

    enum Color_ {
        static let bg = Color(light: 0xFAFAF8, dark: 0x0A0A0B)
        static let bgSoft = Color(light: 0xF3F3F0, dark: 0x121214)
        static let surface = Color(light: 0xFFFFFF, dark: 0x17171A)
        static let ink = Color(light: 0x1D1D1F, dark: 0xF5F5F7)
        static let ink2 = Color(light: 0x55555A, dark: 0xA1A1A6)
        static let ink3 = Color(light: 0x86868B, dark: 0x6E6E73)
        static let hairline = Color(light: 0x000000, dark: 0xFFFFFF, lightAlpha: 0.10, darkAlpha: 0.12)
        static let accent = Color(light: 0x037A55, dark: 0x3ECF8E)
        static let accentTint = Color(light: 0x037A55, dark: 0x3ECF8E, lightAlpha: 0.10, darkAlpha: 0.12)
        // diagram canvas stays white in both themes (brand rule from the homepage)
        static let canvas = Color.white
        static let danger = Color(light: 0xD92D20, dark: 0xFF6369)
        static let warning = Color(light: 0xB54708, dark: 0xFFB35C)
        static let ok = Color(light: 0x037A55, dark: 0x3ECF8E)
    }
}

extension Color {
    init(light: UInt32, dark: UInt32, lightAlpha: Double = 1, darkAlpha: Double = 1) {
        func rgba(_ hex: UInt32, _ alpha: Double) -> NSColor {
            NSColor(srgbRed: Double((hex >> 16) & 0xFF) / 255,
                    green: Double((hex >> 8) & 0xFF) / 255,
                    blue: Double(hex & 0xFF) / 255,
                    alpha: alpha)
        }
        self.init(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return isDark ? rgba(dark, darkAlpha) : rgba(light, lightAlpha)
        })
    }
}

// Rounded card with a hairline border — the structural unit of the layout.
struct Card<Content: View>: View {
    var padding: CGFloat = 12
    @ViewBuilder var content: () -> Content

    var body: some View {
        content()
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: RM.radiusS).fill(RM.Color_.surface))
            .overlay(RoundedRectangle(cornerRadius: RM.radiusS).strokeBorder(RM.Color_.hairline))
    }
}

// Section caption with an SF Symbol, e.g. "▸ TEST TEXT".
struct SectionHeader: View {
    let icon: String
    let title: String
    var trailing: String?

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(RM.Color_.ink3)
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .tracking(0.06)
                .foregroundStyle(RM.Color_.ink2)
            if let trailing {
                Text(trailing)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(RM.Color_.ink3)
            }
            Spacer(minLength: 0)
        }
    }
}

// Severity chip for lint findings.
struct SeverityChip: View {
    let severity: String

    private var tint: Color {
        switch severity.lowercased() {
        case "error": return RM.Color_.danger
        case "warning": return RM.Color_.warning
        default: return RM.Color_.accent
        }
    }

    var body: some View {
        Text(severity.uppercased())
            .font(.system(size: 9, weight: .bold, design: .rounded))
            .tracking(0.08)
            .foregroundStyle(tint)
            .padding(.horizontal, 7)
            .padding(.vertical, 2.5)
            .background(Capsule().fill(tint.opacity(0.13)))
    }
}
