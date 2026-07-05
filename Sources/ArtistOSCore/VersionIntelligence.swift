import Foundation

/// Canonical filename + decision intelligence. MUST match docs/core.js
/// (see Docs/VISION.md); shared test vectors live in both test suites.
public enum VersionIntelligence {

    static let versionWords: Set<String> = [
        "final", "master", "mix", "mixdown", "bounce", "bounced", "draft", "take",
        "rough", "demo", "version", "ver", "v", "edit", "export", "render", "copy",
        "alt", "revision", "rev", "new", "update", "updated", "latest", "old", "wip"
    ]

    public struct Parsed: Equatable {
        public var canonical: String
        public var label: String?
        public var order: Int?
        public init(canonical: String, label: String? = nil, order: Int? = nil) {
            self.canonical = canonical; self.label = label; self.order = order
        }
    }

    private static func stripParens(_ w: String) -> String {
        w.replacingOccurrences(of: "(", with: "").replacingOccurrences(of: ")", with: "")
    }

    private static func vNumber(_ t: String) -> Int? {
        var s = t
        if s.hasPrefix("ver") { s.removeFirst(3) }
        else if s.hasPrefix("v") { s.removeFirst() }
        else { return nil }
        if s.hasPrefix(".") { s.removeFirst() }
        guard !s.isEmpty, s.count <= 3, s.allSatisfy({ $0.isNumber }) else { return nil }
        return Int(s)
    }

    /// Splits "mix2" -> ("mix", 2); returns nil when no trailing digits.
    private static func wordDigits(_ t: String) -> (word: String, number: Int)? {
        let chars = Array(t)
        var i = chars.count
        while i > 0, chars[i - 1].isNumber { i -= 1 }
        guard i < chars.count, chars.count - i <= 3 else { return nil }
        return (String(chars[0..<i]), Int(String(chars[i...]))!)
    }

    public static func isVersionToken(_ raw: String) -> Bool {
        let t = stripParens(raw.lowercased())
        if t.isEmpty { return false }
        if t.count <= 3, t.allSatisfy({ $0.isNumber }) { return true }
        if vNumber(t) != nil { return true }
        if versionWords.contains(t) { return true }
        if let wd = wordDigits(t), !wd.word.isEmpty, versionWords.contains(wd.word) { return true }
        return false
    }

    /// (number, strength): v# = 3, word# = 2, bare # = 1.
    public static func versionNumber(_ raw: String) -> (n: Int, strength: Int)? {
        let t = stripParens(raw.lowercased())
        if let n = vNumber(t) { return (n, 3) }
        if let wd = wordDigits(t) {
            if wd.word.isEmpty { return (wd.number, 1) }
            if versionWords.contains(wd.word) { return (wd.number, 2) }
        }
        return nil
    }

    public static func parse(_ raw: String) -> Parsed {
        var base = ImportService.titleize(raw)
        var labelParts: [String] = []
        var order: Int?
        var strength = 0

        func note(_ tok: String) {
            if let v = versionNumber(tok), v.strength >= strength {
                order = v.n
                strength = v.strength
            }
        }

        var changed = true
        while changed {
            changed = false
            if base.hasSuffix(")"), let open = base.lastIndex(of: "(") {
                let innerStart = base.index(after: open)
                let inner = String(base[innerStart..<base.index(before: base.endIndex)])
                    .trimmingCharacters(in: .whitespaces)
                let toks = inner.split(separator: " ").map(String.init)
                let allNums = !toks.isEmpty && toks.allSatisfy { $0.count <= 3 && $0.allSatisfy({ $0.isNumber }) }
                let versionish = !toks.isEmpty && (allNums || toks.contains(where: isVersionToken))
                if versionish {
                    labelParts.insert(inner, at: 0)
                    toks.forEach(note)
                    base = String(base[..<open]).trimmingCharacters(in: .whitespaces)
                    changed = true
                    continue
                }
            }
            var words = base.split(separator: " ").map(String.init)
            if words.count > 1, isVersionToken(words[words.count - 1]) {
                let w = words.removeLast()
                labelParts.insert(stripParens(w), at: 0)
                note(w)
                base = words.joined(separator: " ")
                changed = true
            }
        }

        let canonical = base.trimmingCharacters(in: CharacterSet(charactersIn: " -_."))
        if canonical.count < 2 || canonical.allSatisfy({ $0.isNumber }) {
            return Parsed(canonical: ImportService.titleize(raw), label: nil, order: nil)
        }
        return Parsed(
            canonical: canonical,
            label: labelParts.isEmpty ? nil : labelParts.joined(separator: " "),
            order: order
        )
    }

    // MARK: - Version stacks

    public static func sortVersions(_ assets: [Asset]) -> [Asset] {
        assets.sorted { a, b in
            let av = a.vOrder ?? -1, bv = b.vOrder ?? -1
            if av != bv { return av > bv }
            let am = a.fileModifiedAt ?? .distantPast, bm = b.fileModifiedAt ?? .distantPast
            if am != bm { return am > bm }
            return a.createdAt > b.createdAt
        }
    }

    public static func versionStack(_ assets: [Asset]) -> [Asset] {
        sortVersions(assets.filter { $0.version != nil || $0.vOrder != nil })
    }

    /// Master decisions consider only full-mix bounces: a hook take and a
    /// beat both labeled "v1" are not versions of each other.
    public static func masterStack(_ assets: [Asset]) -> [Asset] {
        versionStack(assets).filter { $0.role == .fullMix }
    }

    // MARK: - Decision engine (D1 + D2, see VISION.md)

    static let decisiveRoles: [(role: AssetRole, slotTarget: EventTarget)] = [
        (.hook, .hook), (.bridge, .bridge), (.leadVocal, .verse)
    ]

    public static func slotTarget(forSectionName name: String) -> EventTarget {
        let n = name.lowercased()
        if n.contains("intro") { return .intro }
        if n.contains("verse") { return .verse }
        if n.contains("hook") || n.contains("chorus") { return .hook }
        if n.contains("bridge") { return .bridge }
        return .song
    }

    public struct AutoFlag {
        public var sectionID: UUID
        public var sectionName: String
        public var role: AssetRole
        public var count: Int
        public init(sectionID: UUID, sectionName: String, role: AssetRole, count: Int) {
            self.sectionID = sectionID; self.sectionName = sectionName; self.role = role; self.count = count
        }
    }

    /// D1: escalate-only, idempotent. Mutates the song's sections.
    public static func applyAutoDecisions(song: inout Song, assets: [Asset]) -> [AutoFlag] {
        var fired: [AutoFlag] = []
        let escalatable: Set<SectionState> = [.open, .candidate, .experiment]
        for (role, target) in decisiveRoles {
            let candidates = assets.filter { $0.role == role }
            guard candidates.count >= 2 else { continue }
            for index in song.sections.indices {
                guard slotTarget(forSectionName: song.sections[index].name) == target,
                      escalatable.contains(song.sections[index].state)
                else { continue }
                song.sections[index].state = .needsDecision
                song.sections[index].confidence = max(song.sections[index].confidence, 0.5)
                fired.append(AutoFlag(
                    sectionID: song.sections[index].id,
                    sectionName: song.sections[index].name,
                    role: role,
                    count: candidates.count
                ))
            }
        }
        return fired
    }

    public enum DecisionKind { case slot, master }

    public struct Decision: Identifiable {
        public let id: String
        public let kind: DecisionKind
        public let songID: UUID
        public let sectionID: UUID?
        public let title: String
        public let detail: String
        public init(id: String, kind: DecisionKind, songID: UUID, sectionID: UUID?, title: String, detail: String) {
            self.id = id; self.kind = kind; self.songID = songID
            self.sectionID = sectionID; self.title = title; self.detail = detail
        }
    }

    public static func decisions(for song: Song, assets: [Asset]) -> [Decision] {
        var out: [Decision] = []
        for section in song.sections where section.state == .needsDecision {
            out.append(Decision(
                id: "slot-\(section.id.uuidString)",
                kind: .slot, songID: song.id, sectionID: section.id,
                title: "\(section.name) — \(song.title)",
                detail: "Candidates waiting on a call"
            ))
        }
        let stack = masterStack(assets)
        if stack.count >= 2 {
            let top = stack[0]
            if song.masterAssetID == nil {
                out.append(Decision(
                    id: "master-\(song.id.uuidString)",
                    kind: .master, songID: song.id, sectionID: nil,
                    title: "Current master — \(song.title)",
                    detail: "\(stack.count) versions stacked, none pinned as master"
                ))
            } else if song.masterAssetID != top.id, stack.contains(where: { $0.id == song.masterAssetID }) {
                out.append(Decision(
                    id: "master-\(song.id.uuidString)",
                    kind: .master, songID: song.id, sectionID: nil,
                    title: "New version — \(song.title)",
                    detail: "\(top.version ?? "A newer version") challenges the pinned master"
                ))
            }
        }
        return out
    }
}
