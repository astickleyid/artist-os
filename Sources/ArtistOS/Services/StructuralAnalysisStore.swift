import Foundation
import ArtistOSCore

/// On-demand structural segmentation cache for local A/B listening.
///
/// Results are derived analysis only. They are intentionally not persisted as
/// catalog truth and never mutate Master Composition, Events, or Decisions.
actor StructuralAnalysisStore {
    static let shared = StructuralAnalysisStore()

    private var cache: [UUID: Segmentation.Result] = [:]
    private var failed: Set<UUID> = []

    func result(for asset: Asset) async -> Segmentation.Result? {
        if let cached = cache[asset.id] { return cached }
        if failed.contains(asset.id) { return nil }
        guard let url = AssetFileResolver.url(for: asset) else {
            failed.insert(asset.id)
            return nil
        }

        let didAccess = url.startAccessingSecurityScopedResource()
        defer { if didAccess { url.stopAccessingSecurityScopedResource() } }

        // Structural analysis needs the full arrangement rather than the 45-second
        // center excerpt used for BPM/key analysis. The decoded mono buffer remains
        // substantially smaller than typical multichannel source files.
        guard let audio = await AudioAnalysis.loadSamples(
            url: url,
            maxBytes: 300 * 1024 * 1024
        ) else {
            failed.insert(asset.id)
            return nil
        }

        let segmentation = await Task.detached(priority: .utility) {
            Segmentation.segment(audio.samples, sampleRate: audio.sampleRate)
        }.value
        cache[asset.id] = segmentation
        return segmentation
    }
}
