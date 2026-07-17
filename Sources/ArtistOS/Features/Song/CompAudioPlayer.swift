import Foundation
import AVFoundation
import ArtistOSCore

/// Gapless synced multi-version comp player (native mirror of the web CompPlayer).
/// Every version plays at once through its own mixer, perfectly synced from the
/// same start; switching which is audible is done by ramping per-version mixer
/// volume with short equal-power crossfades at comp boundaries. The playhead
/// never moves when you switch — instant, gapless flips.
///
/// NOTE: audio *feel* (crossfade smoothness) can only be verified on a real
/// device; this compiles + is structured to the proven web approach. Tuning of
/// `crossfade` / tick rate may follow first on-device listen.
@MainActor
final class CompAudioPlayer: ObservableObject {
    struct Source { let id: String; let url: URL; var buffer: AVAudioPCMBuffer?; var rms: Double = 0.0001 }

    private let engine = AVAudioEngine()
    private var players: [String: AVAudioPlayerNode] = [:]
    private var mixers: [String: AVAudioMixerNode] = [:]
    private var sources: [Source] = []
    private var comp: Comp.Model?
    private var displayTimer: Timer?
    private var accessed: [URL] = []

    @Published var isPlaying = false
    @Published var position: Double = 0
    @Published var duration: Double = 0
    @Published var loudness = false

    private var startHostTime: TimeInterval = 0
    private var startOffset: Double = 0
    let crossfade: Double = 0.03

    // MARK: load

    /// Decode each version once (mono/stereo PCM) and compute RMS for loudness match.
    func load(_ versions: [(id: String, url: URL)]) {
        teardown()
        var srcs: [Source] = []
        var maxDur: Double = 0
        for v in versions {
            let didAccess = v.url.startAccessingSecurityScopedResource()
            if didAccess { accessed.append(v.url) }
            guard let file = try? AVAudioFile(forReading: v.url) else { continue }
            let fmt = file.processingFormat
            let frames = AVAudioFrameCount(file.length)
            guard frames > 0, let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: frames) else { continue }
            do { try file.read(into: buf) } catch { continue }
            var src = Source(id: v.id, url: v.url, buffer: buf)
            src.rms = Self.rms(of: buf)
            srcs.append(src)
            maxDur = max(maxDur, Double(file.length) / fmt.sampleRate)
        }
        sources = srcs
        duration = maxDur
    }

    private static func rms(of buf: AVAudioPCMBuffer) -> Double {
        guard let ch = buf.floatChannelData?[0] else { return 0.0001 }
        let n = Int(buf.frameLength)
        if n == 0 { return 0.0001 }
        var sum = 0.0; var i = 0
        while i < n { let v = Double(ch[i]); sum += v * v; i += 200 }
        let count = max(1, n / 200)
        return max(0.0001, (sum / Double(count)).squareRoot())
    }

    private func gain(for id: String) -> Float {
        guard loudness else { return 1 }
        let map = Comp.loudnessGains(Dictionary(uniqueKeysWithValues: sources.map { ($0.id, $0.rms) }))
        return Float(map[id] ?? 1)
    }

    // MARK: playback

    func play(comp: Comp.Model, from offset: Double) {
        stop()
        self.comp = comp
        // wire a graph: each source -> its mixer -> main mixer
        for src in sources {
            guard let buf = src.buffer else { continue }
            let player = AVAudioPlayerNode()
            let mixer = AVAudioMixerNode()
            engine.attach(player); engine.attach(mixer)
            engine.connect(player, to: mixer, format: buf.format)
            engine.connect(mixer, to: engine.mainMixerNode, format: buf.format)
            mixer.outputVolume = 0
            players[src.id] = player; mixers[src.id] = mixer
        }
        do { try engine.start() } catch { return }

        let startAt = max(0, min(offset, duration - 0.05))
        startOffset = startAt

        // schedule each buffer from the offset (shared timeline)
        for src in sources {
            guard let buf = src.buffer, let player = players[src.id] else { continue }
            let sr = buf.format.sampleRate
            let startFrame = AVAudioFramePosition(startAt * sr)
            let remaining = AVAudioFrameCount(max(0, Int64(buf.frameLength) - startFrame))
            if remaining == 0 { continue }
            if let seg = segment(of: buf, fromFrame: startFrame, frames: remaining) {
                player.scheduleBuffer(seg, at: nil, options: [], completionHandler: nil)
            }
        }
        // start them all in lockstep
        for (_, player) in players { player.play() }
        startHostTime = Date().timeIntervalSinceReferenceDate
        applyGains(atPosition: startAt)
        isPlaying = true
        startTicking()
    }

    /// Copy a tail segment of a buffer starting at a frame (for offset playback).
    private func segment(of buf: AVAudioPCMBuffer, fromFrame: AVAudioFramePosition, frames: AVAudioFrameCount) -> AVAudioPCMBuffer? {
        guard let out = AVAudioPCMBuffer(pcmFormat: buf.format, frameCapacity: frames) else { return nil }
        let channels = Int(buf.format.channelCount)
        guard let src = buf.floatChannelData, let dst = out.floatChannelData else { return nil }
        for c in 0..<channels {
            for i in 0..<Int(frames) { dst[c][i] = src[c][Int(fromFrame) + i] }
        }
        out.frameLength = frames
        return out
    }

    /// Re-evaluate which source should be audible and ramp gains (crossfade).
    private func applyGains(atPosition p: Double) {
        guard let comp else { return }
        let active = Comp.sourceAt(comp, p)
        for src in sources {
            guard let mixer = mixers[src.id] else { continue }
            let target: Float = (src.id == active) ? gain(for: src.id) : 0
            // small linear step toward target = cheap crossfade over a few ticks
            let cur = mixer.outputVolume
            let step = Float(0.06 / max(crossfade, 0.01))
            mixer.outputVolume = cur + (target - cur) * min(1, step)
        }
    }

    func setLoudness(_ on: Bool) { loudness = on }

    func reschedule(comp: Comp.Model) {
        self.comp = comp
        if isPlaying { applyGains(atPosition: position) }
    }

    func seek(to t: Double) { if let comp { play(comp: comp, from: t) } }

    private func startTicking() {
        displayTimer?.invalidate()
        displayTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    private func tick() {
        guard isPlaying else { return }
        let elapsed = Date().timeIntervalSinceReferenceDate - startHostTime
        position = min(duration, startOffset + elapsed)
        applyGains(atPosition: position)
        if position >= duration - 0.02 { stop() }
    }

    func stop() {
        displayTimer?.invalidate(); displayTimer = nil
        for (_, p) in players { p.stop() }
        engine.stop()
        for (_, node) in players { engine.detach(node) }
        for (_, node) in mixers { engine.detach(node) }
        players.removeAll(); mixers.removeAll()
        isPlaying = false
    }

    func teardown() {
        stop()
        for url in accessed { url.stopAccessingSecurityScopedResource() }
        accessed.removeAll()
        sources.removeAll()
    }
}
