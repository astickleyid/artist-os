import SwiftUI

struct AOSBadge: View {
    var text: String
    var tint: Color = AOSTheme.gold

    var body: some View {
        Text(text)
            .font(.caption2.weight(.bold))
            .foregroundStyle(tint)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(tint.opacity(0.12), in: Capsule())
            .overlay(Capsule().stroke(tint.opacity(0.24), lineWidth: 1))
    }
}

struct AOSProgressBar: View {
    var value: Double

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.08))
                Capsule()
                    .fill(LinearGradient(colors: [AOSTheme.gold, Color(red: 1.0, green: 0.86, blue: 0.52)], startPoint: .leading, endPoint: .trailing))
                    .frame(width: proxy.size.width * max(0, min(value, 1)))
                    .animation(.snappy(duration: 0.35), value: value)
            }
        }
        .frame(height: 7)
    }
}

struct ScoreRing: View {
    var value: Double

    var body: some View {
        ZStack {
            Circle().stroke(Color.white.opacity(0.08), lineWidth: 5)
            Circle()
                .trim(from: 0, to: max(0, min(value, 1)))
                .stroke(AOSTheme.gold, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                .rotationEffect(.degrees(-90))
            VStack(spacing: 0) {
                Text("\(Int(value * 100))")
                    .font(.system(size: 20, weight: .bold, design: .rounded))
                Text("fit")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(AOSTheme.muted)
            }
        }
        .frame(width: 74, height: 74)
    }
}
