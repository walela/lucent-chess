# Indexed database validation — 1.18.0

Measured locally on 2026-09-13 using the release compiler settings.

## Real source import

MegaBase2026-Update01.cbv: 10,738 games indexed in 0.883 seconds, including hashing, archive extraction, managed source copy, indexing, and the first page query. Three sampled records were opened and matched their indexed headers. The source database is not included in this repository.

## Ten million record stress test

The corpus repeats four existing annotation-fixture CBH records to reach exactly 10,000,000 records. It exercises index size and query cardinality, not the diversity or decoding fidelity of ten million distinct games. Only metadata is indexed; full games open on demand.

Final Swift `DatabaseCatalog.page` measurements, including result count and construction of 200 game previews:

| Operation | Matching records | Seconds |
| --- | ---: | ---: |
| All games | 10,000,000 | 0.0043 |
| Broad text search | 2,500,000 | 0.6448 |
| Same search within a collection | 2,500,000 | 2.8908 |

The initial index build took 949 seconds with a peak reader RSS of 297 MiB and a 7.1 GiB SQLite database. Those ingestion measurements preceded the final addition of collection membership to the full-text index; they are a baseline, not final-build ingestion timing. The full ten-million-record full-text index was then rebuilt with that change before the final Swift query measurements above. Broad searches previously took 42 seconds; the query now chooses the ordering index for dense matches. Additional filters and first-use sort-index creation can take longer.

Run `scripts/check_catalog.sh` for collection creation, source deduplication, on-demand CBH/PGN fidelity, prefix search scoped to a collection, bounded pagination, migration, draft persistence, and cancellation regressions. An optional CBV path adds a real-source import check. `scripts/benchmark_catalog.py` generates a fresh ten-million-record corpus after building the helper and records its ingestion and SQL page timings. `scripts/CatalogReadBench.swift` measures the Swift catalog against that corpus.

A separate 11,250-game legacy JSON migration retained every game and the original JSON. Migration took 17.6 seconds; reopening the migrated library took 0.005 seconds. Migration is a one-time conversion; future indexed imports do not decode every move tree.
