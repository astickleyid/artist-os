import SwiftUI

struct CommandBarView: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        HStack(spacing: 12) {
            HStack(spacing: 8) {
                Text("⌘K")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(AOSTheme.muted)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(Color.black.opacity(0.22), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                TextField("Search songs, files, sections, changes…", text: $state.searchText)
                    .textFieldStyle(.plain)
            }
            .padding(.horizontal, 12)
            .frame(height: 38)
            .aosPanel(cornerRadius: 12)

            Button("Analyze") {}
                .buttonStyle(.bordered)
            Button("Update Master") {}
                .buttonStyle(.borderedProminent)
                .tint(AOSTheme.gold)
        }
        .padding(14)
        .background(.ultraThinMaterial)
    }
}
