# Lucent Chess

A native, offline macOS app for studying chess games — a PGN library and analysis workspace with a local UCI engine. Everything stays on your Mac.

![Lucent Chess game library](Docs/dashboard.png)

## Highlights

- **A real game library.** ChessBase-style dashboard with search across players, events, ECO codes, and results; persistent folders with drag-and-drop filing; and smart views for unfiled, autosaved, and unsaved games.
- **Full PGN fidelity.** Import and export nested variations, comments, NAGs, FEN starts, and metadata. Games save as ordinary `.pgn` files — no lock-in, no proprietary database.
- **Local engine analysis.** Runs Stockfish (or any UCI engine) entirely on-device with hardware-aware defaults, MultiPV study lines, WDL estimates, and every UCI option the engine exposes — including strength limits and Syzygy tablebases. Engine output is throttled off the main thread, so analysis never makes the UI stutter.
- **ChessBase-style notation.** Compact horizontal score with clickable moves, inline comments, and correctly nested variations. Add a variation by going back and playing another legal move; save an engine line into the tree with one click.
- **Direct imports.** Pull weekly TWIC archives and public Lichess games, studies, and broadcasts straight into source-named collections, with duplicate skipping.
- **Comes with games.** A starter archive of 256 games: both 2026 Candidates tournaments and all five Kasparov–Karpov World Championship matches.
- **Yours to theme.** 41 piece sets and all 25 Lichess board themes, plus custom square colors, light/dark/system modes, and a resizable board–notation–engine layout.
- **No dependencies, no telemetry.** Pure Swift with zero third-party packages. Nothing leaves the machine.

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

No third-party package dependencies — just Swift and the macOS SDK.

## Keyboard shortcuts

| Shortcut | Action |
| --- | --- |
| Left / Right | Previous / next move |
| Command-Left / Command-Right | First / last move |
| Command-E | Toggle the engine |
| Command-F | Flip the board |
| Command-N | New game |
| Command-O | Open PGN |
| Command-Option-O | Import from TWIC or Lichess |
| Command-S | Save the current game |
| Command-Shift-S | Save as a new PGN |
| Command-Shift-L | Game library |

## Your data

The recovery library is stored at `~/Library/Application Support/Lucent Chess/Library.json`. Games explicitly saved with Save or Save As remain ordinary PGN files wherever you put them.

## License

Lucent Chess is published under the [GNU Affero General Public License v3](LICENSE). The bundled piece sets and board themes are sourced from Lichess, and starter games from The Week in Chess and PGN Mentor; all retain their upstream licenses and attribution — see `THIRD_PARTY_NOTICES.txt`, `LICHESS-COPYING.md`, and `SeedGames/SOURCES.txt` in the application resources.
