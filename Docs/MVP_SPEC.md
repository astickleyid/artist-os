# Artist OS MVP Spec

## Core premise

Artist OS is a native macOS creative workspace for artists who have too many versions, files, bounces, recordings, and unfinished ideas to manage manually.

## MVP rule

The artist should not become a project manager. The app must organize around observed creative work, not manual bookkeeping.

## Primary objects

- Song: the living creative object.
- Master Composition: the current source of truth for song structure.
- Asset: a concrete recording, beat, mix, stem, or reference file.
- Creative Event: a structured target + operation change record.

## Minimal event language

Targets: Song, Intro, Verse, Hook, Bridge, Lead Vocal, Beat, Mix, Master.

Operations: Imported, Source Selected, Candidate Added, Recording Updated, Processing Updated, Structure Updated, Needs Decision, Approved, Archived.

## Deferred

- Batch mix render engine.
- DSP/channel-strip variant generation.
- Cloud sync.
- Collaboration.
- Predictive career modeling.

## Status

Folder import, GRDB persistence, audio preview, editable master slots, and event logging are implemented.

## Next implementation step

Filesystem watcher for observed-change detection, so events are generated from real file activity instead of manual entry.
