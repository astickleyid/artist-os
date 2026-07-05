import SwiftUI

struct HomeView: View {
    @EnvironmentObject var store: CompanionStore
    @State private var showCapture = false

    private var greeting: String {
        let h = Calendar.current.component(.hour, from: Date())
        switch h {
        case ..<5: return "Late night"
        case ..<12: return "Good morning"
        case ..<18: return "Afternoon"
        default: return "Evening"
        }
    }

    var body: some View {
        if store.linkState != .linked {
            LinkView()
                .task { await store.bootstrap() }
        } else {
            feed
        }
    }

    private var feed: some View {
        ZStack(alignment: .bottom) {
            AOS.ink.ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: AOS.Space.lg) {
                    // header
                    VStack(alignment: .leading, spacing: 5) {
                        Text("\(greeting), STICK")
                            .font(.system(size: 26, weight: .black, design: .default))
                            .tracking(-0.5)
                            .foregroundStyle(AOS.text)
                        Text(subtitle)
                            .font(.system(size: 13))
                            .foregroundStyle(AOS.muted)
                    }
                    .padding(.top, 8)

                    // NEEDS YOU — triage first
                    VStack(alignment: .leading, spacing: AOS.Space.sm) {
                        SectionLabel(text: "Needs you", tint: AOS.gold, count: store.decisions.count)
                        if store.decisions.isEmpty {
                            AllClearRow()
                        } else {
                            ForEach(store.decisions) { DecisionCard(decision: $0) }
                        }
                    }

                    // JUST HAPPENED — the "it works for me" signal
                    if !store.recent.isEmpty {
                        VStack(alignment: .leading, spacing: AOS.Space.sm) {
                            SectionLabel(text: "Just happened", tint: AOS.green)
                            ForEach(store.recent) { HappenedRow(event: $0) }
                        }
                    }

                    // IN MOTION — songs by recent activity
                    VStack(alignment: .leading, spacing: AOS.Space.sm) {
                        SectionLabel(text: "In motion", tint: AOS.muted)
                        ForEach(store.songs) { MotionRow(song: $0) }
                    }

                    if store.songs.isEmpty {
                        Panel {
                            VStack(alignment: .leading, spacing: 6) {
                                Text("Linked — nothing here yet").font(.system(size: 15, weight: .bold)).foregroundStyle(AOS.text)
                                Text("Import audio on your Mac or in the web app and it appears here automatically.")
                                    .font(.system(size: 12.5)).foregroundStyle(AOS.muted)
                            }
                        }
                    }

                    Color.clear.frame(height: 96) // room above the capture bar
                }
                .padding(.horizontal, AOS.Space.lg)
            }

            CaptureBar { showCapture = true }
        }
        .refreshable { await store.refresh() }
        .sheet(isPresented: $showCapture) {
            CaptureSheet().presentationDetents([.medium])
        }
    }

    private var subtitle: String {
        let d = store.decisions.count
        if d == 0 { return "Everything's decided · \(store.songs.count) songs" }
        return "\(d) decision\(d == 1 ? "" : "s") waiting · \(store.songs.count) songs"
    }
}

// MARK: - decision card (the hero action)

struct DecisionCard: View {
    let decision: MobileDecision
    var body: some View {
        Button {
            // wired to the compare/decide flow once catalog data is live
        } label: {
            VStack(alignment: .leading, spacing: 13) {
                HStack(spacing: 12) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(AOS.gold.opacity(0.16))
                        Text("⚖").font(.system(size: 19))
                    }
                    .frame(width: 40, height: 40)

                    VStack(alignment: .leading, spacing: 3) {
                        Text(decision.kind == .master ? "PICK THE MASTER" : "COMPETING TAKES")
                            .font(.system(size: 10.5, weight: .black)).tracking(0.9)
                            .foregroundStyle(AOS.gold)
                        Text(decision.songTitle)
                            .font(.system(size: 15.5, weight: .bold))
                            .foregroundStyle(AOS.text)
                            .lineLimit(1)
                        Text(decision.detail)
                            .font(.system(size: 12.5))
                            .foregroundStyle(AOS.muted)
                            .lineLimit(2)
                    }
                    Spacer(minLength: 0)
                }
                HStack {
                    Spacer()
                    Text("Compare & decide →").font(.system(size: 13.5, weight: .bold))
                    Spacer()
                }
                .foregroundStyle(Color(hex: 0x14100A))
                .padding(.vertical, 11)
                .background(AOS.gold, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
            }
            .padding(AOS.Space.md)
            .background(
                LinearGradient(colors: [AOS.gold.opacity(0.12), AOS.panel],
                               startPoint: .topLeading, endPoint: .bottomTrailing),
                in: RoundedRectangle(cornerRadius: AOS.Radius.card, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: AOS.Radius.card, style: .continuous)
                    .strokeBorder(AOS.gold.opacity(0.38), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }
}

struct AllClearRow: View {
    var body: some View {
        HStack(spacing: 13) {
            ZStack {
                RoundedRectangle(cornerRadius: 11, style: .continuous).fill(AOS.green.opacity(0.16))
                Text("✓").font(.system(size: 18)).foregroundStyle(AOS.green)
            }.frame(width: 38, height: 38)
            VStack(alignment: .leading, spacing: 2) {
                Text("All clear").font(.system(size: 14.5, weight: .bold)).foregroundStyle(AOS.text)
                Text("No decisions pending. Keep making.").font(.system(size: 12.5)).foregroundStyle(AOS.muted)
            }
            Spacer(minLength: 0)
        }
        .padding(AOS.Space.md)
        .background(AOS.green.opacity(0.08), in: RoundedRectangle(cornerRadius: AOS.Radius.card, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: AOS.Radius.card, style: .continuous).strokeBorder(AOS.green.opacity(0.24), lineWidth: 1))
    }
}

struct HappenedRow: View {
    let event: MobileEvent
    var body: some View {
        HStack(alignment: .top, spacing: 11) {
            Circle().fill(AOS.green).frame(width: 7, height: 7).padding(.top, 6)
                .shadow(color: AOS.green.opacity(0.6), radius: 4)
            VStack(alignment: .leading, spacing: 3) {
                Text(event.summary).font(.system(size: 13.5)).foregroundStyle(AOS.text).lineLimit(2)
                HStack(spacing: 7) {
                    if let s = event.songTitle {
                        Text(s).font(.system(size: 11, weight: .bold)).foregroundStyle(AOS.gold)
                    }
                    Text(event.at.agoShort).font(.system(size: 11)).foregroundStyle(AOS.muted)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 13).padding(.vertical, 12)
        .background(AOS.panel, in: RoundedRectangle(cornerRadius: AOS.Radius.tile, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: AOS.Radius.tile, style: .continuous).strokeBorder(AOS.line, lineWidth: 1))
    }
}

struct MotionRow: View {
    let song: MobileSong
    var body: some View {
        Button {} label: {
            HStack(spacing: 11) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(song.title).font(.system(size: 16, weight: .bold)).tracking(-0.2)
                        .foregroundStyle(AOS.text).lineLimit(1)
                    Text(metaLine).font(.system(size: 12)).foregroundStyle(AOS.muted).lineLimit(1)
                }
                Spacer(minLength: 0)
                Text(song.lastTouch.agoShort).font(.system(size: 11)).foregroundStyle(AOS.muted)
            }
            .padding(AOS.Space.md)
            .background(AOS.panel, in: RoundedRectangle(cornerRadius: AOS.Radius.card, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: AOS.Radius.card, style: .continuous).strokeBorder(AOS.line, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
    private var metaLine: String {
        var parts = [song.status]
        if song.versionCount >= 2 { parts.append("\(song.versionCount) versions") }
        if let b = song.bpm { parts.append("\(b) BPM") }
        if let k = song.key { parts.append(k) }
        return parts.joined(separator: " · ")
    }
}

// MARK: - persistent capture bar

struct CaptureBar: View {
    var onTap: () -> Void
    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 10) {
                ZStack {
                    Circle().fill(AOS.gold)
                    Image(systemName: "mic.fill").font(.system(size: 15, weight: .bold)).foregroundStyle(Color(hex: 0x14100A))
                }.frame(width: 34, height: 34)
                Text("Capture an idea").font(.system(size: 15, weight: .bold)).foregroundStyle(AOS.text)
                Spacer()
                Image(systemName: "plus").font(.system(size: 15, weight: .bold)).foregroundStyle(AOS.muted)
            }
            .padding(.horizontal, AOS.Space.md).padding(.vertical, 12)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(AOS.gold.opacity(0.35), lineWidth: 1))
            .shadow(color: .black.opacity(0.4), radius: 16, y: 6)
        }
        .buttonStyle(.plain)
        .padding(.horizontal, AOS.Space.lg)
        .padding(.bottom, 8)
    }
}
