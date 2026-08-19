# Artist OS — Vision & Canonical Logic Spec

> Docs/SOURCE-OF-TRUTH.md is the architectural authority. This file is the working logic and implementation-status spec; where they differ, SOURCE-OF-TRUTH wins.

## Why this exists
Artists drown in versions, bounces, takes, and unfinished ideas. Every tool
makes the artist do the filing. Artist OS inverts it.

## The one rule
**The artist never becomes a project manager.** The app organizes around
observed creative work. The app proposes; the artist approves.

## Primitives
Song (living object) · Master Composition (current approved creative blueprint) ·
Asset (immutable evidence/file) · Creative Event (factual WHAT happened) ·
Creative Decision (artist-intent WHY the current state exists).

Versions are derived views over assets + creative history. They are not primary domain objects.

## Intelligence layers (build order)
1. **Filename intelligence** — canonical titles, version stacks, role inference. ✅ web ✅ macOS
2. **Decision engine** — D1: ≥2 competing takes of a decisive role (hook,
   bridge, lead vocal) escalate the matching unlocked slot to Needs Decision
   (escalate-only, fires once). D2: a stack of ≥2 **full-mix** versions
   requires a pinned master; a newer version than the pinned master reopens
   the question. Surfaced as a Decide inbox; resolved by A/B. ✅ web ✅ macOS
3. **Audio intelligence** — BPM/key detection feeding stacks and later DNA. ✅ web ✅ macOS
4. **Master Composition migration** — layered source / processing / automation / comp selections are persisted and the native Master workspace reads/writes the canonical model; legacy Song section fields remain only as compatibility mirrors pending final retirement tests. ✅
5. **Decision history integration** — first-class Decisions are persisted, synced, and wired into approval/structure/state flows so Events remain factual and intent remains separate. ✅
6. **Creative DNA** — cross-song patterns once enough trustworthy history accumulates. ⏳
7. **Recap** — periodic creative journal generated from events + decisions. ⏳

## Canonical logic (platform implementations MUST match; vectors in tests)
- Version tokens: v#, (#), final, master, mix#, take#, bounce, draft, rough,
  demo, edit, copy, alt, rev — stripped iteratively from filename tails,
  including version-bearing parentheticals. Role words are never version tokens.
  Short/numeric bases are never over-stripped.
- Grouping: subfolder ⇒ song; loose files ⇒ canonical title.
- Stack order: vOrder desc → file mtime desc → import time desc. Top = Latest.
- Master stack = full-mix versions only.
- Dedup: content hash (size + head/tail SHA-256 on web; streaming SHA-256 native).
- Auto events are factual/Observed and never downgrade artist decisions.
- Decisions are separate from events: events record WHAT; decisions preserve WHY.
- Master Composition is the only current creative source of truth. Bounces and mixes are assets/output evidence, not the canonical song object.

## Sync (Cloudflare — live, metadata-first)
Architecture per owner decision: one Worker (worker/src/index.js) in front of D1
(metadata) + R2 (opt-in audio).
- **Metadata-first**: Song, Asset, Creative Event, Creative Decision, and Master Composition metadata participate in the canonical native sync contract. Outbound canonical intent is persisted in a GRDB outbox before network delivery and survives relaunch; local domain mutation + outbox insertion still need to become one shared transaction on every mutation path.
- **Audio stays local by default** until a person explicitly chooses to make an
  asset available everywhere — the Frame.io/Splice pattern.
- **Auth**: no passwords. Creating an account issues a bearer token; a second
  device joins the same account via a 6-character, single-use, 5-minute link
  code (`/v1/link/start` + `/v1/link/claim`) — tokens are stored server-side
  as SHA-256 hashes only.
- **Conflict resolution**: last-write-wins by `updatedAt`, per-entity
  (`kind:id`), with a monotonic per-account `seq` cursor for incremental pulls.
  A tie favors the local write made at the same instant.
- **Contract**: worker/schema.sql is the source of truth for the wire shape;
  docs/sync.js (web) and SyncLogic.swift + SyncService.swift (native)
  independently implement the same client contract and are exercised by tests.

## Platform roles
- **macOS native**: primary workstation. True FSEvents watching, deep catalog,
  native playback/preview, Quick Swipe Comp, and the canonical high-fidelity workspace.
- **iPhone companion**: capture, triage, decisions, and synced access to the catalog;
  not a replacement for the workstation.
- **Web**: local-first proving/distribution surface and parity reference for shared logic.
- **Cloudflare sync**: active metadata transport with opt-in audio blobs. It is no longer a deferred architecture decision.

## Current architectural migration order
1. Persist Creative Decisions independently from Creative Events. ✅
2. Establish layered Master Composition as the canonical core model. ✅
3. Persist Master Composition without destroying legacy catalogs. ✅
4. Wire Decisions into A/B, pin-master, and other approval flows. ✅
5. Add Decisions + Master Composition to sync contract and conflict handling. ✅
6. Migrate native macOS workspace to read/write the canonical model. ✅
7. Retire legacy `Song.sections[].assetID` only after migration tests prove existing catalogs are safe. 🚧

## Deferred by design
Batch DSP variant generation · collaboration · predictive career modeling.
These stay behind core catalog truth, version safety, native product quality, and migration correctness.
