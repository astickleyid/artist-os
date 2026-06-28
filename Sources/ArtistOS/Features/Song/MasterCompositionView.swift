import SwiftUI

struct MasterCompositionView: View {
    @EnvironmentObject private var state: AppState
    let song: Song

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Current Master Composition")
                .font(.caption.weight(.black))
                .foregroundStyle(AOSTheme.muted)
                .textCase(.uppercase)

            ForEach(Array(song.sections.enumerated()), id: \.element.id) { index, section in
                MasterSectionRow(index: index + 1, section: section, asset: state.asset(id: section.assetID))
                    .onTapGesture {
                        state.selectedAssetID = section.assetID
                    }
            }
        }
    }
}

struct MasterSectionRow: View {
    let index: Int
    let section: MasterSection
    let asset: Asset?

    var tint: Color {
        switch section.state {
        case .locked: return AOSTheme.green
        case .candidate, .needsDecision: return AOSTheme.gold
        case .experiment: return AOSTheme.blue
        case .open: return AOSTheme.muted
        }
    }

    var body: some View {
        HStack(spacing: 14) {
            Text(String(format: "%02d", index))
                .font(.caption.weight(.black))
                .foregroundStyle(AOSTheme.muted)
                .frame(width: 42, height: 42)
                .background(Color.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 12, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                Text(section.name).font(.headline.weight(.black))
                Text(section.role).font(.caption).foregroundStyle(AOSTheme.muted)
            }
            .frame(width: 118, alignment: .leading)

            VStack(alignment: .leading, spacing: 3) {
                Text(asset?.title ?? "No asset selected").font(.subheadline.weight(.bold))
                Text(asset?.originalFilename ?? section.note).font(.caption).foregroundStyle(AOSTheme.muted).lineLimit(1)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 7) {
                AOSBadge(text: section.state.rawValue, tint: tint)
                AOSProgressBar(value: section.confidence)
                    .frame(width: 80)
            }
        }
        .padding(13)
        .aosPanel(cornerRadius: 17)
    }
}
