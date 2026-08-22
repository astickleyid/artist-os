import SwiftUI
import ArtistOSCore

/// Side-by-side candidate comparison for a master slot, following the
/// reference-comparison pattern from mastering tools (Metric AB, Ozone):
/// instant A/B source switching at a held playhead position, then commit.
struct CompareSheet: View {
    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var audio: AudioPreviewService
    @Environment(\.dismiss) private var dismiss

    let song: Song
    let section: MasterCompositionSection?

    @State private var assetAID: UUID?
    @State private var assetBID: UUID?
    @State private var reason: String = ""
    @State private var structuralEvidence: String?
    @State private var isAnalyzingStructure = false

    private var isMasterMode: Bool { section == nil }
    private var candidates: [Asset] {
        if isMasterMode {
            return state.masterStack(for: song.id)
        }
        guard let section else { return [] }
        return ComparisonIntelligence.rankedCandidates(
            for: section,
            assets: state.assets(for: song.id)
        )
    }
    private var currentMasterAssetID: UUID? {
        state.catalog.masterComposition(for: song.id)?.outputAssetID
    }
    private var assetA: Asset? { state.asset(id: assetAID) }
    private var assetB: Asset? { state.asset(id: assetBID) }
    private var structuralPairKey: String {
        guard isMasterMode else { return "section-mode" }
        return "\(assetAID?.uuidString ?? "none")|\(assetBID?.uuidString ?? "none")"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text(isMasterMode ? "Current master — \(song.title)" : "Compare — \(section?.name ?? "")")
                    .font(.title3.weight(.black))
                Text(isMasterMode
                     ? "Compare any two versions at the same playhead. Pinning records the artist decision and updates the canonical master."
                     : "Switch sources without losing the playhead. Choosing a side records the decision and locks the canonical slot.")
                    .font(.caption)
                    .foregroundStyle(AOSTheme.muted)
            }

            if candidates.count < 2 {
                Text(isMasterMode
                     ? "This song needs at least two full-mix versions to run a comparison. Import another mix first."
                     : "This slot needs at least two relevant assets to run a comparison. Import another matching take first.")
                    .font(.subheadline)
                    .foregroundStyle(AOSTheme.muted)
                    .padding(.vertical, 20)
            } else {
                HStack(spacing: 12) {
                    candidateCard(label: "A", asset: assetA, tint: AOSTheme.gold,
                                  selection: $assetAID, shortcut: "a")
                    candidateCard(label: "B", asset: assetB, tint: AOSTheme.blue,
                                  selection: $assetBID, shortcut: "b")
                }

                if let assetA,
                   let assetB,
                   let difference = AudioComparisonEvidence.relativeSummary(between: assetA, and: assetB) {
                    Text("Measured difference · \(difference)")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(AOSTheme.muted)
                        .lineLimit(2)
                }

                if let assetA,
                   let assetB,
                   let arrangementSignal = AudioComparisonEvidence.arrangementReviewSignal(between: assetA, and: assetB) {
                    Text(arrangementSignal)
                        .font(.caption2.weight(.semibold).monospacedDigit())
                        .foregroundStyle(AOSTheme.gold)
                }

                if isMasterMode {
                    if isAnalyzingStructure {
                        HStack(spacing: 6) {
                            ProgressView()
                                .controlSize(.small)
                            Text("Analyzing detected structure…")
                                .font(.caption2)
                                .foregroundStyle(AOSTheme.muted)
                        }
                    } else if let structuralEvidence {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Detected structure · \(structuralEvidence)")
                                .font(.caption2.weight(.semibold).monospacedDigit())
                                .foregroundStyle(AOSTheme.gold)
                                .lineLimit(2)
                            Text("Audio segmentation is derived analysis, not arrangement truth. Listen to confirm.")
                                .font(.caption2)
                                .foregroundStyle(AOSTheme.muted)
                        }
                    }
                }

                if !isMasterMode {
                    Text("Candidate order uses current-source and version/recency signals only. Newer does not mean better — you decide by listening.")
                        .font(.caption2)
                        .foregroundStyle(AOSTheme.muted)
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("WHY THIS ONE? · OPTIONAL")
                        .font(.caption2.weight(.bold))
                        .tracking(0.8)
                        .foregroundStyle(AOSTheme.muted)
                    TextField("Cleaner emotion, tighter pocket, better balance…", text: $reason, axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                        .lineLimit(1...3)
                    Text("This is stored with the decision, not in the factual change log.")
                        .font(.caption2)
                        .foregroundStyle(AOSTheme.muted)
                }
            }

            HStack {
                Button("Keep Undecided") { close() }
                Spacer()
                if let assetA {
                    Button(isMasterMode ? "Pin A as Master" : "Choose A") { choose(assetA) }
                        .buttonStyle(.borderedProminent)
                        .tint(AOSTheme.gold)
                }
                if let assetB {
                    Button(isMasterMode ? "Pin B as Master" : "Choose B") { choose(assetB) }
                        .buttonStyle(.borderedProminent)
                        .tint(AOSTheme.blue)
                }
            }
        }
        .padding(20)
        .frame(width: 560)
        .onAppear(perform: seedDefaults)
        .task(id: structuralPairKey) {
            await refreshStructuralEvidence()
        }
        .onDisappear { audio.stop() }
    }

    private func candidateCard(
        label: String,
        asset: Asset?,
        tint: Color,
        selection: Binding<UUID?>,
        shortcut: KeyEquivalent
    ) -> some View {
        let isActive = asset != nil && audio.playingAssetID == asset?.id
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(label)
                    .font(.title2.weight(.black))
                    .foregroundStyle(tint)
                Spacer()
                Picker("", selection: selection) {
                    Text("Pick asset…").tag(UUID?.none)
                    ForEach(candidates) { candidate in
                        Text(candidate.title).tag(Optional(candidate.id))
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 170)
            }

            if let asset {
                WaveformView(asset: asset, tint: tint)
                    .frame(height: 34)
                Text(asset.originalFilename)
                    .font(.caption)
                    .foregroundStyle(AOSTheme.muted)
                    .lineLimit(1)
                if let explanation = surfacingExplanation(for: asset) {
                    Text(explanation)
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(AOSTheme.muted)
                }
                if let evidence = AudioComparisonEvidence.summary(for: asset) {
                    Text("Detected audio · \(evidence)")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(AOSTheme.muted)
                        .lineLimit(1)
                }
                Button {
                    if isActive {
                        if audio.isPlaying { audio.pause() } else { audio.resume() }
                    } else {
                        audio.switchPreview(to: asset)
                    }
                } label: {
                    Label(
                        isActive && audio.isPlaying ? "Pause" : "Listen \(label)",
                        systemImage: isActive && audio.isPlaying ? "pause.fill" : "play.fill"
                    )
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .tint(tint)
                .keyboardShortcut(shortcut, modifiers: [])
                .disabled(!audio.canPlay(asset))
            } else {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.white.opacity(0.04))
                    .frame(height: 34)
                Text("No candidate selected")
                    .font(.caption)
                    .foregroundStyle(AOSTheme.muted)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .aosPanel(cornerRadius: 16)
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(isActive ? tint : .clear, lineWidth: 2)
        )
    }

    private func surfacingExplanation(for asset: Asset) -> String? {
        guard let section else { return nil }
        return ComparisonIntelligence.surfacingReason(
            for: asset,
            section: section,
            assets: state.assets(for: song.id)
        ).explanation
    }

    private func seedDefaults() {
        let ids = candidates.map(\.id)
        if isMasterMode {
            assetBID = ids.first
            assetAID = (currentMasterAssetID.flatMap { m in ids.contains(m) ? m : nil })
                ?? ids.first { $0 != assetBID } ?? ids.first
        } else {
            let currentSourceID = section?.selection(.sourceAsset)?.referenceID
            assetAID = currentSourceID.flatMap { ids.contains($0) ? $0 : nil } ?? ids.first
            assetBID = ids.first { $0 != assetAID } ?? ids.dropFirst().first
        }
    }

    @MainActor
    private func refreshStructuralEvidence() async {
        guard isMasterMode,
              let assetA,
              let assetB,
              assetA.id != assetB.id,
              audio.canPlay(assetA),
              audio.canPlay(assetB) else {
            structuralEvidence = nil
            isAnalyzingStructure = false
            return
        }

        structuralEvidence = nil
        isAnalyzingStructure = true

        async let resultA = StructuralAnalysisStore.shared.result(for: assetA)
        async let resultB = StructuralAnalysisStore.shared.result(for: assetB)
        let (segmentationA, segmentationB) = await (resultA, resultB)

        guard !Task.isCancelled else { return }
        isAnalyzingStructure = false
        guard let segmentationA, let segmentationB else { return }
        structuralEvidence = StructuralComparisonEvidence.summary(
            between: segmentationA,
            and: segmentationB
        )
    }

    private func choose(_ winner: Asset) {
        let compared = [assetAID, assetBID].compactMap { $0 }
        let rejected = compared.filter { $0 != winner.id }
        if isMasterMode {
            state.approveMasterDecision(
                songID: song.id,
                assetID: winner.id,
                rejectedAssetIDs: rejected,
                reason: reason
            )
        } else if let section {
            state.approveSectionDecision(
                sectionID: section.id,
                songID: song.id,
                winner: winner.id,
                rejectedAssetIDs: rejected,
                reason: reason
            )
        }
        close()
    }

    private func close() {
        audio.stop()
        dismiss()
    }
}
