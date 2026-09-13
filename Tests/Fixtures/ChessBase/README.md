# ChessBase import fixtures

`small.cbv` and `small/` come from uncbv tests at
`3c18e8a7c6a30c21f945a1ab5462521c306dca57` (GPL-3.0-or-later).
https://github.com/antoyo/uncbv/tree/master/tests

The variation, position, promotion and annotation databases and reference PGNs
come from libcbh gtest fixtures at
`9641c5c3949d8fb210b17dd9aa54455645843696` (GPL-2.0).
https://github.com/rolandlo/libcbh/tree/main/gtest

Upstream source notices and license copies are retained in the reader directory
and application resources. Run `./scripts/check_chessbase_import.sh` for isolated
import, archive-integrity and library-persistence checks. No installed library
is read or modified.

`annotations.cbv` packages the annotation fixture with uncompressed CBV blocks.
The upstream `small.cbv` is empty and is used only for archive-integrity checks.

`small/small.ini` retains its original CRLF bytes and is marked `-text` in
`.gitattributes` so Git cannot normalize the archive-integrity reference.
