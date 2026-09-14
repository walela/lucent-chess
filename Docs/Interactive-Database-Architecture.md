# Interactive reference databases

Status: implemented, automatically validated, and visibly checked in installed
1.20.0 (48), 14 September 2026.
Baseline: `01c28d0`, 11,757,636 catalog games on this Mac (16 GiB RAM, 8 CPUs).

## Decision

Board navigation must look up an existing position index. It must never replay
the reference database to answer a previously unseen position. Sorting must read
an existing ordering and intersect a compact set of matching game IDs. Neither
operation may create database indexes or hydrate millions of game objects.

Keep SQLite for the library registry, editable games, and the approximately 200
metadata rows displayed on a page. Introduce immutable, native source indexes
for positions and typed metadata/sort orders. Their identity is the source plus
record, independent of current folder, header filters, and SQLite rowids.

This is an architectural change. A cache of completed scans cannot substitute
for it: moving one ply creates another cache miss in the current implementation.

## Evidence from the actual library

The baseline board path materializes candidate rowids, decodes CBH/PGN games,
and writes matches into `PositionSearch.sqlite`. A new board costs O(candidate
games). Earlier full-app `1.e4` measurement was 132 seconds; the user has observed
3–5 minutes. A later native-only scan measured 69 seconds. These measurements
cover different work; none establishes interactive latency.

`DatabaseCatalog.page` also executes `CREATE INDEX` and rating backfill. That is
why the first sort can take minutes. A read-only audit of already-indexed first
pages (201 actual metadata rows) produced:

| Sort | Whole library | Mega collection |
|---|---:|---:|
| Date | 20.6 ms | 3.9 ms |
| Players | 53.0 ms | 2.9 ms |
| White Elo | 25.9 ms | 1.7 ms |
| Black Elo | 12.8 ms | 2.1 ms |
| Tournament | 10.1 ms | 6.2 ms |
| Result, moves, round | Each exceeded the 5-second audit ceiling | Same |

The last three orders lacked their indexes and used temporary sorting. These
are query timings under the machine's ordinary cache state, not cold-boot or
end-to-end UI measurements. Existing broad-prefix search still takes seconds;
one fast indexed order does not prove arbitrary combined filters are fast.

SQLite explicitly documents index-ordered and covering-index scans, and its
explain-plan output identifies temporary ordering. This supports retaining the
row store; it does not justify creating more multi-gigabyte indexes inside UI
requests. [SQLite query planner](https://www.sqlite.org/queryplanner.html),
[EXPLAIN QUERY PLAN](https://sqlite.org/eqp.html).

## Independent review

At the user's request, Claude Fable 5.1 in Cursor independently inspected the
repository and live schema read-only. It confirmed the per-position replay,
query-time index creation, planner-sensitive filter/order combinations, and
unstable implicit rowids. It recommended persistent postings and compact column
arrays with sort permutations. Its follow-up accepted bounded record-range
shards and corrected initial assumptions about PGN support and singleton counts.

Two recommendations are deliberately not accepted as production claims:

* Estimated warm/cold latency is an acceptance target, not a measured guarantee.
* Truncated fingerprints with occasional count errors are unacceptable. Fable
  subsequently described an exact alternative using build-time collision
  exceptions plus representative replay. That remains a possible storage
  optimization; the initial implementation uses exact board keys and needs no
  query-time game replay.

SQLite can change implicit rowids during VACUUM. Persistent source indexes must
not store them. Any transient mapping into the live catalog must be reconstructed
from stable identities, and stale mappings must not survive a catalog rebuild.
[SQLite VACUUM documentation](https://www.sqlite.org/lang_vacuum.html).

## Position index

### Semantics

The key contains the exact piece on every square and side to move. It excludes
castling rights, en-passant rights, and clocks, preserving the board filter's
existing semantics. Transpositions therefore share a key regardless of move
order. Index every first-child main-line position, including custom starts and
the starting position. Deduplicate repeated positions within one game. Count
partially unreadable records separately; never present incomplete coverage as
complete coverage. A clicked game is decoded once to locate its first matching
ply; postings need not store a ply for every occurrence.

The CBH traversal must match the full decoder's first-child interpretation of
push/pop blocks. The existing 700-position annotated regression corpus is also
used to compare the persistent index with fully decoded move trees.

### Storage and preparation

Use a 33-byte exact key (side plus two piece codes per byte), lexicographically
sorted. Prefix-compress adjacent keys and compress independent blocks with the
system LZFSE codec. Store delta-coded source-record postings, switching to a bitmap for dense
positions such as the starting board. A sparse directory
maps each block's first key to its offset, lengths and checksum. A lookup binary
searches this directory and decompresses only the relevant block in each shard.

Use bounded, contiguous record ranges. A shard ends at a game boundary when it
reaches the configured entry/memory budget. This avoids holding all ~930 million
game-position pairs or spilling an uncompressed global sort to disk. Shards are
written to temporary files, synced, and renamed atomically. Preparation resumes
after the last complete range. A source is queryable only after all ranges are
published. No hidden fallback to a multi-minute scan for an unprepared source.

The manifest and file headers include format/semantic versions, source identity
and source change detection, record ranges, counts and checksums. Queries reject
incomplete or damaged structures. Keep at least 4 GiB of disk headroom and check
available space during construction. Source files and the live catalog remain
intact; an interrupted build discards only its unfinished derived part.

CBH postings use physical header-record ordinals. PGN postings use game ordinals,
with a separate ordinal-to-byte-range map from the imported catalog. Never mix
PGN byte offsets with CBH ordinals. Both decoders feed the same exact-key writer.
PGN uses the pinned, MIT-licensed native chess-library SAN parser and legal move
generator; the vendored libcbh Position class itself does not provide those APIs.
[chess-library](https://github.com/Disservin/chess-library),
[PGN visitor API](https://disservin.github.io/chess-library/pages/pgn-parsing.html).

### Measurements so far

A uniform 100,000-record sample across Mega produced 7,903,088 deduplicated
game-position pairs and 6,470,665 distinct positions. The latter is not the number
of singletons; the former is not a count of unique boards.

| Sample encoding | Bytes |
|---|---:|
| Prefix-compressed 128-bit hashes plus counts/postings | 130,853,821 |
| Exact prefix keys, before LZFSE | 137,181,987 (keys only) |
| Exact keys plus counts after independent LZFSE blocks | 67,197,440 |
| Delta postings for that sample | 34,835,952 |

Straight-line extrapolation of the last two numbers suggests roughly 12 GB, but
full-scale sharing, shard boundaries, directory overhead and block layout change
that estimate. It is a capacity estimate, not a guarantee.

A separate end-to-end prototype indexed the first 100,000 physical records into
an 81 MiB file in 4.29 seconds. Warm lookup plus bitmap output/sync took 1.0–1.4 ms
for start, `1.e4`, and an absent position. Start and `1.e4` matched all results of
the existing scanner after excluding non-game CBH records. This sample is not
representative of the whole library and is not a cold or UI benchmark.

### Alternatives considered

Lichess's opening explorer demonstrates a persistent position-keyed architecture,
but its published server configuration and workload are not a desktop benchmark.
Its current source uses position prefixes and RocksDB column families; copying
that deployment wholesale would not establish an appropriate RAM/disk budget.
[Explorer source and deployment](https://github.com/lichess-org/lila-openingexplorer),
[database implementation](https://github.com/lichess-org/lila-openingexplorer/blob/master/src/db.rs).

Billions of ordinary SQLite rows add substantial per-entry overhead. RocksDB
sorted-file ingestion avoids part of incremental insertion/compaction work,
but still introduces a dependency and operational/storage choices. The bounded
immutable source files fit this read-mostly workload more directly.
[RocksDB sorted-file ingestion](https://rocksdb.org/blog/2017/02/17/bulkoad-ingest-sst-file.html).

Per-game Bloom filters reduce replay candidates but have length-dependent false
positives and still require verification, especially for common boards. A
bit-sliced design also reads multiple entire bit planes per query. It is not the
primary path. Bitmap containers remain useful for dense exact result sets and
intersections; adaptive sparse/dense containers are well established.
[Roaring bitmap paper](https://arxiv.org/abs/1402.6407).

## Metadata, sorting and paging

Imported metadata has typed column arrays and precomputed ascending
permutations for every advertised order. Descending reads the same order in
reverse. Numeric ratings remain numeric; string ranks preserve the catalog's
ordering and stable game IDs break ties. Folder/deletion overrides and current
catalog membership are applied independently of immutable position postings.

For a board/header request, intersect exact game sets first. Count the resulting
bits rather than fetching millions of SQLite rows. Sparse results can gather
their ranks and sort; dense results walk the selected permutation and test
membership until a page is full. Decode and hydrate only the displayed page.
The same algorithm must work for every sort direction and broad result set.

Name matching indexes SQLite's own `unicode61 remove_diacritics 2` tokens and
prefix ranges over distinct names, followed by intersections over compact
game/name IDs. General-purpose accent stripping was rejected during review:
it can conflate different Greek or Cyrillic letters. The native reader now uses
the actual FTS5 tokenizer API; the differential tests include Latin, decomposed
accents, Greek, Cyrillic and CJK. [FTS5 tokenizer documentation](https://www.sqlite.org/fts5.html#unicode61_tokenizer). Repeated full FTS
rowid materialization for broad prefixes is not an acceptable permanent path.
Preserve player color, tournament, Elo-band, year and result semantics, including
missing ratings, accented names, multiple words, and combinations of constraints.

Use stable keyset cursors across native imported results and the small editable
game store. Multi-source results require a correctly ordered merge; per-source
name ranks cannot be compared directly across different dictionaries. A source
index becoming ready must not silently change an already-displayed page's count.
[SQLite row-value/keyset discussion](https://www.sqlite.org/rowvalue.html).

Editable games need a small incrementally maintained exact position table. A
single draft move must never invalidate or rebuild Mega's immutable indexes.
Imported edits already create a separate draft; folder moves and deletion need
explicit membership/override handling. Build imported metadata on structural
changes, not on every autosave.

## Delivered behavior and review findings

* Every source has persistent exact main-line position postings. All eight column
  orders exist before interactive requests. Production requests cannot call the
  legacy SQLite path that builds indexes; it is explicitly named and retained
  only as an independent test oracle.
* Imported metadata lives in compact typed arrays. Editable games use a small
  indexed header table, with positions maintained transactionally. Only visible
  records become Swift study objects. Source identities never use SQLite rowids.
* Individual imported moves/deletions use `imported_overrides`, preserving the
  metadata snapshot and all source position files. Tests move a game into a new
  folder absent from the original dictionary, search its board there, and move
  it back without rebuilding. Bulk operations suppress per-row layout writes.
* Keyset cursors preserve full floating-point dates, signed 64-bit ratings and
  raw text bytes. The 15-digit SQLite text conversion caused a real paging
  failure during testing and was replaced with exact numeric roundtrips. Hex
  transport prevents legacy CP1252 bytes from breaking JSON or text ordering.
* Preparation outlives individual requests. Scrubbing notation or cancelling a
  search cancels waiting and query work, while shared preparation continues.
  Native workers detect application exit. Position builds resume at completed
  shards. Two builders cannot write the same source concurrently.
* CRCs cover position headers, fence directories and compressed blocks. Metadata
  file bodies are verified before first use in an app session, and again after
  observed changes. Damaged metadata is rebuilt automatically. Derived position
  identity/mtime changes trigger rebuilding rather than demanding reimport.
* Fatal decoder signals record the source ordinal before the helper exits. A
  subsequent attempt quarantines that record, continues, and reports incomplete
  coverage. Cancellation is not treated as corrupt input. Fault-injection tests
  verify this distinction and completed-checkpoint reuse.
* A malformed local payload cannot block every library page. Pending saved-game
  position work yields when an import owns SQLite's writer lock. Incomplete or
  pending position coverage is reported alongside results.
* Background generation cleanup retains the current and previous metadata
  generations, protecting active native readers with shared locks. Build-only
  row/name buffers are released before mapping the output for verification.

Fable independently reviewed the architecture, position files, metadata and
Swift integration. Its concrete findings drove the lifecycle, cursor, integrity,
identity and overlay fixes above. Its claim that default FTS5 treats all symbols
as token characters was checked against SQLite's documentation rather than
accepted: the documented defaults are categories L*, N* and Co.

## Final measurements

Machine: 16 GiB RAM, 8 CPUs. Library: **11,757,636 games**, including
11,741,260 imported Mega header rows and 16,376 saved games. The Mega source has
11,743,083 physical records, including non-game records.

Preparation is separate from query latency:

| Work | Measured result |
|---|---:|
| Full exact CBH position build | 641.2 s |
| Active v2 position files | 10,248,000,767 bytes (9.54 GiB) |
| Active imported metadata files | 2,220,695,298 bytes (2.07 GiB) |
| First saved-game backfill + metadata preparation/checks, positions reused | 226.0 s |
| Final metadata rebuild with SQLite's tokenizer + integrity check | 151.5 s |
| Native PGN index of 16,376 real exported games / 1,381,001 plies | 1.10 s; zero unreadable games |

The full CBH build time was measured for the initial exact format. The final
format adds dense bitmap containers and fence checksums; its files were produced
by a validating conversion, with complete starting-board and 1.e4 posting sets
compared byte-for-byte. The conversion time was not separately captured.
The PGN measurement is a finite real-game sample, not a ten-million-game PGN
preparation measurement or a linear scalability guarantee. Variations/comments
were omitted from this exported throughput corpus; separate fidelity fixtures
exercise those cases. Peak RSS for the initial full builds was not captured
because the sandbox rejected the `/usr/bin/time -l` system query. No claimed
peak-memory number is inferred from reserved buffer sizes.

Final **Swift service** timings include preparation-readiness checks, native
query/count/order, local saved-game filtering, merge, and visible study objects.
These are warm/ordinary filesystem-cache measurements; they exclude SwiftUI
rendering and the 100 ms notation-scrubbing debounce.

| Operation | Median | Largest of 3 passes |
|---|---:|---:|
| Date sort | 29.1 ms | 31.0 ms |
| Player sort | 34.6 ms | 117.8 ms |
| White Elo sort | 31.8 ms | 65.0 ms |
| Black Elo sort | 32.2 ms | 46.2 ms |
| Tournament sort | 30.1 ms | 32.4 ms |
| Result sort | 28.8 ms | 29.1 ms |
| Move-count sort | 33.4 ms | 129.1 ms |
| Round sort | 32.5 ms | 42.1 ms |
| Both Elo >= 2400 | 63.9 ms | 111.5 ms |
| Broad name prefix A | 95.3 ms | 96.2 ms |
| Starting board | 144.7 ms | 147.4 ms |
| Board after 1.e4 | 167.1 ms | 210.2 ms |

For **64 distinct board positions not previously queried through the service**:
p50 **94.8 ms**, p95 **151.1 ms**, maximum **220.0 ms**. A separate 1,000-position
corpus used the full CBH decoder and independently replayed its moves with
chess-library. Every lookup included its originating source record. Native
position lookup p50 was **41.9 ms**, p95 **55.2 ms**, p99 **56.7 ms**, maximum
**368.2 ms**. The median result count was one; the largest was 534,411.
No completed-result cache or database replay was used to answer these queries.

The original target of sub-100 ms warm p95 for the complete board-to-page path
has **not** been met: the measured service p95 is 151 ms, and the UI adds debounce
and rendering. This still replaces minute-scale scans with roughly tenths of a
second. No cold-cache p95 or precisely instrumented rendered-UI latency is claimed.

The installed app was relaunched and its About panel verified as **1.20.0 (48)**.
The visible smoke check exercised all eight column headers in both directions
against all 11,757,636 games, page 201–400, and a combined player/White Elo/year
filter (509 matches). Every sort had populated rows and no busy indicator at the
first accessibility observation after clicking. Click-through-observation times
were 0.78–1.04 s; these include UI automation settling and accessibility capture,
so they are not precise app latency measurements.

The inline reference inspector followed Praggnanandhaa–Nakamura through plies
13, 12, 11, 10, 9, 8, and 0, with Mega match counts 1, 71, 58, 50, 455, 2,375,
and 11,734,395 respectively. Stepping through the boards produced populated
results at the first observation (0.92–1.24 s including automation); the first
inspector opening took 2.44 s including automation. Reference pagination showed
201–400 of 11,734,395. Switching to Candidates 2026 returned its 56 starting
positions and the original game at ply 13. The UI was also checked visually.

The single Mega result at 7.Ne5, Kona–Chassard, is a verified transposition:
its preview shows 1.Nf3 h6 2.g3 Nf6 3.d4 e6 4.Bg2 Be7 5.c4 O-O 6.Nc3 d5
7.Ne5, reaching the same pieces and side to move as the working game's different
move order. The preview opened at that position; closing it preserved the
working game and ply. Mega's 4,481 incomplete-coverage warning remained visible.

## Validation and reproduction

* `scripts/check_catalog.sh`: catalog migration, imports, all mixed-library
  sort orders/directions/pages, 700 annotated main-line positions, transpositions,
  saved-game edits, folder/delete overlays, damaged-metadata recovery, malformed
  payloads/cursors, cancellation and preparation lifetime. Passed.
* `scripts/check_chessbase_import.sh`: annotation/game fidelity, special moves,
  archive validation/truncation, async import and restart, and batches above
  10,000 records. Passed.
* `scripts/check_position_index.sh`: decoder signal/quarantine/resume, immutable
  checkpoints, build exclusion, fence corruption and invalid completion bounds.
  Passed.
* `python3 scripts/check_interactive_native.py <LucentChessCBH>`: 48 native/SQLite
  differential cases across three pages, all eight sorts in both directions,
  the 65,536/65,537 sparse/dense boundary, integer/date/raw-text cursors, Unicode
  prefix parity, overlays and body corruption. Passed.
* `scripts/bench_interactive.sh --prepare <catalog.sqlite> [--corpus <json>]`
  prepares derived indexes and measures the actual Swift service. This command
  writes derived library data and is not a read-only audit.
* `scripts/PositionCorpusBench.cpp` is a read-only corpus generator/checker. Build
  it with the same libcbh sources and linker flags as `PositionIndexChecks.cpp`,
  then pass the CBH path, completed position directory and output JSON path.

## Remaining costs and next steps

1. New imports and bulk collection changes rebuild the global metadata snapshot.
   Individual folder moves/deletions and ordinary autosaves avoid that cost.
   Incremental metadata segments would remove this remaining preparation cliff.
2. A persistent query helper retaining validated fence directories and metadata
   mappings is the next likely latency improvement. Fresh CLI processes currently
   repeat directory validation and startup work; it should be measured against
   the existing bounded-memory/cancellation behavior before adoption.
3. Large independent reference preparations can run concurrently in separate
   windows. A global preparation resource budget and measured peak RSS remain
   useful follow-up work; record/shard buffers are bounded within each builder.
4. Exact positions require substantial extra disk space. The app preserves 4 GiB
   of headroom. Previous metadata generations add up to another ~2 GiB here.
   Old SQLite indexes and the legacy result cache have not been destructively
   compacted; reclaiming their pages needs a separately validated migration with
   sufficient disk space and a recovery copy.
5. Fully cold storage behavior and rendered UI latency remain unmeasured. Some
   damaged source games have only readable-prefix coverage and may fail to open.
   Position matching intentionally ignores rights/clocks and excludes variations;
   this is board filtering, not full legal-position equivalence.
