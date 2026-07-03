import SwiftUI

struct CommandBarView: View {
    @EnvironmentObject private var state: AppState
    @State private var isCreatingSong = false
    @State private var newSongTitle = ""
    @FocusState private var searchFocused: Bool

    var body: some View {
        HStack(spacing: 12) {
            HStack(spacing: 8) {
                Text("⌘K")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(AOSTheme.muted)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(Color.black.opacity(0.22), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                TextField("Search songs, files, sections, changes…  (⌘K)", text: $state.searchText)
                    .focused($searchFocused)
                    .textFieldStyle(.plain)
            }
            .padding(.horizontal, 12)
            .frame(height: 38)
            .aosPanel(cornerRadius: 12)

            Button("New Song") {
                newSongTitle = ""
                isCreatingSong = true
            }
            .buttonStyle(.bordered)
            Button("Log Change") {
                state.isLogChangePresented = true
            }
            .buttonStyle(.borderedProminent)
            .tint(AOSTheme.gold)
            .disabled(state.selectedSong == nil)
        }
        .padding(14)
        .background(.ultraThinMaterial)
        .background {
            Button("") { searchFocused = true }
                .keyboardShortcut("k", modifiers: .command)
                .opacity(0)
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)
        }
        .alert("New Song", isPresented: $isCreatingSong) {
            TextField("Song title", text: $newSongTitle)
            Button("Create") { state.createSong(title: newSongTitle) }
            Button("Cancel", role: .cancel) {}
        }
    }
}
