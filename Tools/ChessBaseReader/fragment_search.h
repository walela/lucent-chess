// SPDX-License-Identifier: GPL-2.0-or-later
#pragma once
#include "interactive_catalog.h"

// Positional fragment search in the style of database search masks: a "Look
// for" board of pieces that must stand on their squares, an "Or" board of
// which at least one placement must hold, an "Exclude" board of placements
// that must not occur, optional mirroring, and a window of moves in which the
// fragment must persist for a number of consecutive plies. Unlike exact board
// searches this has no index; every main line in scope is replayed once per
// distinct mask and the resulting game bitmap is cached by the caller.
namespace lucent_fragments {
using lucent_positions::Key;
using lucent_positions::Bytes;
using lucent_catalog::JSONValues;
namespace fs = std::filesystem;

// Piece codes follow the position key: 1-6 white K Q R B N P, 9-14 black, 7 empty.
constexpr uint16_t whiteMask = 0b0000'0000'0111'1110, blackMask = 0b0111'1110'0000'0000, emptyMask = 1 << 7;
inline uint16_t pieceMask(char c) {
    switch (c) {
    case 'K': return 1 << 1; case 'Q': return 1 << 2; case 'R': return 1 << 3; case 'B': return 1 << 4; case 'N': return 1 << 5; case 'P': return 1 << 6;
    case 'k': return 1 << 9; case 'q': return 1 << 10; case 'r': return 1 << 11; case 'b': return 1 << 12; case 'n': return 1 << 13; case 'p': return 1 << 14;
    case 'A': return whiteMask; case 'a': return blackMask; case '_': return emptyMask;
    default: throw std::runtime_error("Invalid search mask piece.");
    }
}
inline unsigned codeAt(const Key& key, unsigned square) { return square & 1 ? key[1 + square / 2] & 15 : key[1 + square / 2] >> 4; }

struct Check { uint8_t square; uint16_t allowed; };
struct Fragment {
    std::vector<Check> required;      // Look for and Exclude, merged per square.
    std::vector<Check> alternatives;  // Or board: at least one must hold.
    int side = -1;
    bool matches(const Key& key) const {
        if (side >= 0 && key[0] != side) return false;
        for (const auto& check : required) if (!(check.allowed >> codeAt(key, check.square) & 1)) return false;
        if (alternatives.empty()) return true;
        for (const auto& check : alternatives) if (check.allowed >> codeAt(key, check.square) & 1) return true;
        return false;
    }
};

// Horizontal mirroring swaps ranks and colours (a sacrifice on h7 also finds
// one on h2); vertical mirroring swaps the a and h wings.
inline uint16_t swapColours(uint16_t mask) { return uint16_t(((mask & whiteMask) << 8) | ((mask & blackMask) >> 8) | (mask & emptyMask)); }
inline Fragment mirrored(const Fragment& fragment, bool horizontal, bool vertical) {
    auto transform = [&](Check check) {
        unsigned rank = check.square / 8, file = check.square % 8;
        if (horizontal) { rank = 7 - rank; check.allowed = swapColours(check.allowed); }
        if (vertical) file = 7 - file;
        check.square = uint8_t(rank * 8 + file);
        return check;
    };
    Fragment result;
    for (auto check : fragment.required) result.required.push_back(transform(check));
    for (auto check : fragment.alternatives) result.alternatives.push_back(transform(check));
    result.side = fragment.side < 0 || !horizontal ? fragment.side : 1 - fragment.side;
    return result;
}

struct Mask {
    std::vector<Fragment> variants;
    uint32_t firstPly = 0, lastPly = UINT32_MAX, length = 1;

    // "look": 64 characters a1..h8 ('.' any). "or"/"exclude": 64 comma-separated
    // sets of piece letters. Jokers: 'A' any white man, 'a' any black man, '_' empty.
    explicit Mask(const JSONValues& request) {
        std::array<uint16_t, 64> allowed; allowed.fill(0xFFFF);
        std::string look = request.get("look");
        if (look.size() != 64) throw std::runtime_error("The search mask must describe 64 squares.");
        for (unsigned s = 0; s < 64; ++s) if (look[s] != '.') allowed[s] &= pieceMask(look[s]);
        auto sets = [&](const std::string& text) {
            std::vector<std::string> result(1);
            for (char c : text) { if (c == ',') result.emplace_back(); else result.back().push_back(c); }
            if (result.size() != 64) throw std::runtime_error("The search mask must describe 64 squares.");
            return result;
        };
        if (request.has("exclude")) {
            auto exclude = sets(request.get("exclude"));
            for (unsigned s = 0; s < 64; ++s) for (char c : exclude[s]) allowed[s] &= uint16_t(~pieceMask(c));
        }
        Fragment base;
        for (unsigned s = 0; s < 64; ++s) if (allowed[s] != 0xFFFF) base.required.push_back({uint8_t(s), allowed[s]});
        if (request.has("or")) {
            auto alternatives = sets(request.get("or"));
            for (unsigned s = 0; s < 64; ++s) if (!alternatives[s].empty()) { uint16_t mask = 0; for (char c : alternatives[s]) mask |= pieceMask(c); base.alternatives.push_back({uint8_t(s), mask}); }
        }
        if (base.required.empty() && base.alternatives.empty()) throw std::runtime_error("Place at least one piece on the search board.");
        for (const auto& check : base.required) if (!check.allowed) throw std::runtime_error("A square both requires and excludes the same piece.");
        // Move n covers the positions after White's and after Black's nth move.
        auto integer = [&](const std::string& key, uint32_t fallback) { auto text = request.get(key); if (text.empty()) return fallback; auto value = std::stoll(text); if (value < 0 || value > 10000) throw std::runtime_error("Move limits must be between 0 and 10000."); return uint32_t(value); };
        length = std::max<uint32_t>(1, integer("length", 1));
        // A streak of two or more plies has both sides on move, so the side
        // constraint would never hold; it only applies to single-ply fragments.
        auto side = request.get("side"); base.side = length > 1 ? -1 : side == "w" ? 0 : side == "b" ? 1 : -1;
        bool horizontal = request.get("mirrorH") == "1", vertical = request.get("mirrorV") == "1";
        variants.push_back(base);
        if (horizontal) variants.push_back(mirrored(base, true, false));
        if (vertical) variants.push_back(mirrored(base, false, true));
        if (horizontal && vertical) variants.push_back(mirrored(base, true, true));
        auto first = integer("first", 0), last = integer("last", 0);
        firstPly = first <= 1 ? 0 : 2 * first - 1;
        lastPly = last == 0 ? UINT32_MAX : 2 * last;
        if (lastPly < firstPly) throw std::runtime_error("The last move must not precede the first move.");
    }
};

// Consecutive-ply streaks for one game. A streak survives only inside the move window.
struct Streaks {
    const Mask& mask; std::vector<uint32_t> counts; bool found = false;
    explicit Streaks(const Mask& m) : mask(m), counts(m.variants.size(), 0) {}
    void feed(const Key& key, uint32_t ply) {
        if (found) return;
        if (ply < mask.firstPly || ply > mask.lastPly) { std::fill(counts.begin(), counts.end(), 0); return; }
        for (size_t v = 0; v < counts.size(); ++v) {
            if (mask.variants[v].matches(key)) { if (++counts[v] >= mask.length) { found = true; return; } }
            else counts[v] = 0;
        }
    }
};
struct Found {};

inline void writeBitmap(const fs::path& output, const std::vector<uint64_t>& bits, uint64_t skipped) {
    uint64_t count = 0; for (auto word : bits) count += std::popcount(word);
    lucent_positions::File file(output); Bytes header{'L', 'C', 'B', 'I', 'T', '0', '0', '1'};
    lucent_positions::put(header, count, 8); lucent_positions::put(header, skipped, 8); lucent_positions::put(header, bits.size(), 8); file.write(header);
    for (size_t i = 0; i < bits.size(); i += 8192) { Bytes chunk; for (size_t j = i; j < std::min(bits.size(), i + 8192); ++j) lucent_positions::put(chunk, bits[j], 8); file.write(chunk); }
    file.sync();
}

// Records that crashed the decoder while the exact index was built. Skipping
// them keeps a multi-threaded scan from dying on a known-bad record.
inline std::set<uint32_t> quarantined(const fs::path& positions, uint32_t total) {
    std::set<uint32_t> result; auto path = positions / "decoder-crashes.bin";
    if (!fs::exists(path)) return result;
    auto data = lucent_positions::readText(path); if (data.size() % 8) throw std::runtime_error("Invalid decoder quarantine file.");
    for (size_t i = 0; i < data.size(); i += 8) { auto record = lucent_positions::number(reinterpret_cast<const uint8_t*>(data.data() + i), 4); if (record < total) result.insert(uint32_t(record)); }
    return result;
}

template <typename Decode>
inline void scan(uint32_t total, const std::set<uint32_t>& skip, const fs::path& output, const Decode& makeWorker) {
    auto started = std::chrono::steady_clock::now(); auto parent = getppid();
    size_t threads = std::max<size_t>(1, std::min<size_t>(8, std::thread::hardware_concurrency()));
    std::vector<std::vector<uint64_t>> partial(threads, std::vector<uint64_t>((uint64_t(total) + 63) / 64));
    std::atomic<uint32_t> next{0}, scanned{0}, matches{0}, unreadable{0}; std::atomic<bool> stop{false};
    std::vector<std::exception_ptr> failures(threads);
    constexpr uint32_t chunk = 2048;
    {
        std::vector<std::jthread> pool;
        for (size_t t = 0; t < threads; ++t) pool.emplace_back([&, t] {
            try {
                auto decode = makeWorker();
                for (uint32_t begin; (begin = next.fetch_add(chunk)) < total && !stop.load();) {
                    uint32_t end = std::min(total, begin + chunk), found = 0, failed = 0;
                    for (uint32_t record = begin; record < end; ++record) {
                        if (skip.contains(record)) { ++failed; continue; }
                        int status = decode(record);
                        if (status > 0) { partial[t][record / 64] |= uint64_t(1) << (record % 64); ++found; }
                        else if (status < 0) ++failed;
                    }
                    scanned += end - begin; matches += found; unreadable += failed;
                }
            } catch (...) { failures[t] = std::current_exception(); stop = true; }
        });
        auto reported = started;
        while (scanned.load() < total && !stop.load()) {
            std::this_thread::sleep_for(std::chrono::milliseconds(100));
            if (getppid() != parent) { stop = true; break; }
            auto now = std::chrono::steady_clock::now();
            if (now - reported >= std::chrono::milliseconds(400)) {
                reported = now;
                std::cout << "{\"scanned\":" << scanned.load() << ",\"total\":" << total << ",\"matches\":" << matches.load()
                          << ",\"seconds\":" << std::chrono::duration<double>(now - started).count() << "}\n" << std::flush;
            }
        }
    }
    for (auto failure : failures) if (failure) std::rethrow_exception(failure);
    if (getppid() != parent) throw std::runtime_error("The application closed during the position search.");
    if (scanned.load() < total) throw std::runtime_error("The position search stopped early.");
    std::vector<uint64_t> bits(partial[0].size());
    for (const auto& part : partial) for (size_t w = 0; w < bits.size(); ++w) bits[w] |= part[w];
    writeBitmap(output, bits, unreadable.load());
    std::cout << "{\"scanned\":" << total << ",\"total\":" << total << ",\"matches\":" << matches.load()
              << ",\"seconds\":" << std::chrono::duration<double>(std::chrono::steady_clock::now() - started).count() << "}\n" << std::flush;
}

// Ordinals are CBH record indexes, exactly as in the exact position index,
// whose stamp and completion marker guard against a changed source.
inline void scanCBH(const std::string& path, const fs::path& positions, const fs::path& requestPath, const fs::path& output) {
    JSONValues request(lucent_positions::readText(requestPath)); Mask mask(request);
    if (!lucent_positions::readText(positions / "source.txt").starts_with(lucent_positions::sourceStamp(path, true))) throw std::runtime_error("Source positions need preparation or the source changed.");
    CatalogMappedFile index(path);
    if (index.size < 46 || (index.size - 46) / 46 > UINT32_MAX) throw std::runtime_error("Invalid CBH source size.");
    uint32_t total = uint32_t((index.size - 46) / 46), indexed = 0;
    if (!(std::istringstream(lucent_positions::readText(positions / "complete.txt")) >> indexed) || indexed != total) throw std::runtime_error("This source's position index is not ready.");
    const std::string stem = path.substr(0, path.size() - 4), game = stem + ".cbg", annotation = stem + ".cba";
    scan(total, quarantined(positions, total), output, [&] {
        auto decoder = std::make_shared<CbhGameDecoder>(game.c_str(), annotation.c_str());
        if (decoder->decode_header() != OK) throw std::runtime_error("Could not open CBH position decoder.");
        return [&, decoder](uint32_t record) -> int {
            if (index.number(46 + size_t(record) * 46, 1) & 2) return 0; // non-game record
            Streaks streaks(mask);
            try {
                auto plies = decoder->visitMainline(uint32_t(index.number(46 + size_t(record) * 46 + 1, 4)),
                    [&](const Position& p, uint32_t ply) { streaks.feed(lucent_positions::fromPosition(p), ply); if (streaks.found) throw Found{}; });
                return plies < 0 ? -1 : 0;
            } catch (const Found&) { return 1; }
            catch (...) { return -1; }
        };
    });
}

// PGN ordinals follow records.bin from the prepared position index, so
// deletions since preparation keep their original ordinals.
inline void scanPGN(const std::string& path, const fs::path& positions, const fs::path& requestPath, const fs::path& output) {
    JSONValues request(lucent_positions::readText(requestPath)); Mask mask(request);
    if (!lucent_positions::readText(positions / "source.txt").starts_with(lucent_positions::sourceStamp(path, false))) throw std::runtime_error("Source positions need preparation or the source changed.");
    auto map = lucent_positions::readText(positions / "records.bin"); if (map.size() % 16) throw std::runtime_error("Invalid PGN record map.");
    uint64_t total = map.size() / 16, indexed = 0;
    if (!(std::istringstream(lucent_positions::readText(positions / "complete.txt")) >> indexed) || indexed != total) throw std::runtime_error("This source's position index is not ready.");
    const auto sourceSize = fs::file_size(path);
    scan(uint32_t(total), {}, output, [&] {
        auto input = std::make_shared<std::ifstream>(path, std::ios::binary);
        if (!*input) throw std::runtime_error("Missing managed PGN source.");
        return [&, input](uint32_t record) -> int {
            auto p = reinterpret_cast<const uint8_t*>(map.data()) + size_t(record) * 16;
            uint64_t offset = lucent_positions::number(p, 8), length = lucent_positions::number(p + 8, 8);
            if (offset > sourceSize || length > sourceSize - offset || length > 64 * 1024 * 1024) return -1;
            input->clear(); input->seekg(std::streamoff(offset));
            std::string text(size_t(length), '\0');
            if (!input->read(text.data(), std::streamsize(text.size()))) return -1;
            std::istringstream stream(text); lucent_positions::PGNVisitor visitor;
            try { chess::pgn::StreamParser parser(stream); if (parser.readGames(visitor) || visitor.failed || visitor.games != 1) return -1; }
            catch (...) { return -1; }
            Streaks streaks(mask);
            for (uint32_t ply = 0; ply < visitor.keys.size(); ++ply) { streaks.feed(visitor.keys[ply], ply); if (streaks.found) return 1; }
            return 0;
        };
    });
}
} // namespace lucent_fragments
