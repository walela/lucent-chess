# Changelog

## 1.13.2 — 2026-08-26

- Renders moves in ChessBase-style figurine notation (♞f3) in the score, engine lines, and variation previews; PGN files keep standard letters.
- No longer shows raw internal link URLs when hovering over moves in the notation.
- Redraws the engine's best-move arrow as one clean shape with a gap over the origin square.

## 1.13.1 — 2026-08-26

- Restrains the amber accent to primary actions and the current selection; folder tags, metric chips, and section icons are now neutral.
- Simplifies the dashboard header and action cards, removing redundant micro-labels and the colored icon tiles.
- Formats library dates readably (24 Aug 2026) and shows engine configuration errors in red.
- Centralizes all interface colors and typography in a single design token file.

## 1.13.0 — 2026-08-26

- Opens games in a separate reusable window while leaving the library dashboard in place.
- Returning to the library preserves the active folder, filters, and scroll position.

## 1.12.4 — 2026-08-26

- Makes the engine play and stop control a compact square button.

## 1.12.3 — 2026-08-26

- Adds a live material strip above the board with surplus pieces and the point advantage.

## 1.12.2 — 2026-08-26

- Shows imported Lichess Elo ratings beside each player in the notation pane.
- Reworks the game metadata header into compact player cards with cleaner event and result controls.

## 1.12.1 — 2026-08-26

- Filters Lichess player imports by speed, color, result, and rated or casual games.
- Keeps player-only controls out of the way when importing a direct game, study, or broadcast round.

## 1.12.0 — 2026-08-24

- Imports the latest or a numbered TWIC issue directly into a local collection.
- Imports public Lichess games, player histories, studies, and broadcast rounds without an account token.
- Downloads and parses large sources away from the main UI, filters player imports to standard chess, and skips games already in the library.
- Preserves source provenance while keeping clean source imports out of Autosave and Needs Saving.

## 1.11.1 — 2026-08-24

- Detects Stockfish installed after Lucent Chess has already launched, including installations that replace a missing saved engine path.

## 1.11.0 — 2026-08-24

Initial public release.

- Native offline macOS dashboard and three-pane study workspace.
- Real PGN import/export with metadata, comments, NAGs, and nested variations.
- Local configurable UCI/Stockfish analysis with MultiPV and inline variation boards.
- Persistent folders, search, sorting, filtering, Autosave, and Needs Saving views.
- Horizontal ChessBase-style notation with inline comments, visual variation depth, current-move highlighting, and link cursors.
- Forty-one piece sets, twenty-five board themes, custom square colors, and crisp maximized rendering.
- Two Candidates 2026 archives and all five Kasparov–Karpov World Championship matches included for offline study.
- System, Light, and Dark interface modes.
