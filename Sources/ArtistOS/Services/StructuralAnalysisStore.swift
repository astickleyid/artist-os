import Foundation
import ArtistOSCore

/// On-demand structural segmentation cache for local A/B listening.
///
/// Successful results are cached for the app session because Assets are immutable.
/// Failures are intentionally not cached: local file availability can recover after
/// an external drive reconnects, a security-scoped bookmark becomes accessible, or
/// the user restores a missing file. Derived analysis must be able to retry without
/// requiring an Artist OS relaunch.
actor StructuralAnalysisStore {
    static let shared = StructuralAnalysisStore()

    private var cache: [UUID: Segmentation.Result] = [:]

    func result(for asset: Asset) async -> Segmentation.Result? {
        if let cached = cache[asset.id] { return cached }
        guard let url = AssetFileResolver.url(for: asset) else { return nil }

        let didAccess = url.startAccessingSecurityScopedResource()
        defer { if didAccess { url.stopAccessingSecurityScopedResource() } }

        // Structural analysis needs the full arrangement rather than the 45-second
        // center excerpt used for BPM/key analysis. The decoded mono buffer remains
        // substantially smaller than typical multichannel source files.
        guard let audio = await AudioAnalysis.loadSamples(
            url: url,
            maxBytes: 300 * 1024 * 1024
        ) else { return nil }

        let segmentation = await Task.detached(priority: .utility) {
            Segmentation.segment(audio.samples, sampleRate: audio.sampleRate)
        }.value
        cache[asset.id] = segmentation
        return segmentation
    }
}
