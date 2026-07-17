import Foundation
import AVFoundation
import ArtistOSCore

/// Offline render of a comp to a WAV file. Copies each segment's samples on the
/// shared timeline, equal-power crossfade at boundaries, optional loudness
/// match. Deterministic (mirrors the web renderComp). Writes to a temp file and
/// returns its URL.
enum CompRenderer {
    struct RenderError: LocalizedError { let msg: String; var errorDescription: String? { msg } }

    static func render(comp: Comp.Model,
                       sources: [(id: String, url: URL)],
                       loudness: Bool,
                       songTitle: String) async throws -> URL {
        try await Task.detached(priority: .userInitiated) {
            let outSR = 44100.0
            let xf = 0.03

            // decode each used source
            let used = Set(comp.segments.map { $0.sourceId })
            var buffers: [String: AVAudioPCMBuffer] = [:]
            var rms: [String: Double] = [:]
            for s in sources where used.contains(s.id) {
                let didAccess = s.url.startAccessingSecurityScopedResource()
                defer { if didAccess { s.url.stopAccessingSecurityScopedResource() } }
                guard let file = try? AVAudioFile(forReading: s.url) else { continue }
                let fmt = file.processingFormat
                guard let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(file.length)) else { continue }
                try file.read(into: buf)
                buffers[s.id] = buf
                rms[s.id] = rmsOf(buf)
            }
            guard !buffers.isEmpty else { throw RenderError(msg: "No audio to render.") }

            let gains = loudness ? Comp.loudnessGains(rms) : [:]
            func gain(_ id: String) -> Float { loudness ? Float(gains[id] ?? 1) : 1 }

            let outFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: outSR, channels: 2, interleaved: false)!
            let totalFrames = AVAudioFrameCount(max(1, Int(comp.duration * outSR)))
            guard let out = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: totalFrames) else {
                throw RenderError(msg: "Could not allocate output.")
            }
            out.frameLength = totalFrames
            let outL = out.floatChannelData![0], outR = out.floatChannelData![1]
            let xfFrames = Int(xf * outSR)

            for (idx, seg) in comp.segments.enumerated() {
                guard let buf = buffers[seg.sourceId] else { continue }
                let inSR = buf.format.sampleRate
                let ch = buf.floatChannelData!
                let chCount = Int(buf.format.channelCount)
                let g = gain(seg.sourceId)
                let step = inSR / outSR
                let startFrame = Int(seg.start * outSR)
                let endFrame = min(Int(comp.duration * outSR), Int(seg.end * outSR))
                var o = startFrame
                while o < endFrame && o < Int(totalFrames) {
                    let srcIdx = Int(Double(o) * step)
                    if srcIdx >= Int(buf.frameLength) { break }
                    let l = ch[0][srcIdx] * g
                    let r = (chCount > 1 ? ch[1][srcIdx] : ch[0][srcIdx]) * g
                    let rel = o - startFrame
                    if idx > 0 && rel < xfFrames {
                        let t = Float(rel) / Float(xfFrames)
                        let gin = sinf(t * .pi / 2), gout = cosf(t * .pi / 2)
                        outL[o] = outL[o] * gout + l * gin
                        outR[o] = outR[o] * gout + r * gin
                    } else {
                        outL[o] = l; outR[o] = r
                    }
                    o += 1
                }
            }

            let safe = songTitle.replacingOccurrences(of: "[^A-Za-z0-9]+", with: "-", options: .regularExpression).lowercased()
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(safe.isEmpty ? "comp" : safe)-comp.wav")
            let outFile = try AVAudioFile(forWriting: url, settings: outFormat.settings,
                                          commonFormat: .pcmFormatFloat32, interleaved: false)
            try outFile.write(from: out)
            return url
        }.value
    }

    private static func rmsOf(_ buf: AVAudioPCMBuffer) -> Double {
        guard let ch = buf.floatChannelData?[0] else { return 0.0001 }
        let n = Int(buf.frameLength); if n == 0 { return 0.0001 }
        var sum = 0.0; var i = 0
        while i < n { let v = Double(ch[i]); sum += v * v; i += 200 }
        return max(0.0001, (sum / Double(max(1, n / 200))).squareRoot())
    }
}
