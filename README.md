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
- **Large databases.** Index classic CBH databases, unencrypted CBV archives, and PGN files into named collections. Browse and search the index; games, variations, and comments load when you open a game.
- **Direct imports.** Pull weekly TWIC archives and public Lichess games, studies, and broadcasts into named collections, with duplicate skipping.
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

## Browsing collections

Click a collection with more than 100 games to open its dedicated window. Clicking it again brings the same window forward; collections with 100 games or fewer stay in the library preview. Each window keeps its own search, filters, sort order, and page. Use **Library** to return to the collection browser.

The game table shows **White Elo**, **Black Elo**, **Result**, and **Tournament**, along with players, date, moves, and round. Every column header is sortable; click again to reverse its order. Elo sorts numerically, with unrated games below rated games in descending order. Missing ratings display as a dash. The first Elo sort of an older library fills in any remaining ratings from metadata in the background. On narrower layouts, scroll the table horizontally to see every column.

## Reference database and filters

In a game window, open the **Filter** inspector tab (or the toolbar's **Filter**
button) and choose a reference collection. Matching games appear directly in the
inspector and follow the board as you play or navigate the notation. The panel
shows players, ratings, result, tournament and year, with 200 games per page.
Selecting a result previews it separately at the matching position; **Open for
analysis** explicitly selects it as a working game.

From the main library or a collection window, use **Filters** in the top toolbar
to combine player names, separate White/Black Elo bands, tournament, year, result
and an optional board. Paste FEN or choose **Set up board…**. These filters are
independent of the game inspector's current-board results. Names match word
prefixes; unknown Elo does not satisfy a numeric range. All table columns remain
sortable, and results load in pages of 200.

Imported databases are prepared once for interactive browsing: all eight sort
orders and name indexes, then an exact index of every main-line position when
board search is first used. Preparation runs in the background, survives board
navigation, and resumes position work after an app restart. Progress is shown;
there is no fallback to scanning the database for each new position.

Queries read compressed position postings and compact metadata columns, then
load only 200 visible rows. Saved studies update their positions incrementally.
Moving or deleting individual imported games applies a small overlay, preserving
the large prepared indexes. New imports and bulk collection changes rebuild the
metadata snapshot; unchanged source positions remain reusable.

Board matches compare exact piece placement and side to move, including
transpositions, but ignore castling rights, en passant and clocks. Only main lines
of standard chess games are indexed. Damaged games retain readable prefixes and
are reported as incomplete coverage. Preparation requires extra disk space;
on this Mac the 11.74-million-game source uses about 10 GiB for exact positions
plus about 2 GiB for imported metadata.

See [architecture, measurements, and remaining limits](Docs/Interactive-Database-Architecture.md).

## Your data

The indexed library is stored at `~/Library/Application Support/Lucent Chess/Library.sqlite`.
Managed copies of imported database files live in the adjacent `Databases` folder;
keep that folder with the SQLite database when backing up or moving the library.
The SQLite `-wal` and `-shm` files, when present, belong to the live database—quit
Lucent before making a filesystem copy of the library directory.

Existing `Library.json` libraries migrate automatically. The original JSON file is
retained as a recovery backup; it does not contain edits made after migration.
Database imports get a collection named after the file by default. New games and
analysis drafts stay in Unfiled until explicitly filed. Editing a collection or
indexed source game preserves the original and creates an Unfiled analysis copy.
Only working games are decoded in memory; the browser loads 200 metadata rows at
a time. All column orders are prepared together and reused.

## License

Lucent Chess is published under the [GNU Affero General Public License v3](LICENSE). The bundled piece sets and board themes are sourced from Lichess, and starter games from The Week in Chess and PGN Mentor; all retain their upstream licenses and attribution — see `THIRD_PARTY_NOTICES.txt`, `LICHESS-COPYING.md`, and `SeedGames/SOURCES.txt` in the application resources.

## ChessBase imports

Use **Open Games…** (Command-O) or **Import → PGN or ChessBase…**.
For CBH, keep the matching `.cbg`, `.cba`, `.cbp`, `.cbt`, `.cbc` and `.cbs`
files in the same folder. CBV archives are unpacked into temporary storage;
source files are never modified. Database imports create a named collection unless
an existing destination is chosen. Reimporting an identical source database is
skipped. Overlap between different databases is retained rather than guessed
from matching player names; small TWIC/Lichess imports still deduplicate games.

Classic CBH and unencrypted CBV are supported. Archives are unpacked block by
block, then their headers are indexed without decoding every move. PGN imports
index headers and byte ranges. Actual game contents, including SAN and variations,
are decoded and validated on open. The previous 10,000-game, whole-import move,
and 256 MiB database-file limits do not apply to indexed imports. Available disk
space and the source format's own limits still apply. An individual opened game
and a decompression block remain bounded against malformed inputs.

Newer 2CBH databases, encrypted archives, Chess960 and null-move games remain
unsupported. Text pages, multimedia, training features and extra proprietary tags
are not imported. Arrows and square highlights are preserved as PGN annotation
text, not rendered overlays. Legacy CBH text uses Windows-1252.

Reader provenance and local changes: [Tools/ChessBaseReader](Tools/ChessBaseReader/README.md).

Checks: `./scripts/check_catalog.sh` covers indexing, paging, migration and on-demand opening; `./scripts/check_chessbase_import.sh` covers game fidelity and archive integrity. Both use temporary test libraries. `./scripts/check_position_index.sh` checks corruption, crash recovery, and concurrent builders.
