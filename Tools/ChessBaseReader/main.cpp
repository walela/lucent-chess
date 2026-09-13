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

// CBH text uses Windows-1252. Escape it into ASCII JSON for the Swift reader.
static std::string quoted(const std::string& text) {
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
        << ",\"before\":" << quoted(before) << ",\"after\":" << quoted(after) << ",\"nags\":[";
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
    out << "{\"white\":" << quoted(name(game.whiteName, game.whiteFirstName))
        << ",\"black\":" << quoted(name(game.blackName, game.blackFirstName))
        << ",\"event\":" << quoted(game.eventTitle) << ",\"site\":" << quoted(game.eventPlace)
        << ",\"year\":" << game.gameDate.year << ",\"month\":" << game.gameDate.month << ",\"day\":" << game.gameDate.day
        << ",\"round\":" << quoted(game.round ? std::to_string(game.round) + (game.subround ? "." + std::to_string(game.subround) : "") : "")
        << ",\"whiteElo\":" << game.whiteElo << ",\"blackElo\":" << game.blackElo
        << ",\"eco\":" << quoted(ecoText.str()) << ",\"result\":" << quoted(results[game.result < 4 ? game.result : 0])
        << ",\"fen\":" << quoted(game.startFen) << ",\"moves\":[";
    for (size_t i = 0; i < game.annotatedMoves.size(); ++i) {
        if (i) out << ',';
        writeMove(out, game.annotatedMoves[i]);
    }
    out << "]}";
}

int main(int argc, char** argv) {
    if (argc != 3) return 2;
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
        if (codec.numGames() > 10000) throw std::runtime_error("Import at most 10,000 games at a time. Split this database in ChessBase first.");
        std::ofstream out(argv[2]);
        out.exceptions(std::ios::failbit | std::ios::badbit);
        out << "{\"games\":[";
        size_t accepted = 0, skipped = 0, moves = 0;
        for (size_t i = 0; i < codec.numGames(); ++i) {
            GameReturnValue game{};
            if (codec.parseNext(game) != OK) { ++skipped; continue; }
            moves += game.annotatedMoves.size();
            if (moves > 500000) throw std::runtime_error("This database has too many moves for one import. Split it into smaller databases first.");
            std::ostringstream encoded;
            writeGame(encoded, game);
            if (accepted++) out << ',';
            out << encoded.str();
        }
        out << "],\"skipped\":" << skipped << '}';
        return 0;
    } catch (const std::exception& error) {
        std::cerr << error.what() << '\n';
        return 1;
    }
}
