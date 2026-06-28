import SwiftUI

struct InspectorView: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Inspector")
                .font(.caption.weight(.black))
                .foregroundStyle(AOSTheme.muted)
                .textCase(.uppercase)

            if let song = state.selectedSong {
                inspectorCard(title: "Current Risk") {
                    Text(song.risk).font(.headline.weight(.bold))
                }
                inspectorCard(title: "Master Progress") {
                    AOSProgressBar(value: song.progress)
                    Text("\(Int(song.progress * 100))%").font(.caption).foregroundStyle(AOSTheme.muted)
                }
            }

            inspectorCard(title: "Selected Asset") {
                if let asset = state.selectedAsset {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(asset.title).font(.headline.weight(.bold))
                        Text(asset.originalFilename).font(.caption).foregroundStyle(AOSTheme.muted)
                        AOSBadge(text: asset.role.rawValue, tint: AOSTheme.blue)
                        if let duration = asset.duration {
                            Text("Duration: \(Int(duration))s").font(.caption).foregroundStyle(AOSTheme.muted)
                        }
                    }
                } else {
                    Text("Select a master section or asset to inspect metadata.")
                        .font(.caption)
                        .foregroundStyle(AOSTheme.muted)
                }
            }

            inspectorCard(title: "Product Rule") {
                Text("The UI shows one living song. Versions, files, and experiments stay organized behind it.")
                    .font(.caption)
                    .foregroundStyle(AOSTheme.muted)
            }

            Spacer()
        }
        .padding(14)
        .background(.ultraThinMaterial)
    }

    private func inspectorCard<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(title)
                .font(.caption2.weight(.black))
                .foregroundStyle(AOSTheme.muted)
                .textCase(.uppercase)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(13)
        .aosPanel(cornerRadius: 16)
    }
}
