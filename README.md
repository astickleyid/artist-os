# Artist OS

Native macOS creative workspace for serious artists.

This repository is now the SwiftUI foundation for Artist OS. The earlier HTML prototype was useful for design exploration, but the production direction is a native macOS app.

## Product thesis

Artist OS organizes **songs**, not files. The artist works from one living song workspace while recordings, revisions, assets, and experiments stay preserved behind the glass.

## Current foundation

- Native SwiftUI application shell
- macOS split-view layout
- Library sidebar
- Song list column
- Song workspace detail
- **Persistent SQLite catalog (GRDB)** — songs, sections, assets, and events survive relaunch
- **Local folder import** — recursive scan, subfolder→song grouping, role inference, audio metadata (duration, sample rate, channels, size) via AVFoundation
- **Native audio preview** — single-active-player AVPlayer previews from master slots, asset grid, and inspector
- **Editable Master Composition** — assign assets to slots, set states, edit notes, add/remove slots; progress and risk recompute automatically
- **Creative event logging** — automatic events for imports and master edits, plus manual Log Change entry (⌘⇧L)
- **Filesystem watcher (FSEvents)** — imported folders are watched; new, changed, and removed audio files generate observed creative events automatically, and new files auto-import into the right song
- **Duplicate detection** — SHA-256 content hashing skips files already in the catalog; imports are cancellable mid-scan
- **Waveform rendering** — downsampled peak waveforms on asset cards and in the inspector
- **Drag-and-drop assignment** — drag any asset card onto a master slot; slots also reorder via Move Up/Down
- **Global Timeline and Assets views** — catalog-wide change feed and searchable asset browser from the sidebar
- Rich asset inspector with playback scrubline and Reveal in Finder
- Sanitized local-only data model; no unreleased audio committed

## Run

```bash
swift run ArtistOS
```

Requires macOS 14+.

## Architecture

```text
Sources/ArtistOS/
├── App/
├── DesignSystem/
├── Features/
│   ├── Inspector/
│   ├── Library/
│   ├── Search/
│   ├── Shell/
│   ├── Song/
│   └── Timeline/
├── Models/
└── Services/
```

## Data

Catalog database lives at `~/Library/Application Support/ArtistOS/catalog.sqlite`. First launch seeds a demo song; imports add real data alongside it.

## Next build targets

1. Waveform scrubbing (click-to-seek on the inspector waveform).
2. A/B comparison mode for Needs Decision slots.
3. Startup reconciliation scan (catch changes that happened while the app was closed).
4. Creative DNA analytics once observed history accumulates.
5. Cloud sync + iPhone companion capture app (deferred per MVP spec).
