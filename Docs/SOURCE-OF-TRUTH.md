# Artist OS — Source of Truth
## Version 1.0

> This document defines the permanent architecture, philosophy, data model, and design principles of Artist OS. Every future feature, service, database model, UI screen, and AI capability should derive from this document.
> Docs/VISION.md remains the working logic spec; where they differ, THIS document wins.

# Mission
Artist OS is not a DAW. It is not a file browser. It is not Git for music. It is not simply version control.
Artist OS is the operating system for an artist's creative work.
Its purpose is to make every creative decision observable, reversible, understandable, and organized without requiring the artist to become a project manager.

# Core Philosophy
There is only one thing the artist is creating. **Songs.**
Everything else exists to support a Song. Not folders. Not projects. Not sessions. Not files. Not versions. Songs.
If a feature cannot ultimately be explained as helping an artist create, understand, or improve a Song, it probably does not belong.

# Product Philosophy
Artist OS should reduce creative friction. The artist should spend nearly all of their time making music. The software should quietly organize everything else. The application should continuously observe creative work without demanding manual bookkeeping.
Whenever possible: Observe instead of asking. Infer instead of requiring notes. Organize instead of creating folders. Explain instead of overwhelming.

# Product Hierarchy (immutable)
Artist → Catalog → Song → { Master Composition, Assets, Creative History, Decisions, Analysis, Releases }
Nothing exists above Song except the Artist Catalog. Everything beneath Song exists only because it helps describe the song.

# Song
A Song is NOT a WAV, an MP3, a Logic project, a folder, a session, or a bounce.
A Song is the permanent identity of a piece of music. It survives new beats, rewritten hooks, new verses, new recordings, arrangement changes, mixing, mastering, releases. The song is the permanent object. Everything else changes.

# Master Composition
The heart of Artist OS. NOT the newest bounce/project/final master/latest mix.
It is the current approved creative state of the song — a blueprint of sections, each pointing at its currently selected building blocks. It represents the artist's current intent.

# Assets
Assets are immutable. If an asset changes, it becomes a NEW asset. Assets never mutate. Artist OS preserves history forever.

# Creative Events
Nothing changes without creating an event. Events represent objective facts, automatically observed whenever possible. The artist should rarely need to create them manually.

# Events Never Lie
Events contain facts, never opinions. Never "Hook Improved" — instead "Recording Updated: Lead17.wav → Lead21.wav". Whether it's better belongs elsewhere. Events record reality.

# Decisions
Events explain WHAT happened. Decisions explain WHY. ("Lead21 Approved — Reason: cleaner emotion in Verse 1.") Decision history becomes one of the most valuable parts of Artist OS.

# Analysis
Analysis is layered on top of facts: strongest hook, vocal consistency, melodic originality, writing patterns, production evolution, structural trends, artistic identity, strengths, weaknesses, trajectory, release readiness. Analysis is never permanent. Facts are.

# Versions Do Not Exist
Versions are an emergent property of Creative History + the current Master Composition — never the primary object.

# Files Are Evidence
The filesystem is evidence, not truth. Truth belongs to Artist OS. If Artist OS knows where something came from, why it changed, and what replaced it, filenames become much less important.

# Automation
Automation should never surprise the artist. The application may propose (likely duplicate / replacement / abandoned / newer version / alternate take). The artist approves. Truth updates.

# AI Philosophy
AI never owns the catalog. AI observes, explains, predicts, suggests, summarizes. AI never silently edits history. AI never rewrites facts.

# Universal Creative Event System
Targets: Song, Intro, Verse, Chorus, Hook, Bridge, Outro, Beat, Lead Vocal, Background Vocal, Adlibs, Mix, Master, Artwork, Release.
Operations: Imported, Candidate Added, Source Selected, Recording Updated, Processing Updated, Structure Updated, Decision Made, Approved, Archived.
Simple. Consistent. Scalable forever.

# Event Classification
Recording Changed vs Processing Changed vs Writing Changed vs Arrangement Changed vs Mix Changed vs Master Changed are fundamentally different creative actions. The application should never confuse them.

# Master Composition Rules
Every section exists independently: which recording, which processing, why it is current, what alternatives exist — visible without opening folders. (Recording / Processing / Status / Confidence per section.)

# Source of Truth Rules
Only one object may be the current source of truth. Everything else becomes history.

# Design Principles
Artist OS should feel calm, premium, native, invisible, intentional, fast. Never cluttered, noisy, technical, overwhelming. The artist should feel like they're working on music, not software.

# AI Principles
AI should answer: "What changed?" "What am I forgetting?" "What recording replaced this one?" "Why is this the current version?" — never "What folder is this in?"

# Long-Term Vision
The complete operating system for professional artists. Layers on top of Songs: Version Intelligence, Audio Analysis, Catalog Intelligence, Artist DNA, Creative Search, Career Analytics, Release Management, Publishing, Marketing, Collaboration, Cloud Sync, AI. Those systems exist because they improve Songs — never the other way around.

# Non-Goals
Not replacing Logic/Pro Tools/Ableton/FL. Creation remains inside the DAW. Artist OS manages the creative lifecycle around it.

# MVP
Succeeds if an artist can: import a catalog; auto-organize every song; track every recording + decision; maintain a single Master Composition; understand what changed over time; instantly preview every asset; never lose work; never wonder which version is current.

# Future Rule
Every future feature must answer: **Does this help the artist understand, organize, or evolve a Song?** If no — don't build it.

# First Principles
1. Songs are permanent. 2. Assets are immutable. 3. Events are factual. 4. Decisions explain intent. 5. Analysis is derived. 6. AI assists, never owns. 7. Artists create music, not folders. 8. Artist OS quietly organizes everything else.

# The North Star
An artist can open a song from five years ago and immediately understand how it evolved, every important decision, every recording that mattered, every experiment tried, and why the current version exists — without opening a single folder or guessing which file is right.
