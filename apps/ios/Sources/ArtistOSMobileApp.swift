import SwiftUI

@main
struct ArtistOSMobileApp: App {
    @StateObject private var store = MobileStore()
    var body: some Scene {
        WindowGroup {
            HomeView()
                .environmentObject(store)
                .preferredColorScheme(.dark)
                .tint(AOS.gold)
        }
    }
}
