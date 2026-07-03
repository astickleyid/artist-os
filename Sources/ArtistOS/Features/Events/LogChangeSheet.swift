import SwiftUI

/// Manual creative-event entry using the structured target + operation language.
struct LogChangeSheet: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var target: EventTarget = .song
    @State private var operation: EventOperation = .structureUpdated
    @State private var summary = ""
    @State private var assetID: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Log Change")
                    .font(.title3.weight(.black))
                if let song = state.selectedSong {
                    Text(song.title)
                        .font(.caption)
                        .foregroundStyle(AOSTheme.muted)
                }
            }

            Form {
                Picker("Target", selection: $target) {
                    ForEach(EventTarget.allCases, id: \.rawValue) { candidate in
                        Text(candidate.rawValue).tag(candidate)
                    }
                }
                Picker("Operation", selection: $operation) {
                    ForEach(EventOperation.allCases, id: \.rawValue) { candidate in
                        Text(candidate.rawValue).tag(candidate)
                    }
                }
                Picker("Asset", selection: $assetID) {
                    Text("None").tag(UUID?.none)
                    if let song = state.selectedSong {
                        ForEach(state.assets(for: song.id)) { asset in
                            Text(asset.title).tag(Optional(asset.id))
                        }
                    }
                }
                TextField("Summary", text: $summary, prompt: Text("What changed?"))
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Log Change") {
                    state.logManualEvent(
                        target: target,
                        operation: operation,
                        summary: summary,
                        assetID: assetID
                    )
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .tint(AOSTheme.gold)
                .disabled(state.selectedSong == nil)
            }
        }
        .padding(18)
        .frame(width: 420)
    }
}
