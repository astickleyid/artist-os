import SwiftUI

@main
struct ArtistOSApp: App {
    @StateObject private var state = AppState()

    var body: some Scene {
        WindowGroup {
            ArtistOSShellView()
                .environmentObject(state)
                .frame(minWidth: 1180, minHeight: 760)
        }
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandMenu("Artist OS") {
                Button("Import Career Folder…") {
                    state.isImportPresented = true
                }
                .keyboardShortcut("i", modifiers: [.command, .shift])
            }
        }
    }
}
