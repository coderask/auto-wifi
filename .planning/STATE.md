# Project State

## Project Reference

See: .planning/PROJECT.md (updated 2026-05-12)

**Core value:** When multiple known WiFi networks are in range, the user is always on the genuinely best one — and never stranded on a dead or weak network because macOS was slow to switch.
**Current focus:** Phase 1 — Foundations

## Current Position

Phase: 1 of 8 (Foundations)
Plan: 0 of TBD in current phase
Status: Ready to plan
Last activity: 2026-05-12 — Roadmap created (8 phases, 39 v1 requirements mapped, mode=mvp, granularity=standard)

Progress: [░░░░░░░░░░] 0%

## Performance Metrics

**Velocity:**
- Total plans completed: 0
- Average duration: —
- Total execution time: 0.0 hours

**By Phase:**

| Phase | Plans | Total | Avg/Plan |
|-------|-------|-------|----------|
| - | - | - | - |

**Recent Trend:**
- Last 5 plans: (none yet)
- Trend: —

*Updated after each plan completion*

## Accumulated Context

### Decisions

Decisions are logged in PROJECT.md Key Decisions table.
Recent decisions affecting current work:

- Roadmap: Single-process LSUIElement app for v1; XPC agent split deferred to v2 (REQUIREMENTS.md ARCH-01)
- Roadmap: Login-item path via `SMAppService.loginItem`, not `SMAppService.agent` — research recommends for personal/portfolio scope
- Roadmap: Notarization pipeline scaffolded in Phase 1, exercised continuously, packaged in Phase 8
- Roadmap: Hysteresis thresholds read-only in v1 (TUNE-01 deferred); editable in v2

### Pending Todos

None yet.

### Blockers/Concerns

Phase 1 needs an empirical CoreWLAN spike on real hardware (per research SUMMARY.md "Research Flags" + ARCHITECTURE.md "Open Questions"):
- Exact CoreWLAN scan rate-limits on macOS 14.4+
- `associate(toNetwork:password:)` with `nil` for Enterprise SSIDs
- `scanCacheUpdated` reliability when app not frontmost
- SMAppService macOS 14.4+ Info.plist requirements (error-125 reports)
- ICMP-equivalent via `NWConnection` UDP-to-gateway vs raw-socket entitlements

Findings to be captured in `.planning/research/PHASE_1.md` during Phase 1 planning.

## Deferred Items

Items acknowledged and carried forward (from REQUIREMENTS.md v2 section):

| Category | Item | Status | Deferred At |
|----------|------|--------|-------------|
| Throughput | THR-01: Lightweight throughput sampling beyond ping/DNS | v2 | 2026-05-12 (init) |
| Tuning | TUNE-01: Editable hysteresis thresholds in GUI | v2 | 2026-05-12 (init) |
| Tuning | TUNE-02: Auto-tuning of hysteresis from observed flap rate | v2 | 2026-05-12 (init) |
| Polish | POL-01..06: Notifications, Sparkle, Cask, CSV/JSON export, snapshot export, Charts viz | v2 | 2026-05-12 (init) |
| Architecture | ARCH-01: XPC agent + GUI split | v2 | 2026-05-12 (init) |

## Session Continuity

Last session: 2026-05-12 17:09
Stopped at: Roadmap and STATE created; REQUIREMENTS.md traceability filled. Ready for `/gsd-plan-phase 1`.
Resume file: None
