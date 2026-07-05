import Foundation

/// Cross-version assembly — the "verse from v1, hook from v3" recipe layer.
/// Builds/validates an ordered plan of section-slices from different versions,
/// flags seams (tempo/key mismatches), and groups slices into unified folders.
/// Pure; the audio render consumes a validated plan. MUST match docs/assembly.js.
public enum Assembly {

    /// A pick fills a structural slot with a section-slice from a specific asset.
    public struct Pick: Equatable {
        public var slotId: String
        public var label: String
        public var assetId: String?
        public var sectionId: String?
        public var start: Double
        public var end: Double
        public var bpm: Double?
        public var keyName: String?
        public var crossfade: Double
        public init(slotId: String, label: String, assetId: String?, sectionId: String? = nil,
                    start: Double, end: Double, bpm: Double? = nil, keyName: String? = nil, crossfade: Double = 0.04) {
            self.slotId = slotId; self.label = label; self.assetId = assetId; self.sectionId = sectionId
            self.start = start; self.end = end; self.bpm = bpm; self.keyName = keyName; self.crossfade = crossfade
        }
    }

    public struct SeamIssue: Equatable {
        public enum Kind: String { case tempo, key }
        public var type: Kind
        public var detail: String
    }
    public struct Seam: Equatable {
        public var betweenIndex: Int
        public var at: Int
        public var issues: [SeamIssue]
    }

    public struct Validation {
        public var ok: Bool
        public var errors: [String]
        public var warnings: [String]
        public var seams: [Seam]
    }

    /// A section-slice as gathered across versions (for folders + source pickers).
    public struct Slice: Equatable {
        public var assetId: String
        public var assetTitle: String
        public var version: String
        public var sectionId: String
        public var label: String
        public var start: Double
        public var end: Double
        public var confidence: Double
        public var bpm: Double?
        public var keyName: String?
        public init(assetId: String, assetTitle: String, version: String, sectionId: String, label: String,
                    start: Double, end: Double, confidence: Double, bpm: Double? = nil, keyName: String? = nil) {
            self.assetId = assetId; self.assetTitle = assetTitle; self.version = version
            self.sectionId = sectionId; self.label = label; self.start = start; self.end = end
            self.confidence = confidence; self.bpm = bpm; self.keyName = keyName
        }
    }

    public struct Folder: Equatable {
        public var label: String
        public var items: [Slice]
    }

    public static func sliceDuration(_ p: Pick) -> Double { max(0, p.end - p.start) }

    public static func totalDuration(_ recipe: [Pick]) -> Double {
        recipe.reduce(0) { $0 + sliceDuration($1) }
    }

    /// Seams: tempo jump or key change between adjacent picks (won't beat-match).
    public static func seamsFor(_ recipe: [Pick], bpmTolerance: Double = 2) -> [Seam] {
        var seams: [Seam] = []
        guard recipe.count > 1 else { return seams }
        for i in 1..<recipe.count {
            let prev = recipe[i - 1], cur = recipe[i]
            var issues: [SeamIssue] = []
            if let pb = prev.bpm, let cb = cur.bpm, abs(pb - cb) > bpmTolerance {
                issues.append(SeamIssue(type: .tempo, detail: "\(Int(pb.rounded())) → \(Int(cb.rounded())) BPM"))
            }
            if let pk = prev.keyName, let ck = cur.keyName, pk != ck {
                issues.append(SeamIssue(type: .key, detail: "\(pk) → \(ck)"))
            }
            if !issues.isEmpty { seams.append(Seam(betweenIndex: i - 1, at: i, issues: issues)) }
        }
        return seams
    }

    public static func validateRecipe(_ recipe: [Pick], bpmTolerance: Double = 2) -> Validation {
        var errors: [String] = []
        var warnings: [String] = []
        if recipe.isEmpty {
            errors.append("Add at least one section to build a version.")
            return Validation(ok: false, errors: errors, warnings: warnings, seams: [])
        }
        for (i, p) in recipe.enumerated() {
            if p.assetId == nil || p.assetId?.isEmpty == true {
                errors.append("Section \(i + 1) has no source version selected.")
            }
            if sliceDuration(p) <= 0 {
                errors.append("Section \(i + 1) (\(p.label)) has zero length.")
            }
        }
        let seams = seamsFor(recipe, bpmTolerance: bpmTolerance)
        for s in seams {
            for issue in s.issues {
                warnings.append("Seam at section \(s.at + 1): \(issue.detail) — cut will not beat-match.")
            }
        }
        return Validation(ok: errors.isEmpty, errors: errors, warnings: warnings, seams: seams)
    }

    /// Group every section-slice across versions by label — the unified folders
    /// ("every Chorus, from every version, in one place").
    public static func unifiedFolders(_ slices: [Slice]) -> [Folder] {
        var map: [String: [Slice]] = [:]
        var order: [String] = []
        for s in slices {
            let key = s.label.isEmpty ? "Section" : s.label
            if map[key] == nil { map[key] = []; order.append(key) }
            map[key]?.append(s)
        }
        let canonical = ["Intro", "Verse", "Hook", "Chorus", "Bridge", "Outro"]
        func rank(_ l: String) -> Int { canonical.firstIndex(of: l) ?? 99 }
        return order
            .map { Folder(label: $0, items: map[$0] ?? []) }
            .sorted { a, b in
                let ra = rank(a.label), rb = rank(b.label)
                if ra != rb { return ra < rb }
                return a.label < b.label
            }
    }
}
