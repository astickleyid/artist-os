import SwiftUI

/// Design tokens mirrored from the web app (docs/styles.css) so the iPhone
/// companion is visually continuous with the landing page and web app:
/// a dark pro-audio console, gold as the single accent, green for resolved.
enum AOS {
    static let ink       = Color(hex: 0x070810)
    static let panel     = Color(hex: 0x11121A)
    static let raised    = Color(hex: 0x171A22)
    static let line      = Color.white.opacity(0.09)
    static let text      = Color(hex: 0xF2F6FC)
    static let muted     = Color(hex: 0x8F96A8)
    static let gold      = Color(hex: 0xD6AE5C)
    static let goldBright = Color(hex: 0xF2D083)
    static let green     = Color(hex: 0x7AD685)
    static let blue      = Color(hex: 0x80A6FF)

    enum Radius { static let card: CGFloat = 16; static let chip: CGFloat = 999; static let tile: CGFloat = 13 }
    enum Space { static let xs: CGFloat = 6; static let sm: CGFloat = 10; static let md: CGFloat = 14; static let lg: CGFloat = 20 }
}

extension Color {
    init(hex: UInt32, alpha: Double = 1) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255,
                  opacity: alpha)
    }
}

/// Shared card container used across the app.
struct Panel<Content: View>: View {
    var accent: Color? = nil
    @ViewBuilder var content: Content
    var body: some View {
        content
            .padding(AOS.Space.md)
            .background(AOS.panel, in: RoundedRectangle(cornerRadius: AOS.Radius.card, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: AOS.Radius.card, style: .continuous)
                    .strokeBorder(accent ?? AOS.line, lineWidth: 1)
            )
    }
}

/// Small uppercase section label ("NEEDS YOU", "JUST HAPPENED").
struct SectionLabel: View {
    let text: String
    var tint: Color = AOS.muted
    var count: Int? = nil
    var body: some View {
        HStack(spacing: 9) {
            Text(text.uppercased())
                .font(.system(size: 12, weight: .black))
                .tracking(1.4)
                .foregroundStyle(tint)
            if let count, count > 0 {
                Text("\(count)")
                    .font(.system(size: 11, weight: .heavy))
                    .foregroundStyle(AOS.muted)
                    .padding(.horizontal, 8).padding(.vertical, 2)
                    .background(Color.white.opacity(0.05), in: Capsule())
            }
            Rectangle().fill(AOS.line).frame(height: 1)
        }
    }
}
