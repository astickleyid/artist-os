import Foundation
import CoreServices
import os

extension WatchedFolder {
    /// Bookmark-resolved URL when available, raw path otherwise.
    func resolveURL() -> URL {
        if let bookmark {
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
        return URL(fileURLWithPath: path)
    }
}

/// Thin Swift wrapper over an FSEvents stream (recursive, file-level events).
/// FSEvents is the canonical macOS API for observing folder trees — the same
/// mechanism Dropbox-style sync clients and DAW media managers rely on.
final class FSWatcher {
    private var stream: FSEventStreamRef?
    private let queue = DispatchQueue(label: "com.stickley.artistos.fsevents")
    private let paths: [String]
    private let handler: ([String]) -> Void

    init(paths: [String], handler: @escaping ([String]) -> Void) {
        self.paths = paths
        self.handler = handler
    }

    func start() {
        guard stream == nil, !paths.isEmpty else { return }

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )

        let callback: FSEventStreamCallback = { _, info, numEvents, eventPaths, _, _ in
            guard let info, numEvents > 0 else { return }
            let watcher = Unmanaged<FSWatcher>.fromOpaque(info).takeUnretainedValue()
            let array = Unmanaged<NSArray>.fromOpaque(eventPaths).takeUnretainedValue()
            let changed = (array as? [String]) ?? []
            watcher.handler(changed)
        }

        stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            callback,
            &context,
            paths as CFArray,
            FSEventStreamEventId(UInt64.max), // kFSEventStreamEventIdSinceNow
            2.0,
            FSEventStreamCreateFlags(
                kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents
            )
        )

        guard let stream else { return }
        FSEventStreamSetDispatchQueue(stream, queue)
        FSEventStreamStart(stream)
    }

    func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    deinit {
        stop()
    }
}

/// Manages the active FSEvents stream over all watched folders and keeps
/// security-scoped access open while watching.
@MainActor
final class FolderWatchService {
    private var watcher: FSWatcher?
    private var accessedURLs: [URL] = []
    private let logger = Logger(subsystem: "com.stickley.artistos", category: "FolderWatch")

    /// Called on the main actor with a batch of changed file paths.
    var onChanges: (([String]) -> Void)?

    func update(folders: [WatchedFolder]) {
        stop()
        guard !folders.isEmpty else { return }

        var watchPaths: [String] = []
        for folder in folders {
            let url = folder.resolveURL()
            if url.startAccessingSecurityScopedResource() {
                accessedURLs.append(url)
            }
            if FileManager.default.fileExists(atPath: url.path) {
                watchPaths.append(url.path)
            } else {
                logger.warning("Watched folder missing on disk: \(folder.path)")
            }
        }
        guard !watchPaths.isEmpty else { return }

        let newWatcher = FSWatcher(paths: watchPaths) { [weak self] paths in
            Task { @MainActor in
                self?.onChanges?(paths)
            }
        }
        newWatcher.start()
        watcher = newWatcher
        logger.info("Watching \(watchPaths.count) folder(s) for creative activity.")
    }

    func stop() {
        watcher?.stop()
        watcher = nil
        for url in accessedURLs {
            url.stopAccessingSecurityScopedResource()
        }
        accessedURLs = []
    }
}
