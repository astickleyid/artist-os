import SwiftUI
import AppKit
import AVFoundation
import ArtistOSCore

/// Quick Swipe Comp — swipe across stacked version lanes to build one master
/// from the best parts of every version. Mirrors the web Comp tab.
struct CompView: View {
    let song: Song
    @EnvironmentObject var state: AppState
    @StateObject private var player = CompAudioPlayer()

    @State private var comp: Comp.Model?
    @State private var versions: [CompSource] = []
    @State private var loaded = false
    @State private var loudness = false
    @State private var rendering = false
    @State private var status = ""

    struct CompSource: Identifiable {
        let id: String
        let asset: Asset
        let label: String
        let color: Color
        var url: URL?
    }

    private let palette: [Color] = [
        AOSTheme.gold, AOSTheme.blue, AOSTheme.green,
        Color(red: 0.91, green: 0.47, blue: 0.54),
        Color(red: 0.71, green: 0.55, blue: 1.0)
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if versions.count < 2 {
                emptyState
            } else {
                intro
                compStrip
                lanes
                transport
                actions
                if !status.isEmpty {
                    Text(status).font(.caption).foregroundStyle(AOSTheme.muted)
                }
            }
        }
        .onAppear(perform: setup)
        .onDisappear { player.teardown() }
    }

    // MARK: setup

    private func setup() {
        guard !loaded else { return }
        loaded = true
        let stack = VersionIntelligence.masterStack(state.catalog.assets.filter { $0.songID == song.id })
        versions = stack.enumerated().compactMap { (i, a) in
            guard let url = AssetFileResolver.url(for: a) else { return nil }
            return CompSource(id: "cv\(i)", asset: a, label: a.version ?? a.title,
                              color: palette[i % palette.count], url: url)
        }
        guard versions.count >= 2 else { return }
        player.load(versions.map { (id: $0.id, url: $0.url!) })
        comp = Comp.makeComp(duration: player.duration, defaultSourceId: versions[0].id)
    }

    // MARK: pieces

    private var intro: some View {
        Text("Swipe across a version to make it the source for that stretch of the song — verse from one take, hook from another. Playback flips instantly at the same spot, no gap.")
            .font(.caption).foregroundStyle(AOSTheme.muted).fixedSize(horizontal: false, vertical: true)
    }

    private var compStrip: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("YOUR COMP").font(.system(size: 10, weight: .black)).tracking(1).foregroundStyle(AOSTheme.gold)
            GeometryReader { geo in
                HStack(spacing: 0) {
                    if let comp, comp.duration > 0 {
                        ForEach(Array(comp.segments.enumerated()), id: \.offset) { _, seg in
                            let w = CGFloat((seg.end - seg.start) / comp.duration) * geo.size.width
                            let v = versions.first { $0.id == seg.sourceId } ?? versions[0]
                            Rectangle().fill(v.color)
                                .frame(width: max(0, w))
                                .overlay(w > 34 ? Text(v.label).font(.system(size: 9, weight: .bold)).foregroundStyle(.black.opacity(0.8)) : nil)
                        }
                    }
                }
            }
            .frame(height: 34).clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(AOSTheme.line))
        }
    }

    private var lanes: some View {
        GeometryReader { geo in
            VStack(spacing: 0) {
                ForEach(versions) { v in
                    CompLane(source: v, comp: comp, player: player,
                             onSwipe: { from, to in applySwipe(v.id, from, to) },
                             width: geo.size.width)
                }
            }
            .overlay(alignment: .leading) {
                if player.isPlaying, player.duration > 0 {
                    Rectangle().fill(AOSTheme.gold).frame(width: 2)
                        .offset(x: CGFloat(player.position / player.duration) * geo.size.width)
                        .shadow(color: AOSTheme.gold, radius: 4)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(AOSTheme.line))
        }
        .frame(height: CGFloat(versions.count) * 76)
    }

    private var transport: some View {
        HStack(spacing: 12) {
            Button(action: togglePlay) {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 16, weight: .bold)).foregroundStyle(.black)
                    .frame(width: 44, height: 44).background(AOSTheme.gold, in: Circle())
            }.buttonStyle(.plain)
            Text("\(fmt(player.position)) / \(fmt(player.duration))")
                .font(.system(size: 12, design: .monospaced)).foregroundStyle(AOSTheme.muted)
            Spacer()
            Button {
                loudness.toggle(); player.setLoudness(loudness)
            } label: {
                Text(loudness ? "✓ Match loudness" : "Match loudness")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(loudness ? AOSTheme.gold : AOSTheme.muted)
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(RoundedRectangle(cornerRadius: 10).strokeBorder(loudness ? AOSTheme.gold.opacity(0.5) : AOSTheme.line))
            }.buttonStyle(.plain)
        }
    }

    private var actions: some View {
        HStack(spacing: 9) {
            Button("Reset") {
                if let c = comp { comp = Comp.makeComp(duration: c.duration, defaultSourceId: versions[0].id)
                    if player.isPlaying, let comp { player.reschedule(comp: comp) } }
            }.buttonStyle(.plain).padding(.horizontal, 14).padding(.vertical, 10)
             .background(RoundedRectangle(cornerRadius: 10).strokeBorder(AOSTheme.line)).foregroundStyle(AOSTheme.text)
            Button(action: render) {
                Text(rendering ? "Rendering…" : "⬇ Render comp").font(.system(size: 13, weight: .bold)).foregroundStyle(.black)
                    .frame(maxWidth: .infinity).padding(.vertical, 11).background(AOSTheme.gold, in: RoundedRectangle(cornerRadius: 10))
            }.buttonStyle(.plain).disabled(rendering)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "waveform.path").font(.largeTitle).foregroundStyle(AOSTheme.muted)
            Text("Need at least two versions").font(.headline).foregroundStyle(AOSTheme.text)
            Text("Import another mix or bounce of “\(song.title)” to swipe-comp between them.")
                .font(.caption).foregroundStyle(AOSTheme.muted).multilineTextAlignment(.center)
        }.frame(maxWidth: .infinity).padding(40)
    }

    // MARK: actions

    private func applySwipe(_ sourceId: String, _ from: Double, _ to: Double) {
        guard let c = comp else { return }
        comp = Comp.applySwipe(c, sourceId: sourceId, from: from, to: to)
        if player.isPlaying, let comp { player.reschedule(comp: comp) }
    }

    private func togglePlay() {
        guard let comp else { return }
        if player.isPlaying { player.stop() } else { player.play(comp: comp, from: player.position) }
    }

    private func render() {
        guard let comp else { return }
        rendering = true; status = "Rendering on-device…"
        Task {
            do {
                let url = try await CompRenderer.render(comp: comp,
                    sources: versions.compactMap { v in v.url.map { (id: v.id, url: $0) } },
                    loudness: loudness, songTitle: song.title)
                await MainActor.run {
                    rendering = false
                    status = "Rendered → \(url.lastPathComponent)"
                    state.recordComp(songID: song.id, sources: Comp.sourcesUsed(comp), segments: comp.segments.count)
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }
            } catch {
                await MainActor.run { rendering = false; status = "Render failed: \(error.localizedDescription)" }
            }
        }
    }

    private func fmt(_ t: Double) -> String {
        let s = Int(t.rounded()); return String(format: "%d:%02d", s / 60, s % 60)
    }
}

/// One version lane: waveform + active-region highlight + swipe gesture.
struct CompLane: View {
    let source: CompView.CompSource
    let comp: Comp.Model?
    @ObservedObject var player: CompAudioPlayer
    let onSwipe: (Double, Double) -> Void
    let width: CGFloat

    @State private var samples: [Float] = []

    var body: some View {
        ZStack(alignment: .topLeading) {
            WaveShape(samples: samples)
                .stroke(source.color.opacity(isActive ? 0.9 : 0.4), lineWidth: 1)
                .background(Color.black.opacity(0.15))
            // active regions
            if let comp, comp.duration > 0 {
                ForEach(Array(comp.segments.enumerated()), id: \.offset) { _, seg in
                    if seg.sourceId == source.id {
                        Rectangle().fill(source.color.opacity(0.16))
                            .frame(width: CGFloat((seg.end - seg.start) / comp.duration) * width)
                            .offset(x: CGFloat(seg.start / comp.duration) * width)
                    }
                }
            }
            HStack(spacing: 6) {
                Circle().fill(source.color).frame(width: 9, height: 9)
                Text(source.label).font(.system(size: 11, weight: .bold)).foregroundStyle(AOSTheme.text)
                if let bpm = source.asset.bpm { Text("\(Int(bpm)) BPM").font(.system(size: 10)).foregroundStyle(AOSTheme.muted) }
            }.padding(6)
        }
        .frame(height: 76)
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 4).onEnded { g in
            guard let comp, comp.duration > 0, width > 0 else { return }
            let a = max(0, min(comp.duration, Double(g.startLocation.x / width) * comp.duration))
            let b = max(0, min(comp.duration, Double(g.location.x / width) * comp.duration))
            onSwipe(a, b)
        })
        .task { await loadWave() }
    }

    private var isActive: Bool {
        guard let comp else { return false }
        return comp.segments.contains { $0.sourceId == source.id }
    }

    private func loadWave() async {
        guard samples.isEmpty, let url = source.url else { return }
        let peaks = await Task.detached { () -> [Float] in
            guard let file = try? AVAudioFile(forReading: url) else { return [] }
            let fmt = file.processingFormat
            let total = AVAudioFrameCount(file.length)
            guard total > 0, let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: total) else { return [] }
            try? file.read(into: buf)
            guard let ch = buf.floatChannelData?[0] else { return [] }
            let n = Int(buf.frameLength); let cols = 400; let step = max(1, n / cols)
            var out: [Float] = []
            var i = 0
            while i < n { var peak: Float = 0; var j = 0
                while j < step && i + j < n { peak = max(peak, abs(ch[i + j])); j += 1 }
                out.append(peak); i += step
            }
            return out
        }.value
        await MainActor.run { samples = peaks }
    }
}

/// Simple mirrored waveform path from peak samples.
struct WaveShape: Shape {
    let samples: [Float]
    func path(in rect: CGRect) -> Path {
        var p = Path()
        guard !samples.isEmpty else { return p }
        let mid = rect.midY
        let dx = rect.width / CGFloat(samples.count)
        for (i, s) in samples.enumerated() {
            let x = CGFloat(i) * dx
            let h = CGFloat(s) * rect.height * 0.45
            p.move(to: CGPoint(x: x, y: mid - h)); p.addLine(to: CGPoint(x: x, y: mid + h))
        }
        return p
    }
}
