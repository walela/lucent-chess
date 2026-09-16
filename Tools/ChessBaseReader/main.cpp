// SPDX-License-Identifier: GPL-2.0-or-later
#include "common.h"
#include "cbh.h"
#include <fstream>
#include <iomanip>
#include <iostream>
#include <sstream>
#include <stdexcept>
#include <sys/resource.h>
#include <unistd.h>
#include <sqlite3.h>
#include <ctime>
#include <algorithm>
#include "catalog_index.h"
#include "cbh_decode_game.h"
#include "position_index.h"
#include "interactive_catalog.h"
#include "fragment_search.h"

// CBH text uses Windows-1252. Escape it into ASCII JSON for the Swift reader.
static std::string jsonQuoted(const std::string& text) {
    static const unsigned cp1252[32] = {
        0x20ac,0x81,0x201a,0x192,0x201e,0x2026,0x2020,0x2021,
        0x2c6,0x2030,0x160,0x2039,0x152,0x8d,0x17d,0x8f,
        0x90,0x2018,0x2019,0x201c,0x201d,0x2022,0x2013,0x2014,
        0x2dc,0x2122,0x161,0x203a,0x153,0x9d,0x17e,0x178
    };
    std::ostringstream out;
    out << '"';
    for (unsigned char c : text) {
        if (c == '"' || c == '\\') out << '\\' << c;
        else if (c >= 32 && c < 127) out << c;
        else out << "\\u" << std::hex << std::setw(4) << std::setfill('0')
                 << (c >= 128 && c < 160 ? cp1252[c - 128] : unsigned(c));
    }
    return out.str() + '"';
}

static std::string square(byte value) {
    if (value >= 64) throw std::runtime_error("Invalid annotation square");
    return std::string(1, 'a' + value % 8) + char('1' + value / 8);
}

static void writeMove(std::ostream& out, const AnnotatedMove& move) {
    std::string before, after;
    std::vector<unsigned> nags;
    auto append = [](std::string& target, const std::string& text) {
        if (!target.empty()) target += '\n';
        target += text;
    };
    for (const auto& comment : move.comments) {
        if (auto c = std::get_if<TextBeforeComment>(&comment)) append(before, c->text);
        else if (auto c = std::get_if<TextAfterComment>(&comment)) append(after, c->text);
        else if (auto c = std::get_if<SymbolComment>(&comment)) {
            for (auto n : {c->symbol, c->evaluation, c->prefix}) if (n) nags.push_back(n);
        } else if (auto c = std::get_if<ArrowComment>(&comment)) {
            char color = c->color == "green" ? 'G' : c->color == "yellow" ? 'Y' : 'R';
            append(after, "[%cal " + std::string(1, color) + square(c->from) + square(c->to) + "]");
        } else if (auto c = std::get_if<SquareComment>(&comment)) {
            char color = c->color == "green" ? 'G' : c->color == "yellow" ? 'Y' : 'R';
            append(after, "[%csl " + std::string(1, color) + square(c->sq) + "]");
        }
    }
    out << "{\"from\":" << unsigned(move.from) << ",\"to\":" << unsigned(move.to)
        << ",\"promote\":" << unsigned(move.promote)
        << ",\"before\":" << jsonQuoted(before) << ",\"after\":" << jsonQuoted(after) << ",\"nags\":[";
    for (size_t i = 0; i < nags.size(); ++i) out << (i ? "," : "") << nags[i];
    out << "]}";
}

static void writeGame(std::ostream& out, const GameReturnValue& game) {
    auto name = [](const std::string& last, const std::string& first) {
        return last + (first.empty() ? "" : ", " + first);
    };
    unsigned eco = game.eco ? (game.eco - 1) / 131 : 0;
    std::ostringstream ecoText;
    if (game.eco && eco < 500) ecoText << char('A' + eco / 100) << std::setw(2) << std::setfill('0') << eco % 100;
    const char* results[] = {"*", "1-0", "0-1", "1/2-1/2"};
    out << "{\"white\":" << jsonQuoted(name(game.whiteName, game.whiteFirstName))
        << ",\"black\":" << jsonQuoted(name(game.blackName, game.blackFirstName))
        << ",\"event\":" << jsonQuoted(game.eventTitle) << ",\"site\":" << jsonQuoted(game.eventPlace)
        << ",\"year\":" << game.gameDate.year << ",\"month\":" << game.gameDate.month << ",\"day\":" << game.gameDate.day
        << ",\"round\":" << jsonQuoted(game.round ? std::to_string(game.round) + (game.subround ? "." + std::to_string(game.subround) : "") : "")
        << ",\"whiteElo\":" << game.whiteElo << ",\"blackElo\":" << game.blackElo
        << ",\"eco\":" << jsonQuoted(ecoText.str()) << ",\"result\":" << jsonQuoted(results[game.result < 4 ? game.result : 0])
        << ",\"fen\":" << jsonQuoted(game.startFen) << ",\"moves\":[";
    for (size_t i = 0; i < game.annotatedMoves.size(); ++i) {
        if (i) out << ',';
        writeMove(out, game.annotatedMoves[i]);
    }
    out << "]}";
}

int main(int argc, char** argv) {
    if (argc == 3 && std::string(argv[1]) == "--verify-catalog-metadata") {
        try { lucent_catalog::verifyMetadata(argv[2]); return 0; }
        catch (const std::exception& e) { std::cerr << e.what() << '\n'; return 1; }
    }
    if (argc == 5 && std::string(argv[1]) == "--catalog-source-scope") {
        try { lucent_catalog::sourceScope(argv[2], argv[3], argv[4]); return 0; }
        catch (const std::exception& e) { std::cerr << e.what() << '\n'; return 1; }
    }
    if (argc == 5 && std::string(argv[1]) == "--query-catalog-metadata") {
        try { lucent_catalog::queryMetadata(argv[2], argv[3], argv[4]); return 0; }
        catch (const std::exception& e) { std::cerr << e.what() << '\n'; return 1; }
    }
    if (argc == 5 && std::string(argv[1]) == "--query-position-tree") {
        try { lucent_catalog::queryPositionTree(argv[2], argv[3], argv[4]); return 0; }
        catch (const std::exception& e) { std::cerr << e.what() << '\n'; return 1; }
    }
    if (argc == 5 && std::string(argv[1]) == "--prepare-catalog-metadata") {
        try { lucent_catalog::buildMetadata(argv[2], argv[3], argv[4]); return 0; }
        catch (const std::exception& e) { std::cerr << e.what() << '\n'; return 1; }
    }
    if (argc == 6 && std::string(argv[1]) == "--prepare-pgn-positions") {
        try { lucent_positions::buildPGN(argv[2], argv[3], argv[4], argv[5]); return 0; }
        catch (const std::exception& e) { std::cerr << e.what() << '\n'; return 1; }
    }
    if (argc == 5 && std::string(argv[1]) == "--prepare-cbh-positions") {
        try { lucent_positions::buildCBH(argv[2], argv[3], uint32_t(std::stoull(argv[4]))); return 0; }
        catch (const std::exception& e) { std::cerr << e.what() << '\n'; return 1; }
    }
    // Positional fragment search over one source: <source> <positions dir> <request.json> <output.bits>
    if (argc == 6 && std::string(argv[1]) == "--scan-cbh-fragment") {
        try { lucent_fragments::scanCBH(argv[2], argv[3], argv[4], argv[5]); return 0; }
        catch (const std::exception& e) { std::cerr << e.what() << '\n'; return 1; }
    }
    if (argc == 6 && std::string(argv[1]) == "--scan-pgn-fragment") {
        try { lucent_fragments::scanPGN(argv[2], argv[3], argv[4], argv[5]); return 0; }
        catch (const std::exception& e) { std::cerr << e.what() << '\n'; return 1; }
    }
    if (argc == 5 && std::string(argv[1]) == "--query-position-index") {
        try { lucent_positions::query(argv[2], argv[3], argv[4]); return 0; }
        catch (const std::exception& e) { std::cerr << e.what() << '\n'; return 1; }
    }
    // Decode a sparse list of records (one index per stdin line) into one JSON
    // file. Reference trees need the main lines of a page of matching games.
    if (argc == 4 && std::string(argv[1]) == "--decode-records") {
        rlimit cpu{60, 60}, memory{1024ULL * 1024 * 1024, 1024ULL * 1024 * 1024};
        setrlimit(RLIMIT_CPU, &cpu);
        setrlimit(RLIMIT_AS, &memory);
        alarm(90);
        dup2(STDERR_FILENO, STDOUT_FILENO);
        try {
            CbhCodec codec;
            if (codec.open(argv[2]) != OK) throw std::runtime_error("Could not read this CBH database and its companion files.");
            std::ofstream out(argv[3]);
            out.exceptions(std::ios::failbit | std::ios::badbit);
            out << "{\"games\":[";
            size_t accepted = 0, skipped = 0, moves = 0, requested = 0;
            uint64_t record;
            while (std::cin >> record) {
                if (++requested > 1024) throw std::runtime_error("Too many records requested.");
                if (record >= codec.numGames() || codec.setGameIndex(static_cast<uint32_t>(record)) != OK) { ++skipped; continue; }
                GameReturnValue game{};
                if (codec.parseNext(game) != OK) { ++skipped; continue; }
                if (game.annotatedMoves.size() > 500000 - moves)
                    throw std::runtime_error("These games contain unusually large annotations.");
                moves += game.annotatedMoves.size();
                std::ostringstream encoded;
                writeGame(encoded, game);
                if (accepted++) out << ',';
                out << "{\"record\":" << record << ',' << encoded.str().substr(1);
            }
            out << "],\"skipped\":" << skipped << '}';
            return 0;
        } catch (const std::exception& error) {
            std::cerr << error.what() << '\n';
            return 1;
        }
    }
    if (argc != 5) return 2;
    if (std::string(argv[1]) == "--index-pgn") {
        try { return indexPGN(argv[2], argv[3], argv[4]); }
        catch (const std::exception& e) { std::cerr << e.what() << '\n'; return 1; }
    }
    if (std::string(argv[1]) == "--index") {
        try { return indexDatabase(argv[2], argv[3], argv[4]); }
        catch (const std::exception& e) { std::cerr << e.what() << '\n'; return 1; }
    }
    if (std::string(argv[1]) == "--match-position") {
        try {
            const std::string path=argv[2], stem=path.substr(0,path.size()-4);
            CatalogMappedFile index(path);
            const auto gamePath=stem+".cbg",annotationPath=stem+".cba";
            CbhGameDecoder decoder(gamePath.c_str(),annotationPath.c_str());
            if(decoder.decode_header()!=OK || !decoder.configureMatch(argv[3]))throw std::runtime_error("Could not prepare board search.");
            FILE* output=fdopen(dup(STDOUT_FILENO),"w");
            dup2(STDERR_FILENO,STDOUT_FILENO);
            uint64_t record;
            while(std::cin>>record) {
                alarm(10);
                int result=-2;
                try { if(record<(index.size-46)/46)result=decoder.matchRecord(index.number(46+record*46+1,4)); } catch(...){}
                alarm(0);fprintf(output,"%d\n",result);fflush(output);
            }
            fclose(output);return 0;
        } catch(const std::exception& e) {std::cerr<<e.what()<<'\n';return 1;}
    }
    rlimit cpu{60, 60}, memory{1024ULL * 1024 * 1024, 1024ULL * 1024 * 1024};
    rlimit output{256ULL * 1024 * 1024, 256ULL * 1024 * 1024};
    setrlimit(RLIMIT_CPU, &cpu);
    setrlimit(RLIMIT_AS, &memory);
    setrlimit(RLIMIT_FSIZE, &output);
    alarm(90);
    // Upstream diagnostics go to stderr; only the output file carries JSON.
    dup2(STDERR_FILENO, STDOUT_FILENO);
    try {
        CbhCodec codec;
        if (codec.open(argv[1]) != OK) throw std::runtime_error("Could not read this CBH database and its companion files.");
        const size_t start = std::stoull(argv[3]);
        const size_t count = std::stoull(argv[4]);
        if (start > codec.numGames() || count == 0 || count > 256)
            throw std::runtime_error("Invalid import batch range.");
        const size_t end = start + std::min(count, codec.numGames() - start);
        if (start < end && codec.setGameIndex(static_cast<uint32_t>(start)) != OK)
            throw std::runtime_error("Could not seek to the next import batch.");
        std::ofstream out(argv[2]);
        out.exceptions(std::ios::failbit | std::ios::badbit);
        out << "{\"games\":[";
        size_t accepted = 0, skipped = 0, moves = 0;
        for (size_t i = start; i < end; ++i) {
            GameReturnValue game{};
            if (codec.parseNext(game) != OK) { ++skipped; continue; }
            // Bound each reader invocation, without limiting the whole database.
            if (game.annotatedMoves.size() > 500000 - moves)
                throw std::runtime_error("This batch contains unusually large game annotations.");
            moves += game.annotatedMoves.size();
            std::ostringstream encoded;
            writeGame(encoded, game);
            if (accepted++) out << ',';
            out << encoded.str();
        }
        out << "],\"skipped\":" << skipped
            << ",\"next\":" << end << ",\"total\":" << codec.numGames() << '}';
        return 0;
    } catch (const std::exception& error) {
        std::cerr << error.what() << '\n';
        return 1;
    }
}
