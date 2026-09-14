# Reference database performance review — 1.19.0

Historical measurements: the scan architecture below is superseded in 1.20.0 by
[prepared exact position and metadata indexes](Interactive-Database-Architecture.md).

Measured on the development Mac, 14 September 2026. This is a first pass at
reference search, not a persistent index of every position in every game.

## What changed after self-review

- Share one bound SQL predicate between the table and board-search candidates;
  player, tournament, numeric Elo, local-calendar year, result and collection
  constraints cannot silently diverge between the two paths.
- Force sparse text matches to fetch by row ID, including board-search candidate
  materialization. At full scale SQLite otherwise chose the collection/date index
  and walked millions of unrelated entries. Alekhine paging fell from about
  5.5 seconds to 20 ms; first query with the fix measured 174 ms.
- Use a compact covering Elo/year/result index for range counts and board
  candidates, with one leading rating field and only the requested scope.
  Separate rating indexes caused millions of full-row reads to test the opponent's
  rating. A profiled full-scale attempt was stopped after more than eight minutes.
  Table pages now walk the requested ordering index and stop at 201 matches.
  The 200k sample's repeated Elo query fell from 269 ms to 3.6 ms.
- Reuse bounded count caches across pages and sort changes. FTS names are scoped
  by field and collection. User input is bound, including adversarial punctuation.
- Materialize matching row IDs once into a file-backed temporary table, then read
  512 candidates at a time. Repeated batches no longer rerun FTS/range predicates.
- Release the main database read snapshot between batches, avoiding a long-lived
  reader that prevents an import WAL from being checkpointed.
- Probe dense cached position results by primary key while walking the requested
  sort index. The previous million-row IN materialization repeated on every page.
- Decode CBH positions in a persistent native process without constructing SAN,
  annotations or variation trees. A target's required home pawns and pawn counts
  allow safe early rejection; matching counts were unchanged on the sample.
- Stream PGN byte ranges through a reusable 16 KiB buffer, skipping comments and
  variations and resolving only candidate SAN moves, without building studies.
- Bound native processes and open PGN readers to four each. Helper reads use
  POSIX read and 100 ms polling; FileHandle's buffered read previously stalled
  the request/response protocol. Cancelled queries remove incomplete results.
- Reclaim least-recently-used completed position results above a 256 MiB used-page
  budget, before the 512 MiB hard cap. A 60-second grace interval protects newly
  resolved pages and cache hits; incomplete searches are not evicted. Regression
  checks exercise pressure eviction while preserving recent and in-flight jobs.
- Scope cache invalidation and UI request identity to the searched collection.
  Autosaving an unrelated working game no longer cancels a reference search or
  invalidates its completed results. Unchanged payloads avoid redundant writes.
- Decode game opening off the UI thread. Reference previews own their board and
  selected ply; browsing them does not navigate or edit the working game.
- Use the same local Gregorian year boundaries as the visible dates. A January 1
  game previously fell outside a same-year search in positive UTC offsets.
- Preserve committed imports when later bookkeeping fails. Delete managed files
  only after uncommitted catalog cleanup succeeds. Startup recovers collection
  metadata from committed sources. Both native import paths reserve checkpoint
  headroom; CBH also estimates required index space before ingesting headers.

## Tests

`./scripts/check_catalog.sh` checks filters, bounds, prefix/injection handling,
local year boundaries, transpositions, main-line-only matching, scoped cache
invalidation, pagination, cancellation, source retention on cleanup failures and
collection recovery. PGN cases cover castling, en passant, underpromotion,
disambiguation, checkmate, custom starts, comments, variations and compact NAGs.

`./scripts/check_chessbase_import.sh` checks native annotations and game fidelity,
archive validation, promotion/custom-position fixtures, large batches, async
imports and restart. Both suites use isolated test libraries.

UI checks use a separate application identifier and disposable 240-game library:
combined player/Elo/year filters, a board made with Set up board, numeric Elo sort,
reference selection, opening at a matching ply, preview navigation and preservation
of the working position. The installed app also showed all 12 recovered collections and 11,757,636 games.
The Filter inspector's player/Elo/year/current-board search produced the expected
70 QA games and preserved the criteria in the reference window. In the real Mega
Database, a standalone Alekhine + 1.e4 search completed with 1,466 matches after
fixing candidate materialization. Existing 1.e4 working-game data persisted
unchanged through app replacement.

## Measurements

### Stratified ChessBase sample

200,000 headers sampled evenly across 11,743,083 source records, retaining original
move files. 199,975 valid game rows; 25 deleted/non-game records. Sample ingestion:
17.795 s, native peak RSS 145 MB. Results span eras and rated/unrated games.

| Operation | Seconds | Matches |
| --- | ---: | ---: |
| All games, first / next page | 0.0066 / 0.0030 | 199,975 |
| Player prefix A, first / repeated | 0.1565 / 0.0570 | 66,632 |
| Player Alekhine, first / repeated (final query fix) | 0.0095 / 0.0026 | 52 |
| Player + year + result, first / repeated | 0.0037 / 0.0029 | 13 |
| Both Elo ≥2400, first / repeated (final covering index) | 1.1890 / 0.0036 | 17,937 |
| First 1.e4 board search | 2.8197 | 100,439 |
| Repeat board cache lookup | 0.0046 | 100,439 |
| Cached board first / next / player sort page | 0.0046 / 0.0033 / 0.0056 | 100,439 |
| Cancellation response after request | 0.0034 | — |
| Open a 117-ply game | 0.0174 | 1 |

The previous scanner took 9.4952 s for the identical 100,439 matches. Both runs
reported 71 unreadable/unsupported games. Timings include ordinary filesystem
cache effects and concurrent development work; “first” is not an OS-cold-cache
claim. Counts and optional indexes can dominate a first header query.

### Full recovered ChessBase database

A consistent SQLite backup was used, leaving the live library unmodified by the
benchmark. 11,741,260 imported game rows. Full-scale profiling exposed and fixed
sparse-name candidate plans and the opponent-rating count lookup problem.

| Operation | Seconds | Matches |
| --- | ---: | ---: |
| All games, first / next page | 0.0095 / 0.0057 | 11,741,260 |
| Broad one-letter player prefix A, first / repeated | 9.2161 / 2.4902 | 3,903,286 |
| Player Alekhine, first / repeated / next page | 0.1743 / 0.0215 / 0.0196 | 2,903 |
| Player + year + result, first / repeated | 0.0247 / 0.0168 | 765 |
| Both Elo ≥2400, first including new covering index / repeated | 79.5744 / 0.0047 | 1,066,841 |
| First 1.e4 board search | 132.0088 | 5,873,566 |
| Repeat board cache lookup | 0.0055 | 5,873,566 |
| Cached board first / next / player sort page | 0.0057 / 0.0037 / 0.0434 | 5,873,566 |
| Cancellation response | 0.0056 | — |
| Open a 44-ply game | 0.0276 | 1 |

The full board scan reported 4,481 unreadable/unsupported games. The benchmark
process was observed at about 130 MB resident memory during the full run; this is
not a combined application-plus-helper peak. The external `time -l` wrapper could
not read `kern.clockrate` in the sandbox after the benchmark completed, so no
unsupported aggregate resource claim is made. The disposable 15+ GiB catalog was
removed after the measurements, restoring approximately 24 GiB of free space.

The one-letter prefix deliberately matches millions of games: its FTS row-ID
materialization remains costly on repeated pages. Full names are much faster.
The Elo run reused existing legacy-rating preparation indexes and measured the
new covering index's first build; an older catalog needing metadata backfill may
pay additional preparation cost. Broad first-use indexes are not instantaneous.

### PGN corpus

1,024 games built from 64 actual games repeated 16 times. This deliberately small
corpus exercises move parsing; it is not evidence of 10-million-game throughput.

| Operation | Seconds | Matches |
| --- | ---: | ---: |
| Header/byte-range import | 0.2857 | 1,024 |
| 1.e4 first search | 0.0510 | 400 |
| Deep final-position first search | 0.7862 | 16 |
| Full-scan kings-only miss | 0.8226 | 0 |

No games were skipped. These runs overlapped integrity-check I/O; cached-page
measurements ranged 6–120 ms. Deep PGN queries remain linear in decoded moves.

Reproduce using `scripts/bench_reference.sh cbh <disposable-catalog.sqlite>
[folder-id]` or `scripts/bench_reference.sh pgn <source-catalog.sqlite>
<new-disposable-directory>`. The CBH benchmark creates optional indexes and a
position cache: never point it at the user's live catalog. Private source data
and absolute local paths are not distributed with the benchmark.

## Remaining limits and next work

1. First board queries scan header-matching games. A persistent, compact position
   index is still needed for consistently fast arbitrary-position searches across
   ten million PGN games. Results from a short opening query must not be projected
   to deep positions or full misses.
2. Matching means exact pieces and side to move on the main line. Castling rights,
   en passant and clocks are ignored; variations, partial-material patterns,
   Chess960 and null moves are not supported. Skipped games are reported.
3. The sidecar's main file is capped near 512 MiB. New queries reclaim older
   completed entries above a 256 MiB used-page budget; one-day-old completed
   entries expire regardless. Cached results touched within 60 seconds and
   incomplete jobs are protected. Several simultaneous dense queries can still
   reach the hard cap; WAL and temporary candidate files need additional space.
   Explicit per-window leases and resumable/incomplete-cache recovery remain work.
4. Imports still use a single large transaction and maintain catalog indexes as
   records arrive. Checkpoint headroom guards and safe recovery address failure
   handling; staged ingestion, deferred index construction and smaller resumable
   commits are needed to reduce peak storage and import write amplification.
5. Arbitrary sort combinations and exact counts over broad range/text filters can
   still be expensive. Counts are cached and optional sort indexes are reused,
   but this does not guarantee millisecond cold queries at every scale.
6. Reference selection persists; detailed filters currently last for the running
   app session. Saved reusable filter presets are a follow-up.

## Recovery validation

The interrupted import was backed up before recovery. SQLite WAL checkpointing
completed and `PRAGMA quick_check` returned `ok`. The catalog retained 11,757,635
existing games; one game created during verification brought the total to
11,757,636. Mega Database 2026 retained 11,741,260 imported games and all seven
managed companion files. No prior library contents were replaced by a test DB.
