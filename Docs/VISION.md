# Artist OS — Vision & Canonical Logic Spec

## Why this exists
Artists drown in versions, bounces, takes, and unfinished ideas. Every tool
makes the artist do the filing. Artist OS inverts it.

## The one rule
**The artist never becomes a project manager.** The app organizes around
observed creative work. The app proposes; the artist approves.

## Primitives
Song (living object) · Master Composition (structural source of truth) ·
Asset (real file, optionally a version in a stack) · Creative Event
(target + operation record, attributed You / Observed).

## Intelligence layers (build order)
1. **Filename intelligence** — canonical titles, version stacks, role inference. ✅ web ✅ macOS
2. **Decision engine** — D1: ≥2 competing takes of a decisive role (hook,
   bridge, lead vocal) escalate the matching unlocked slot to Needs Decision
   (escalate-only, fires once). D2: a stack of ≥2 **full-mix** versions
   requires a pinned master; a newer version than the pinned master reopens
   the question. Surfaced as a Decide inbox; resolved by A/B. ✅ web ✅ macOS
3. **Audio intelligence** — BPM/key detection feeding stacks and DNA. ⏳
4. **Creative DNA** — cross-song patterns once history accumulates. ⏳
5. **Recap** — periodic creative journal generated from events. ⏳

## Canonical logic (both platforms MUST match; vectors in tests)
- Version tokens: v#, (#), final, master, mix#, take#, bounce, draft, rough,
  demo, edit, copy, alt, rev — stripped iteratively from filename tails,
  including version-bearing parentheticals. Role words are never version tokens.
  Short/numeric bases are never over-stripped.
- Grouping: subfolder ⇒ song; loose files ⇒ canonical title.
- Stack order: vOrder desc → file mtime desc → import time desc. Top = Latest.
- Master stack = full-mix versions only.
- Dedup: content hash (size + head/tail SHA-256 on web; streaming SHA-256 native).
- Auto events are attributed Observed and never downgrade artist decisions.

## Platform roles
- **macOS native**: the workstation. True FSEvents watching, deep catalog.
- **Web (local-first)**: distribution + capture surface; blueprint for the
  iPhone companion. No backend; audio never leaves the device.
- **Sync (deferred, next decision)**: CloudKit vs. Cloudflare stack — owner call.

## Deferred by design
Batch render engine · DSP variants · collaboration · predictive modeling.
