import SwiftUI

struct LibrarySidebarView: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            artistHeader
            navigation
            Spacer()
            importCard
        }
        .padding(16)
        .background(.ultraThinMaterial)
    }

    private var artistHeader: some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(LinearGradient(colors: [Color(red: 0.95, green: 0.78, blue: 0.45), AOSTheme.gold], startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(width: 40, height: 40)
                .overlay(Text("S").font(.headline.weight(.black)).foregroundStyle(.black))
            VStack(alignment: .leading, spacing: 2) {
                Text(state.catalog.artistName).font(.headline.weight(.bold))
                Text("Artist OS Library").font(.caption).foregroundStyle(AOSTheme.muted)
            }
        }
        .padding(.top, 8)
    }

    private var navigation: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Library")
                .font(.caption2.weight(.black))
                .foregroundStyle(AOSTheme.muted)
                .textCase(.uppercase)
            ForEach(NavigationItem.allCases) { item in
                Button {
                    state.selectedNavigation = item
                } label: {
                    HStack {
                        Text(item.rawValue)
                        Spacer()
                        if item == .songs { Text("\(state.catalog.songs.count)") }
                        if item == .assets { Text("\(state.catalog.assets.count)") }
                    }
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(state.selectedNavigation == item ? AOSTheme.text : AOSTheme.muted)
                    .padding(.horizontal, 11)
                    .padding(.vertical, 9)
                    .background(state.selectedNavigation == item ? Color.white.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var importCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Import career")
                .font(.subheadline.weight(.bold))
            Text("Drop a folder. Artist OS finds songs, assets, and change history.")
                .font(.caption)
                .foregroundStyle(AOSTheme.muted)
            Button("Import Folder") {
                state.isImportPresented = true
            }
            .buttonStyle(.borderedProminent)
            .tint(AOSTheme.gold)
        }
        .padding(14)
        .aosPanel(cornerRadius: 16)
    }
}
