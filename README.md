# Lucent Chess

A native, offline macOS app for studying chess games — a PGN library and analysis workspace with a local UCI engine. Everything stays on your Mac.

![Lucent Chess game library](Docs/dashboard.png)

## Highlights

- **A real game library.** ChessBase-style dashboard with search across players, events, ECO codes, and results; persistent collections with drag-and-drop filing; and clear All Games, Recently Edited, and Unfiled views.
- **Full PGN fidelity.** Import and export nested variations, comments, NAGs, FEN starts, and metadata. Export games as ordinary `.pgn` files — no lock-in, no proprietary database.
- **Local engine analysis.** Runs Stockfish (or any UCI engine) entirely on-device with hardware-aware defaults, MultiPV study lines, WDL estimates, and every UCI option the engine exposes — including strength limits and Syzygy tablebases. Engine output is throttled off the main thread, so analysis never makes the UI stutter.
- **Set up any position.** Place pieces or load a FEN, choose the side to move and special rights, and open a new game for analysis or practice.
- **Play from any position.** Start a separate Stockfish training game, choose your color and strength, and keep its moves in your library without changing the original study.
- **ChessBase-style notation.** Readable indented variations with clickable moves, inline comments, and move-specific context menus. Add a variation by going back and playing another legal move; save an engine line into the tree with one click.
- **ChessBase files.** Import classic CBH databases (with their companion files) and unencrypted CBV archives into Unfiled, including moves, variations, comments and move annotations.
- **Direct imports.** Pull weekly TWIC archives and public Lichess games, studies, and broadcasts into Unfiled or an explicitly chosen collection, with duplicate skipping.
- **Comes with games.** A starter archive of 256 games: both 2026 Candidates tournaments and all five Kasparov–Karpov World Championship matches.
- **Yours to theme.** 42 piece sets and all 25 Lichess board themes, plus custom square colors, light/dark/system modes, and a resizable board–notation–engine layout.
- **Offline, no telemetry.** Native Swift app with a bundled C++ ChessBase reader. Nothing leaves the machine.

The full feature list lives in [FEATURES.md](FEATURES.md).

## Install

1. Download `Lucent-Chess-macOS.zip` from the [latest release](https://github.com/walela/lucent-chess/releases/latest).
2. Unzip and move **Lucent Chess.app** to Applications.
3. The build is ad-hoc signed, not notarized, so macOS will block the first launch. Either use **System Settings → Privacy & Security → Open Anyway**, or clear the quarantine flag directly:

```sh
xattr -dr com.apple.quarantine "/Applications/Lucent Chess.app"
```

Stockfish is optional but recommended for analysis:

```sh
brew install stockfish
```

Lucent Chess finds it automatically in the usual Homebrew and MacPorts locations; any other UCI binary can be selected in Settings.

Requires Apple Silicon and macOS 14 or later.

## Build from source

```sh
./scripts/build_app.sh
```

Uses Swift, the macOS SDK and a vendored C++20 ChessBase reader. `swift build` builds both executables; keep `LucentChessCBH` next to `LucentChess` when running outside an app bundle.

## Keyboard shortcuts

| Shortcut | Action |
| --- | --- |
| Left / Right | Previous / next move |
| Command-Left / Command-Right | First / last move |
| Command-E | Toggle the engine |
| Command-F | Flip the board |
| Command-N | New game |
| Command-O | Open PGN, CBH or CBV |
| Command-Option-O | Import from TWIC or Lichess |
| Command-S | Save to a collection |
| Command-Shift-S | Export PGN |
| Command-Shift-L | Game library |
| Command-Option-Shift-S | Set up position |

## Your data

The recovery library is stored at `~/Library/Application Support/Lucent Chess/Library.json`. New games and analysis drafts stay in Unfiled until you explicitly choose a collection. Editing a collection game preserves its original and creates an Unfiled analysis copy. Export PGN writes an ordinary PGN file wherever you choose.

## License

Lucent Chess is published under the [GNU Affero General Public License v3](LICENSE). The bundled piece sets and board themes are sourced from Lichess, and starter games from The Week in Chess and PGN Mentor; all retain their upstream licenses and attribution — see `THIRD_PARTY_NOTICES.txt`, `LICHESS-COPYING.md`, and `SeedGames/SOURCES.txt` in the application resources.

## ChessBase imports

Use **Open Games…** (Command-O) or **Import → PGN or ChessBase…**.
For CBH, keep the matching `.cbg`, `.cba`, `.cbp`, `.cbt`, `.cbc` and `.cbs`
files in the same folder. CBV archives are unpacked into temporary storage;
source files are never modified. Imports default to Unfiled and skip duplicates.

Supports classic CBH and unencrypted CBV, processed automatically in batches of
256 records with visible progress. Database files may total up to 256 MiB per import. Newer 2CBH databases, encrypted
archives, Chess960 and null-move games are unsupported. Unsupported or unreadable
records are counted in the import result. Text pages, multimedia, training features
and extra proprietary tags are not imported. Arrows and square highlights are
preserved as PGN annotation text, not rendered overlays. Legacy text uses
Windows-1252; other code pages are not automatically detected.

Reader provenance and local changes: [Tools/ChessBaseReader](Tools/ChessBaseReader/README.md).

Focused import checks: `./scripts/check_chessbase_import.sh` (temporary fixtures only).
