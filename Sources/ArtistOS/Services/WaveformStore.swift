import Foundation
import ArtistOSCore
import AVFoundation
import CoreMedia
import SwiftUI

/// Resolves an asset back to a local file URL: security-scoped bookmark first,
/// raw path as fallback.
enum AssetFileResolver {
    static func url(for asset: Asset) -> URL? {
        if let bookmark = asset.localURLBookmark {
            var isStale = false
            if let url = try? URL(
                resolvingBookmarkData: bookmark,
                options: [.withSecurityScope],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            ) {
                return url
            }
        }
        if let path = asset.sourcePath, FileManager.default.fileExists(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        return nil
    }
}

/// Computes and caches downsampled waveform peaks (0...1) per asset.
actor WaveformStore {
    static let shared = WaveformStore()

    private var cache: [UUID: [Float]] = [:]
    private var failed: Set<UUID> = []

    func peaks(for asset: Asset, buckets: Int = 96) async -> [Float]? {
        if let cached = cache[asset.id] { return cached }
        if failed.contains(asset.id) { return nil }
        guard let url = AssetFileResolver.url(for: asset) else {
            failed.insert(asset.id)
            return nil
        }
        let didAccess = url.startAccessingSecurityScopedResource()
        defer { if didAccess { url.stopAccessingSecurityScopedResource() } }

        if let peaks = await Self.computePeaks(url: url, buckets: buckets) {
            cache[asset.id] = peaks
            return peaks
        }
        failed.insert(asset.id)
        return nil
    }

    private static func computePeaks(url: URL, buckets: Int) async -> [Float]? {
        let avAsset = AVURLAsset(url: url)
        guard let track = try? await avAsset.loadTracks(withMediaType: .audio).first,
              let cmDuration = try? await avAsset.load(.duration),
              cmDuration.seconds.isFinite, cmDuration.seconds > 0
        else { return nil }

        var sampleRate: Double = 44_100
        var channelCount: Double = 2
        if let descriptions = try? await track.load(.formatDescriptions),
           let description = descriptions.first,
           let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(description) {
            sampleRate = asbd.pointee.mSampleRate
            channelCount = Double(max(1, asbd.pointee.mChannelsPerFrame))
        }

        guard let reader = try? AVAssetReader(asset: avAsset) else { return nil }
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { return nil }
        reader.add(output)
        guard reader.startReading() else { return nil }

        let estimatedTotalSamples = max(1.0, cmDuration.seconds * sampleRate * channelCount)
        let samplesPerBucket = max(1, Int(estimatedTotalSamples / Double(buckets)))

        var peaks = [Float](repeating: 0, count: buckets)
        var sampleIndex = 0

        while reader.status == .reading, let sampleBuffer = output.copyNextSampleBuffer() {
            guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { continue }
            let length = CMBlockBufferGetDataLength(blockBuffer)
            guard length > 0 else { continue }
            var data = Data(count: length)
            let status = data.withUnsafeMutableBytes { pointer -> OSStatus in
                guard let base = pointer.baseAddress else { return -1 }
                return CMBlockBufferCopyDataBytes(
                    blockBuffer, atOffset: 0, dataLength: length, destination: base
                )
            }
            guard status == kCMBlockBufferNoErr else { continue }

            data.withUnsafeBytes { raw in
                for sample in raw.bindMemory(to: Int16.self) {
                    let bucket = min(buckets - 1, sampleIndex / samplesPerBucket)
                    let amplitude = Float(abs(Int(sample))) / Float(Int16.max)
                    if amplitude > peaks[bucket] {
                        peaks[bucket] = amplitude
                    }
                    sampleIndex += 1
                }
            }
        }

        guard sampleIndex > 0 else { return nil }
        let maxPeak = peaks.max() ?? 1
        if maxPeak > 0 {
            peaks = peaks.map { $0 / maxPeak }
        }
        return peaks
    }
}

/// Compact bar waveform (Splice-browser style). Shows a subtle placeholder
/// while loading or when no local file is linked.
struct WaveformView: View {
    let asset: Asset
    var tint: Color = AOSTheme.gold

    @State private var peaks: [Float]?

    var body: some View {
        Group {
            if let peaks, !peaks.isEmpty {
                Canvas { context, size in
                    let count = peaks.count
                    let barWidth = size.width / CGFloat(count)
                    for (index, peak) in peaks.enumerated() {
                        let height = max(1.5, CGFloat(peak) * size.height)
                        let rect = CGRect(
                            x: CGFloat(index) * barWidth + barWidth * 0.15,
                            y: (size.height - height) / 2,
                            width: barWidth * 0.7,
                            height: height
                        )
                        context.fill(
                            Path(roundedRect: rect, cornerRadius: barWidth * 0.3),
                            with: .color(tint.opacity(0.85))
                        )
                    }
                }
            } else {
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.white.opacity(0.045))
            }
        }
        .task(id: asset.id) {
            peaks = await WaveformStore.shared.peaks(for: asset)
        }
    }
}
