import SwiftUI

struct MasterCompositionView: View {
    @EnvironmentObject private var state: AppState
    let song: Song

    @State private var isAddingSlot = false
    @State private var newSlotName = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Current Master Composition")
                    .font(.caption.weight(.black))
                    .foregroundStyle(AOSTheme.muted)
                    .textCase(.uppercase)
                Spacer()
                Button {
                    newSlotName = ""
                    isAddingSlot = true
                } label: {
                    Label("Add Slot", systemImage: "plus")
                        .font(.caption.weight(.bold))
                }
                .buttonStyle(.bordered)
            }

            ForEach(Array(song.sections.enumerated()), id: \.element.id) { index, section in
                MasterSectionRow(index: index + 1, song: song, section: section)
                    .aosHoverable(cornerRadius: 17)
            }
            .animation(.snappy(duration: 0.25), value: song.sections.map(\.id))

            if song.sections.isEmpty {
                Text("No master slots yet. Add a slot to start structuring this song.")
                    .font(.caption)
                    .foregroundStyle(AOSTheme.muted)
                    .padding(14)
            }
        }
        .alert("New Master Slot", isPresented: $isAddingSlot) {
            TextField("Slot name (e.g. Verse 2)", text: $newSlotName)
            Button("Add") { state.addSection(name: newSlotName, songID: song.id) }
            Button("Cancel", role: .cancel) {}
        }
    }
}

struct MasterSectionRow: View {
    @EnvironmentObject private var state: AppState

    let index: Int
    let song: Song
    let section: MasterSection

    @State private var isEditingNote = false
    @State private var noteDraft = ""
    @State private var isDropTargeted = false
    @State private var isComparing = false

    private var asset: Asset? { state.asset(id: section.assetID) }

    private var tint: Color {
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

            if let asset {
                PlayButton(asset: asset)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(asset?.title ?? "No asset selected")
                    .font(.subheadline.weight(.bold))
                Text(asset?.originalFilename ?? (section.note.isEmpty ? "Assign a source from this song's assets." : section.note))
                    .font(.caption)
                    .foregroundStyle(AOSTheme.muted)
                    .lineLimit(1)
            }

            Spacer()

            if section.state == .needsDecision {
                Button {
                    isComparing = true
                } label: {
                    Image(systemName: "scale.3d")
                        .foregroundStyle(AOSTheme.gold)
                }
                .buttonStyle(.plain)
                .help("Compare candidates and resolve this decision")
            }

            VStack(alignment: .trailing, spacing: 7) {
                AOSBadge(text: section.state.rawValue, tint: tint)
                AOSProgressBar(value: section.confidence)
                    .frame(width: 80)
            }

            sectionMenu
        }
        .padding(13)
        .aosPanel(cornerRadius: 17)
        .overlay(
            RoundedRectangle(cornerRadius: 17, style: .continuous)
                .stroke(isDropTargeted ? AOSTheme.gold : .clear, lineWidth: 2)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            state.selectedAssetID = section.assetID
        }
        .dropDestination(for: String.self) { items, _ in
            guard let raw = items.first, let assetID = UUID(uuidString: raw) else { return false }
            state.assign(assetID: assetID, sectionID: section.id, songID: song.id)
            return true
        } isTargeted: { targeted in
            isDropTargeted = targeted
        }
        .sheet(isPresented: $isEditingNote) {
            noteEditor
        }
        .sheet(isPresented: $isComparing) {
            CompareSheet(song: song, section: section)
        }
    }

    private var sectionMenu: some View {
        Menu {
            Menu("Assign Asset") {
                Button("None") {
                    state.assign(assetID: nil, sectionID: section.id, songID: song.id)
                }
                Divider()
                ForEach(state.assets(for: song.id)) { candidate in
                    Button(candidate.title) {
                        state.assign(assetID: candidate.id, sectionID: section.id, songID: song.id)
                    }
                }
            }
            Menu("Set State") {
                ForEach(SectionState.allCases, id: \.rawValue) { candidate in
                    Button(candidate.rawValue) {
                        state.setState(candidate, sectionID: section.id, songID: song.id)
                    }
                }
            }
            Button("Edit Note…") {
                noteDraft = section.note
                isEditingNote = true
            }
            Button("Compare Candidates…") {
                isComparing = true
            }
            Divider()
            Button("Move Up") {
                state.moveSection(sectionID: section.id, songID: song.id, offset: -1)
            }
            Button("Move Down") {
                state.moveSection(sectionID: section.id, songID: song.id, offset: 1)
            }
            Divider()
            Button("Remove Slot", role: .destructive) {
                state.removeSection(sectionID: section.id, songID: song.id)
            }
        } label: {
            Image(systemName: "ellipsis.circle")
                .foregroundStyle(AOSTheme.muted)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    private var noteEditor: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("\(section.name) Note")
                .font(.headline.weight(.bold))
            TextEditor(text: $noteDraft)
                .font(.body)
                .frame(minHeight: 110)
                .scrollContentBackground(.hidden)
                .padding(8)
                .aosPanel(cornerRadius: 10)
            HStack {
                Spacer()
                Button("Cancel") { isEditingNote = false }
                Button("Save") {
                    state.updateNote(noteDraft, sectionID: section.id, songID: song.id)
                    isEditingNote = false
                }
                .buttonStyle(.borderedProminent)
                .tint(AOSTheme.gold)
            }
        }
        .padding(18)
        .frame(width: 380)
    }
}

/// Shared row-level preview toggle (single active preview, DAW-browser style).
struct PlayButton: View {
    @EnvironmentObject private var audio: AudioPreviewService
    let asset: Asset

    private var isActive: Bool { audio.playingAssetID == asset.id && audio.isPlaying }

    var body: some View {
        Button {
            audio.toggle(asset: asset)
        } label: {
            Image(systemName: isActive ? "pause.circle.fill" : "play.circle.fill")
                .font(.system(size: 22))
                .foregroundStyle(audio.canPlay(asset) ? AOSTheme.gold : AOSTheme.muted.opacity(0.4))
        }
        .buttonStyle(.plain)
        .disabled(!audio.canPlay(asset))
        .help(audio.canPlay(asset) ? "Preview audio" : "No local file linked to this asset")
    }
}
