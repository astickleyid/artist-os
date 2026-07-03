import Foundation
import AVFoundation
import os

/// Single-player audio preview (Splice/DAW-browser convention: one active
/// preview at a time, toggled from asset rows and the inspector).
@MainActor
final class AudioPreviewService: ObservableObject {
    @Published private(set) var playingAssetID: UUID?
    @Published private(set) var isPlaying = false
    @Published private(set) var currentTime: Double = 0
    @Published private(set) var duration: Double = 0

    private var player: AVPlayer?
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var accessedURL: URL?
    private let logger = Logger(subsystem: "com.stickley.artistos", category: "AudioPreview")

    func canPlay(_ asset: Asset) -> Bool {
        asset.localURLBookmark != nil || asset.sourcePath != nil
    }

    func toggle(asset: Asset) {
        if playingAssetID == asset.id {
            if isPlaying { pause() } else { resume() }
            return
        }
        play(asset: asset)
    }

    func play(asset: Asset, from startTime: Double = 0) {
        stop()
        guard let url = AssetFileResolver.url(for: asset) else {
            logger.error("No playable source for asset \(asset.originalFilename)")
            return
        }
        if url.startAccessingSecurityScopedResource() {
            accessedURL = url
        }

        let item = AVPlayerItem(url: url)
        let newPlayer = AVPlayer(playerItem: item)
        player = newPlayer
        playingAssetID = asset.id
        duration = asset.duration ?? 0
        currentTime = 0

        timeObserver = newPlayer.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.25, preferredTimescale: 600),
            queue: .main
        ) { [weak self] time in
            guard let self else { return }
            Task { @MainActor in
                self.currentTime = time.seconds
                if self.duration == 0,
                   let itemDuration = self.player?.currentItem?.duration.seconds,
                   itemDuration.isFinite {
                    self.duration = itemDuration
                }
            }
        }

        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.stop()
            }
        }

        if startTime > 0 {
            let target = CMTime(seconds: startTime, preferredTimescale: 600)
            newPlayer.seek(to: target)
            currentTime = startTime
        }

        newPlayer.play()
        isPlaying = true
    }

    /// Scrub to a 0...1 position. Starts playback from that point if this
    /// asset isn't already the active preview.
    func seek(asset: Asset, toFraction fraction: Double) {
        let clamped = min(max(fraction, 0), 1)
        if playingAssetID == asset.id {
            let total = duration > 0 ? duration : (asset.duration ?? 0)
            guard total > 0 else { return }
            let target = clamped * total
            player?.seek(to: CMTime(seconds: target, preferredTimescale: 600))
            currentTime = target
            if !isPlaying { resume() }
        } else {
            play(asset: asset, from: clamped * (asset.duration ?? 0))
        }
    }

    /// A/B comparison switch: swap the source while holding the playhead
    /// position, so candidates are judged at the same moment in the song.
    func switchPreview(to asset: Asset) {
        guard playingAssetID != asset.id else { return }
        let position = currentTime
        let wasPlaying = isPlaying
        play(asset: asset, from: position)
        if !wasPlaying { pause() }
    }

    func pause() {
        player?.pause()
        isPlaying = false
    }

    func resume() {
        player?.play()
        isPlaying = true
    }

    func stop() {
        if let timeObserver, let player {
            player.removeTimeObserver(timeObserver)
        }
        timeObserver = nil
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
        }
        endObserver = nil
        player?.pause()
        player = nil
        accessedURL?.stopAccessingSecurityScopedResource()
        accessedURL = nil
        playingAssetID = nil
        isPlaying = false
        currentTime = 0
        duration = 0
    }
}
