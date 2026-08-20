import SwiftUI

@main
struct ArtistOSApp: App {
    @StateObject private var state = AppState()
    @State private var reanalysisBlocked = false

    var body: some Scene {
        WindowGroup {
            ArtistOSShellView()
                .environmentObject(state)
                .environmentObject(state.audio)
                .frame(minWidth: 1180, minHeight: 760)
                .alert("Protected assets kept in place", isPresented: $reanalysisBlocked) {
                    Button("OK", role: .cancel) {}
                } message: {
                    Text("Artist OS kept assets referenced by the current Master Composition in place. Safe filename updates and regrouping were still applied.")
                }
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
                    reanalysisBlocked = !state.reanalyzeCatalogSafely()
                }
            }
        }
    }
}
