import SwiftUI

@main
struct ArtistOSApp: App {
    @StateObject private var state = AppState()

    var body: some Scene {
        WindowGroup {
            ArtistOSShellView()
                .environmentObject(state)
                .environmentObject(state.audio)
                .frame(minWidth: 1180, minHeight: 760)
        }
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandMenu("Artist OS") {
                Button("Import Career Folder…") {
                    state.isImportPresented = true
                }
                .keyboardShortcut("i", modifiers: [.command, .shift])
                Button("Log Change…") {
                    state.isLogChangePresented = true
                }
                .keyboardShortcut("l", modifiers: [.command, .shift])
                Button("Re-analyze Filenames") {
                    state.reanalyzeCatalog()
                }
            }
        }
    }
}
