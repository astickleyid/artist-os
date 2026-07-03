import SwiftUI

enum AOSTheme {
    static let background = Color(red: 0.028, green: 0.031, blue: 0.040)
    static let panel = Color(red: 0.065, green: 0.073, blue: 0.095)
    static let panelRaised = Color(red: 0.090, green: 0.102, blue: 0.132)
    static let line = Color.white.opacity(0.09)
    static let text = Color(red: 0.950, green: 0.965, blue: 0.990)
    static let muted = Color(red: 0.560, green: 0.590, blue: 0.660)
    static let gold = Color(red: 0.840, green: 0.680, blue: 0.360)
    static let green = Color(red: 0.480, green: 0.840, blue: 0.520)
    static let blue = Color(red: 0.500, green: 0.650, blue: 1.000)
    static let corner: CGFloat = 18
}

extension View {
    func aosPanel(cornerRadius: CGFloat = AOSTheme.corner) -> some View {
        self
            .background(AOSTheme.panel.opacity(0.86), in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).stroke(AOSTheme.line, lineWidth: 1))
    }

    /// Standard macOS hover affordance: subtle raise + border brighten.
    func aosHoverable(cornerRadius: CGFloat = AOSTheme.corner) -> some View {
        modifier(AOSHoverModifier(cornerRadius: cornerRadius))
    }
}

struct AOSHoverModifier: ViewModifier {
    let cornerRadius: CGFloat
    @State private var isHovered = false

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(Color.white.opacity(isHovered ? 0.045 : 0))
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(Color.white.opacity(isHovered ? 0.16 : 0), lineWidth: 1)
            )
            .animation(.easeOut(duration: 0.12), value: isHovered)
            .onHover { hovering in
                isHovered = hovering
            }
    }
}

/// Shared relative timestamp ("2 hr ago") — the Linear/GitHub convention that
/// reads faster than absolute times in activity feeds.
enum AOSTime {
    static let relative: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter
    }()

    static func ago(_ date: Date) -> String {
        if Date().timeIntervalSince(date) < 60 { return "now" }
        return relative.localizedString(for: date, relativeTo: Date())
    }
}
