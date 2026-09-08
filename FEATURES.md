# Features

The complete feature list. For the short version, see the [README](README.md).

## Game library

- Opens to a ChessBase-style game dashboard with search, file status, recent games, and one-click access to analysis.
- Organizes large libraries with persistent folders, Unfiled and Needs Saving views, drag-and-drop filing, and Move to Folder menus.
- Keeps new and duplicated games in a persistent Autosave smart collection until each one is explicitly saved as a PGN; edited PGNs remain separately visible in Needs Saving.
- Searches across players, events, sites, ECO codes, results, and filenames; filters by result or file state; and sorts players, events, dates, results, move counts, or tournament rounds.
- Uses a draggable dashboard divider so the folder sidebar can be resized between a compact list and a wider library organizer.
- Opens games in a separate reusable window, leaving the library's active folder, filters, and scroll position intact for quick return.
- Includes a starter archive of 256 unannotated games: both 2026 Candidates tournaments and all five Kasparov–Karpov World Championship matches.
- Offers a compact appearance switcher with persistent System, Light, and Dark modes.

## Notation and variations

- Displays clickable main-line moves and separate indented variations, with inline PGN comments and repeated move numbers when a line resumes.
- Gives the score a clear reading hierarchy: bold main-line moves, readable variation colors, and an amber highlight for the current move. Right-click a move to promote or delete a variation or copy FEN/PGN.
- Adds variations simply by going back and making another legal move.
- Lets you save an engine line into the move tree with one click.

## PGN and imports

- Saves games as real `.pgn` files with Command-S and Save As, while keeping a local recovery library between launches.
- Imports and exports PGN, including player and event metadata, nested variations, comments, NAGs, and FEN starts.
- Imports weekly TWIC archives and public Lichess games, players, studies, or broadcast rounds directly into source-named collections, with duplicate skipping and player-history filters.

## Engine

- Runs Stockfish entirely on the Mac with hardware-aware defaults (6 threads, 1 GB hash, and 3 study lines on an 8-core/16 GB M1 Pro), resource presets, configurable CPU threads, hash, MultiPV, WDL estimates, and depth/time/node search limits.
- Detects every UCI option exposed by the selected engine, including Stockfish strength/Elo controls, Syzygy tablebase paths, and Clear Hash.
- Ranks engine lines in a numbered gutter and expands any line into an independent inline variation board with local move controls; only the plus button writes it into the study.
- Can switch to another local macOS UCI engine without changing the app.

## Training

- Starts an untimed game against Stockfish from the current study position, including its castling rights and en-passant square.
- Opens training in a separate window and saves its moves in the library while leaving the source study selected.
- Lets you choose White or Black, an approximate engine strength from 1400 to 2600 or full strength, and 0.5 to 5 seconds of thinking time per engine move.
- Uses a separate engine process, preserving analysis settings and hiding analysis arrows during play.
- Handles legal moves, resignation, checkmate and draws; stopping or closing the window cancels pending engine moves.
- Opens the saved training game in the study workspace for review and PGN export.

## Board

- Supports click-to-move, drag-to-move, promotion, castling, en passant, board flipping, coordinates, move hints, and keyboard navigation.
- Applies moves and navigation jumps immediately, without an automatic piece transition getting between the board and the score.
- Includes 42 bundled piece sets—including an original Fritz-inspired ivory/charcoal set—and all 25 current Lichess board themes, plus custom square colors and piece scaling.
- Sizes pieces explicitly within each square, caps oversized shadows, and supplies high-resolution fallbacks for filtered sets so both inline and maximized boards stay crisp.
- Uses a resizable board / notation / engine workspace with persistent pane widths and grouped Game, Analysis and View controls. Light mode has warm off-white surfaces.
- Centers a compact five-button game transport directly below the board for start, previous, flip, next, and end navigation.

## Performance

- Coalesces and reduces UCI output off the main thread, publishing at most one engine snapshot every 80 ms so Stockfish cannot starve clicks or navigation.
- Captures immutable, flat recovery snapshots in a few milliseconds, then performs JSON encoding and disk writes entirely on a background queue.

See [PERFORMANCE.md](PERFORMANCE.md) for details.

## Licensing notes

The visual catalog is sourced from Lichess. Attribution and applicable GPL, AGPL, Creative Commons, freeware, and non-commercial notices are bundled with the application. Two upstream sets with no stated redistribution license are intentionally omitted.

Starter game scores are sourced from The Week in Chess and PGN Mentor. Exact source URLs and retrieval details are included in `SeedGames/SOURCES.txt` inside the app bundle.
