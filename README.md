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
- Current Master Composition board
- Creative Change Log
- Inspector panel
- Command/search bar
- Mock catalog model
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

## Next build targets

1. Local folder import flow.
2. Persistent SQLite/GRDB catalog.
3. Native audio preview using AVFoundation.
4. Asset hover/inspector metadata.
5. Editable Master Composition slots.
6. Event creation and observed-change logging.
