import Foundation

/// Canonical current creative state of a Song.
///
/// MasterComposition is not a bounce, mix, project file, or "latest version".
/// It is the blueprint of what the artist currently means the song to be.
///
/// Existing Song.sections remain supported while the app migrates. This model
/// gives us a stable destination that can express source audio, processing,
/// automation, and comp state independently instead of collapsing all of those
/// decisions into one `assetID`.
public struct MasterComposition: Identifiable, Codable, Equatable {
    public var id: UUID
    public var songID: UUID
    public var sections: [MasterCompositionSection]
    public var outputAssetID: UUID?
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        songID: UUID,
        sections: [MasterCompositionSection],
        outputAssetID: UUID? = nil,
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.songID = songID
        self.sections = sections
        self.outputAssetID = outputAssetID
        self.updatedAt = updatedAt
    }

    /// The source-of-truth is incomplete while a slot still needs a decision.
    public var unresolvedSectionIDs: [UUID] {
        sections.filter { $0.state == .needsDecision }.map(\.id)
    }

    public var isDecisionComplete: Bool {
        unresolvedSectionIDs.isEmpty
    }
}

/// One structural region of the current song blueprint.
///
/// `selections` deliberately separates independent creative dimensions. The
/// same recording can remain selected while only its processing snapshot changes.
public struct MasterCompositionSection: Identifiable, Codable, Equatable {
    public var id: UUID
    public var name: String
    public var role: String
    public var selections: [MasterSelection]
    public var state: SectionState
    public var confidence: Double
    public var note: String

    public init(
        id: UUID = UUID(),
        name: String,
        role: String,
        selections: [MasterSelection] = [],
        state: SectionState = .open,
        confidence: Double = 0,
        note: String = ""
    ) {
        self.id = id
        self.name = name
        self.role = role
        self.selections = selections
        self.state = state
        self.confidence = confidence
        self.note = note
    }

    public func selection(_ kind: MasterSelectionKind) -> MasterSelection? {
        selections.last { $0.kind == kind }
    }

    public mutating func setSelection(_ selection: MasterSelection?) {
        guard let selection else { return }
        selections.removeAll { $0.kind == selection.kind }
        selections.append(selection)
    }

    public mutating func clearSelection(_ kind: MasterSelectionKind) {
        selections.removeAll { $0.kind == kind }
    }
}

/// A selected piece of current creative truth for one section.
///
/// The reference is intentionally typed. Asset references are usable today;
/// other reference kinds create clean attachment points for immutable processing,
/// automation, and comp snapshots without pretending those are audio files.
public struct MasterSelection: Identifiable, Codable, Equatable {
    public var id: UUID
    public var kind: MasterSelectionKind
    public var referenceID: UUID
    public var decisionID: UUID?
    public var selectedAt: Date

    public init(
        id: UUID = UUID(),
        kind: MasterSelectionKind,
        referenceID: UUID,
        decisionID: UUID? = nil,
        selectedAt: Date = Date()
    ) {
        self.id = id
        self.kind = kind
        self.referenceID = referenceID
        self.decisionID = decisionID
        self.selectedAt = selectedAt
    }
}

public enum MasterSelectionKind: String, Codable, CaseIterable {
    /// Recording, beat, stem, mix, or other immutable Asset used as source.
    case sourceAsset = "Source Asset"

    /// Immutable future snapshot of channel-strip / patch / processing state.
    case processingSnapshot = "Processing Snapshot"

    /// Immutable future snapshot of automation state.
    case automationSnapshot = "Automation Snapshot"

    /// A Quick Swipe Comp recipe or other assembled-source recipe.
    case compRecipe = "Comp Recipe"
}

// MARK: - Backward-compatible bridge

public extension MasterComposition {
    /// Projects the legacy Song.sections representation into the canonical model.
    /// This lets existing libraries and UI continue to work while persistence and
    /// editing migrate incrementally instead of forcing a destructive rewrite.
    static func projected(from song: Song) -> MasterComposition {
        MasterComposition(
            songID: song.id,
            sections: song.sections.map { legacy in
                var selections: [MasterSelection] = []
                if let assetID = legacy.assetID {
                    selections.append(MasterSelection(
                        kind: .sourceAsset,
                        referenceID: assetID,
                        selectedAt: song.updatedAt
                    ))
                }
                return MasterCompositionSection(
                    id: legacy.id,
                    name: legacy.name,
                    role: legacy.role,
                    selections: selections,
                    state: legacy.state,
                    confidence: legacy.confidence,
                    note: legacy.note
                )
            },
            outputAssetID: song.masterAssetID,
            updatedAt: song.updatedAt
        )
    }
}
