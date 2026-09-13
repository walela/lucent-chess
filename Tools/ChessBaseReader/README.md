# ChessBase reader

Lucent runs this GPL reader as a separate executable, `LucentChessCBH`.
It reads staged CBH companion files and writes decoded games as JSON.

Vendored libcbh: https://github.com/rolandlo/libcbh
Revision: `9641c5c3949d8fb210b17dd9aa54455645843696`
License: GPL-2.0 (upstream source notices retained).
The adapter in `main.cpp` is GPL-2.0-or-later.

Local libcbh changes:
- Use fixed-width public integer types on macOS.
- Propagate failed move decoding instead of accepting partial games.
- Read game-record lengths as unsigned bytes and reject truncated records.
- Expose the buffered reader position for record bounds checks.
- Destroy decoder subclasses through a virtual base destructor.
- Use a fixed-size starting-position buffer on Clang.
- Reject Chess960 records; Lucent supports standard chess only.

The Swift CBV unpacker follows uncbv by Antoni Boucher, GPL-3.0-or-later:
https://github.com/antoyo/uncbv
Revision: `3c18e8a7c6a30c21f945a1ab5462521c306dca57`
It validates archive paths, sizes, Huffman trees and backward references.
The uncbv license is bundled as `UNCBV-GPL-3.0.txt`.

The app requests batches of up to 256 records using the helper arguments
`database.cbh output.json start count`. Each JSON response includes `next` and
`total` record offsets. There is no total record-count limit. Per batch, the helper
allows 500,000 move tokens, 60 CPU seconds and 90 wall-clock seconds. Database
files are limited to 256 MiB per import.
Classic unencrypted CBV/CBH only. Null-move and Chess960 games are rejected.
Guiding text records are counted as skipped. Multimedia, training overlays,
extra ChessBase tags and proprietary annotations are not imported.
Windows-1252 text is decoded; other legacy code pages are not detected.
