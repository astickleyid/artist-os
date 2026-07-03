import SwiftUI

struct CreativeTimelineView: View {
    @EnvironmentObject private var state: AppState
    let song: Song

    var events: [CreativeEvent] {
        state.catalog.events
            .filter { $0.songID == song.id }
            .sorted { $0.timestamp > $1.timestamp }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Creative Change Log")
                .font(.caption.weight(.black))
                .foregroundStyle(AOSTheme.muted)
                .textCase(.uppercase)

            ForEach(events) { event in
                HStack(alignment: .top, spacing: 14) {
                    Text(AOSTime.ago(event.timestamp))
                        .font(.caption.weight(.bold).monospacedDigit())
                        .foregroundStyle(AOSTheme.muted)
                        .frame(width: 62, alignment: .leading)
                        .help(event.timestamp.formatted(date: .abbreviated, time: .shortened))

                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 8) {
                            Text(event.target.rawValue).font(.subheadline.weight(.black))
                            Text(event.operation.rawValue).font(.subheadline.weight(.black)).foregroundStyle(AOSTheme.gold)
                        }
                        Text(event.summary)
                            .font(.caption)
                            .foregroundStyle(AOSTheme.muted)
                    }
                    Spacer()
                    Text("\(Int(event.confidence * 100))%")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(AOSTheme.muted)
                }
                .padding(13)
                .aosPanel(cornerRadius: 15)
                .aosHoverable(cornerRadius: 15)
            }
        }
    }
}
