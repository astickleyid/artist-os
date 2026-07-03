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

1. Import cancellation + duplicate-file detection (hash-based).
2. Waveform rendering in asset rows.
3. Drag-and-drop asset assignment onto master slots.
4. Section reordering in the Master Composition board.
5. Filesystem watcher for observed-change detection (auto events).
6. Timeline and Assets navigation views (sidebar items currently inert).
