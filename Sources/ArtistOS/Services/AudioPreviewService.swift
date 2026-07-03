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

    func play(asset: Asset) {
        stop()
        guard let url = resolveURL(for: asset) else {
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

        newPlayer.play()
        isPlaying = true
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

    private func resolveURL(for asset: Asset) -> URL? {
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
