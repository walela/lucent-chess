# Changelog

## 1.20.0 — 2026-09-14

- Prepares an exact position index and a metadata snapshot per imported database once, then answers board searches and header sorts from them: 11.7 million games sort in tens of milliseconds and the starting position resolves in well under a second without decoding games.
- Redesigns the game workspace around a **Reference** tab. A **Moves** table lists every continuation played from the current board across the whole reference database with game count, White's score bar and average Elo; clicking a row plays it. Castling and en passant continuations are included, and transpositions count.
- Adds a **Position search** mask modelled on database search masks: Look for, Or and Exclude boards, any-white/any-black jokers and an empty-square marker, several pieces per square on the Or and Exclude boards, right-click for the opposite colour, horizontal and vertical mirroring, a first/last move window and a minimum length in plies. Fragments are matched natively across every main line in scope (about 9–15 s for 11.7 million games, cached per mask) and opening a result jumps to the first matching position. A complete position with a side to move still answers from the exact index.
- Lists matching games in a database-style table (White, Elo, Black, Elo, Result, Event, Year) that scrolls continuously and sorts from any header through the backend.
- Keeps the previous position's results on screen, dimmed, while the next position loads; caches recently visited positions; shows preparation progress only when a search genuinely takes long.
- Replaces the editable player fields in the notation pane with a read-only game header; clicking it opens Details, where every field remains editable.
- Adds user-installed piece sets: drop a folder of `wK…bP` SVG, WebP or PNG files into `Application Support/Lucent Chess/Pieces` and it appears in Appearance. Removes the placeholder "Fritz-inspired" set.
- Fixes board-theme tiles in Appearance that stopped taking clicks in a wider inspector.

A game counts for a continuation when its main line contains both the current position and the resulting one, so a handful of games that reach both by another route are included. Prepared indexes are stored under Application Support and rebuild automatically when a source database changes.

## 1.18.1 — 2026-09-13

- Opens collections with more than 100 games in a dedicated window, reusing that window on subsequent clicks. Smaller collections remain in the library preview.
- Gives each collection window independent search, filters, sorting, and pagination, with a Library button to return to the archive.
- Adds numerically sortable White Elo and Black Elo columns, keeps Result next to the ratings, and labels the event column Tournament. Wide tables scroll horizontally.
- Indexes ratings for new CBH/CBV and PGN imports. Older libraries recover ratings from metadata for the visible page without decoding move trees or reimporting games. The first Elo sort fills remaining ratings in bounded batches before sorting the entire collection.

## 1.18.0 — 2026-09-13

- Imports ChessBase and PGN databases into their own named collections by default.
- Indexes database headers in SQLite and keeps source game data on disk; move trees are decoded only when opening a game.
- Adds indexed search and paged browsing with 200 rows per page, cached collection counts, import progress, and cancellation.
- Replaces whole-library JSON rewrites with per-game SQLite saves. Existing libraries migrate automatically, with the original JSON retained as a backup.
- Gives previously imported ChessBase games a named collection during migration while preserving games already filed elsewhere.

## 1.17.1 — 2026-09-13

- Fixes imports failing on multiline comments and preserves Windows-1252 annotation text in the reader JSON.
- Removes the 10,000-record ChessBase import limit by reading databases automatically in batches, including the final partial batch.
- Shows record progress during ChessBase imports and applies reader time and move limits per batch instead of to the full database.

## 1.17.0 — 2026-09-13

- Imports classic ChessBase CBH databases and unencrypted CBV archives with a bundled reader, preserving moves, variations, comments, and move annotations.
- Adds ChessBase files to Open Games and Finder file associations; imports go to Unfiled and skip duplicates without changing source databases.
- Adds collection browsing and preserves collection originals by creating Unfiled analysis drafts for edits.

## 1.16.0 — 2026-09-10

- Adds a position editor with piece placement, FEN loading, side to move, castling, en passant, and move counters. Validated positions open as new games without changing the source game.
- Replaces workspace dropdowns with larger, labeled action icons. Game actions stay left; Analyze and Practice sit beside the engine area on the right.
- Removes the redundant game-title block and gives the inspector clear Engine, Details, and Appearance tabs.
- Simplifies the library sidebar to All Games, Recently Edited, and Collections, including Unfiled. Automatic library saving remains active.
- Makes collection terminology consistent and removes duplicate native Game menu registration.

## 1.15.0 — 2026-09-08

- Adds a separate Stockfish training window from any study position, with color, strength and thinking-time controls and automatic library saving.
- Groups workspace commands into Game, Analysis and View menus with a visible Play from here action.
- Softens light-mode board and panel backgrounds to a warm off-white.

- Separates variations into indented lines with readable colors and repeats move numbers when a line resumes.
- Replaces generic notation text menus with promotion, deletion, and FEN/PGN copy actions for the right-clicked move.
- Aligns game metadata and notation settings into consistent columns, with Game details above notes.
- Keeps divider resizing confined to neighboring panes and preserves workspace widths across updates and reopening.

## 1.14.2 — 2026-08-27

- Rebuilds the workspace panes on NSSplitViewController so the board, notation, and engine dividers drag reliably.
- Sharpens the notation hierarchy: main line, first variation, and deeper nesting now use clearly stepped sizes and shades, and variation parentheses no longer use amber.

## 1.14.1 — 2026-08-27

- Fixes the board / notation / engine dividers not dragging; the workspace now uses a native split view, stretches the board first when the window resizes, and remembers divider positions between launches.

## 1.14.0 — 2026-08-27

- Adds the Fresca Camelot piece set (sadsnake1's Fresca recolored by caderek, CC BY-NC-SA 4.0), bringing the catalog to 42 sets.
- Makes notation figurines customizable: any bundled piece set can supply them, either tinted to match the text or in the set's own colors.
- Makes the notation font customizable with System, Serif, Rounded, and Monospaced designs and an adjustable size.

## 1.13.3 — 2026-08-27

- Draws notation figurines with the bundled Lichess mono piece silhouettes instead of unicode glyphs, tinted to match the text in both appearances.
- Fixes notation colors going illegible after switching between light and dark mode.
- Fixes Promote Variation doing nothing unless the first move of the variation was selected; it now promotes from anywhere inside the variation.

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
