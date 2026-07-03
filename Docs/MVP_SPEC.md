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

MVP complete: folder import (cancellable, hash-deduplicated), GRDB persistence, audio preview, waveforms, editable + reorderable master slots with drag-and-drop assignment, manual and automatic event logging, and the FSEvents folder watcher generating observed creative events from real file activity.

## Next implementation step

Startup reconciliation scan — diff watched folders against the catalog at launch so changes made while the app was closed are also observed.
