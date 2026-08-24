# Lucent Chess performance architecture

Version 1.9 replaces several broad, synchronous paths that could make the interface feel unresponsive under engine load or with a larger library.

## Review findings and fixes

- **Engine event flood:** every Stockfish `info` line previously entered the main queue, performed SAN conversion, changed several published properties, and invalidated large SwiftUI view trees. Raw output is now buffered and reduced on a dedicated queue. Only the newest message and newest PV for each MultiPV slot cross to the main thread every 80 ms, in one immutable telemetry snapshot. The analysis list and board arrow observe that narrow stream independently from the workspace.
- **Global view invalidation:** move navigation and edits previously signaled the entire `LibraryStore`. Each `ChessStudy` now owns its own observable revision state, so dashboard and root navigation do not redraw for board-local changes.
- **Tree traversal:** selected-node, parent, and path operations previously searched the recursive move tree repeatedly. Every study now maintains a UUID-to-node index and uses stored parent IDs. Current-position parsing and main-line length are cached and invalidated only when required.
- **Notation redraws:** selecting a move previously rebuilt and compared the full attributed notation document. Static notation and node ranges are now cached by a notation revision; selection changes touch only the old and new text ranges.
- **Persistence:** JSON encoding of the complete live object graph previously occurred on the main thread. A flat, immutable, `Sendable` snapshot is captured first; encoding and atomic writing happen on a serial utility queue. Flat nodes also avoid recursive encoder limits.
- **Dashboard work:** rows are lazy and the scoped/filter/sort query is evaluated once per render rather than repeatedly for the count, empty state, controls, and list.

## Data structures

- Library selection: `[UUID: ChessStudy]` index alongside the ordered studies array.
- Move lookup: `[UUID: MoveNode]` per study, with `parentID` for upward traversal.
- Persistence: flat `[MovePersistenceSnapshot]` records connected by UUIDs.
- Engine UI: one `EngineAnalysisSnapshot` containing lines and search statistics.

## Measured checks

Measurements use the installed 258-game, 7.96 MB library on the target Apple Silicon Mac:

- Full library decode and index construction: about **144 ms**.
- Immutable main-thread persistence capture: about **4.3 ms**.
- 200,000 current-node and cached-position reads in a 5,000-ply tree: about **22 ms**.
- Game selection: about **0.004 ms**; move-selection notification: about **0.012 ms**; edit scheduling: about **0.19 ms**.
- Synthetic 3,000-message UCI burst: **one** telemetry publication, preserving all newest MultiPV slots.
- Compact recovery archive: **5.26 MB**, down from **7.96 MB**.

The performance harnesses are `scripts/ArchitectureChecks.swift`, `scripts/ResponsivenessChecks.swift`, and `scripts/EngineChecks.swift`.
