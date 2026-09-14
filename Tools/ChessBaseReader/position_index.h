// SPDX-License-Identifier: GPL-2.0-or-later
#pragma once
#include <array>
#include <bit>
#include <chrono>
#include <compression.h>
#include <filesystem>
#include <functional>
#include <map>
#include <sys/statvfs.h>
#include <sys/file.h>
#include <csignal>
#include <set>
#include <zlib.h>
#include "chess-library/chess.hpp"

// Immutable, exact position postings. IDs are source record ordinals, never
// SQLite rowids. Each game belongs to one shard; repetitions count only once.
namespace lucent_positions {
namespace fs = std::filesystem;
using Bytes = std::vector<uint8_t>;
using Key = std::array<uint8_t, 33>;
constexpr uint32_t version = 2;
constexpr size_t headerSize = 64, fenceSize = 53, entryBudget = 20'000'000;
constexpr uint64_t diskReserve = 4ULL * 1024 * 1024 * 1024;

inline uint64_t number(const uint8_t* p, size_t n) {
    uint64_t v = 0;
    for (size_t i = 0; i < n; ++i) v |= uint64_t(p[i]) << (8 * i);
    return v;
}
inline void put(Bytes& b, uint64_t n, size_t bytes) {
    for (size_t i = 0; i < bytes; ++i) b.push_back(uint8_t(n >> (8 * i)));
}
inline void varint(Bytes& b, uint32_t n) {
    do { b.push_back(uint8_t(n & 127) | (n >= 128 ? 128 : 0)); n >>= 7; } while (n);
}
inline uint32_t varint(const uint8_t*& p, const uint8_t* end) {
    uint32_t result = 0;
    for (unsigned shift = 0; shift < 35; shift += 7) {
        if (p == end || (shift == 28 && *p > 15)) throw std::runtime_error("Invalid position index integer.");
        uint8_t b = *p++;
        result |= uint32_t(b & 127) << shift;
        if (!(b & 128)) return result;
    }
    throw std::runtime_error("Invalid position index integer.");
}
inline uint32_t checksum(const uint8_t* p, size_t n) {
    return uint32_t(crc32(0, p, uInt(n)));
}
inline void checkSpace(const fs::path& directory, uint64_t extra = 0) {
    struct statvfs s{};
    if (statvfs(directory.c_str(), &s) != 0 || uint64_t(s.f_bavail) * s.f_frsize < diskReserve + extra)
        throw std::runtime_error("Preparation paused to preserve 4 GB of free disk space. Completed position parts are resumable.");
}
inline Key fromPosition(const Position& p) {
    Key key{}; key[0] = p.GetToMove();
    const auto* board = p.GetBoard();
    for (size_t s = 0; s < 64; s += 2) key[1 + s / 2] = uint8_t((board[s] << 4) | board[s + 1]);
    return key;
}
inline Key fromFEN(const std::string& fen) {
    Key key{};
    std::array<uint8_t, 64> board{}; board.fill(7);
    std::istringstream in(fen); std::string layout, side;
    if (!(in >> layout >> side) || (side != "w" && side != "b")) throw std::runtime_error("Invalid board position.");
    key[0] = side == "b";
    int rank = 7, file = 0;
    const std::string pieces = " KQRBNP  kqrbnp";
    for (char c : layout) {
        if (c == '/') { if (file != 8 || rank == 0) throw std::runtime_error("Invalid board rank."); --rank; file = 0; }
        else if (c >= '1' && c <= '8') file += c - '0';
        else {
            auto piece = pieces.find(c);
            if (piece == std::string::npos || c == ' ' || file >= 8) throw std::runtime_error("Invalid board piece.");
            board[rank * 8 + file++] = uint8_t(piece);
        }
        if (file > 8) throw std::runtime_error("Invalid board rank.");
    }
    if (rank != 0 || file != 8) throw std::runtime_error("Incomplete board position.");
    for (size_t s = 0; s < 64; s += 2) key[1 + s / 2] = uint8_t((board[s] << 4) | board[s + 1]);
    return key;
}
inline Key fromBoard(const chess::Board& board) {
    Key key{}; key[0] = board.sideToMove() == chess::Color::BLACK;
    // chess-library orders types pawn..king; libcbh uses king..pawn.
    constexpr uint8_t mapping[] = {6, 5, 4, 3, 2, 1, 14, 13, 12, 11, 10, 9, 7};
    for (int s = 0; s < 64; s += 2) {
        auto a = int(board.at(chess::Square(s))), b = int(board.at(chess::Square(s + 1)));
        if (a < 0 || a > 12 || b < 0 || b > 12) throw std::runtime_error("Invalid native board.");
        key[1 + s / 2] = uint8_t(mapping[a] << 4 | mapping[b]);
    }
    return key;
}

struct File {
    FILE* handle;
    explicit File(const fs::path& path) : handle(fopen(path.c_str(), "wb+")) {
        if (!handle) throw std::runtime_error("Could not create position index.");
    }
    ~File() { if (handle) fclose(handle); }
    void write(const Bytes& bytes) {
        if (fwrite(bytes.data(), 1, bytes.size(), handle) != bytes.size()) throw std::runtime_error("Could not write position index (disk full?).");
    }
    uint64_t offset() const { auto p = ftello(handle); if (p < 0) throw std::runtime_error("Index seek failed."); return p; }
    void sync() { if (fflush(handle) || fsync(fileno(handle))) throw std::runtime_error("Could not sync position index."); }
};
struct BuildLock {
    int fd = -1;
    explicit BuildLock(const fs::path& directory) {
        fd = ::open((directory/"build.lock").c_str(),O_RDWR|O_CREAT,0600);
        if(fd<0)throw std::runtime_error("Could not lock index preparation.");
        if(flock(fd,LOCK_EX|LOCK_NB)!=0){::close(fd);fd=-1;throw std::runtime_error("This source is already being prepared.");}
    }
    ~BuildLock(){if(fd>=0){flock(fd,LOCK_UN);::close(fd);}}
};
struct Entry { Key key; uint32_t record; };

inline fs::path partPath(const fs::path& dir, uint32_t begin) {
    char name[40]; snprintf(name, sizeof name, "part-%010u.lcpi", begin); return dir / name;
}

inline void writePart(const fs::path& dir, uint32_t begin, uint32_t end, uint32_t total,
                      uint32_t skipped, std::vector<Entry>& entries) {
    checkSpace(dir);
    std::sort(entries.begin(), entries.end(), [](const Entry& a, const Entry& b) {
        return a.key < b.key || (a.key == b.key && a.record < b.record);
    });
    auto final = partPath(dir, begin), partial = fs::path(final.string() + ".partial");
    File out(partial); out.write(Bytes(headerSize));
    Bytes fences, block;
    Key previous{}, first{};
    uint64_t unique = 0;
    unsigned blockEntries = 0;
    auto flush = [&] {
        if (block.empty()) return;
        Bytes compressed(block.size() + 4096);
        size_t n = compression_encode_buffer(compressed.data(), compressed.size(), block.data(), block.size(), nullptr, COMPRESSION_LZFSE);
        bool raw = n == 0 || n >= block.size();
        if (raw) compressed = block; else compressed.resize(n);
        fences.insert(fences.end(), first.begin(), first.end());
        put(fences, out.offset(), 8); put(fences, compressed.size() | (raw ? 0x80000000U : 0), 4);
        put(fences, block.size(), 4); put(fences, checksum(block.data(), block.size()), 4);
        out.write(compressed); block.clear(); blockEntries = 0; previous = {};
        if (out.offset() % (16 * 1024 * 1024) < compressed.size()) checkSpace(dir);
    };
    for (size_t i = 0; i < entries.size();) {
        size_t j = i + 1;
        while (j < entries.size() && entries[j].key == entries[i].key) ++j;
        if (blockEntries == 0) first = entries[i].key;
        size_t prefix = 0;
        if (blockEntries) while (prefix < 33 && entries[i].key[prefix] == previous[prefix]) ++prefix;
        block.push_back(uint8_t(prefix));
        block.insert(block.end(), entries[i].key.begin() + prefix, entries[i].key.end());
        bool dense = j - i > uint64_t(end - begin) / 16;
        Bytes postings; uint32_t last = 0;
        if(dense){
            postings.resize((uint64_t(end-begin)+7)/8);
            for(size_t k=i;k<j;++k){auto relative=entries[k].record-begin;postings[relative/8]|=uint8_t(1)<<(relative%8);}
        }else{
            postings.reserve(j-i+4);
            for(size_t k=i;k<j;++k){varint(postings,entries[k].record-last);last=entries[k].record;}
        }
        varint(block, uint32_t(j - i)); varint(block, uint32_t(postings.size()<<1)|(dense?1:0));
        block.insert(block.end(), postings.begin(), postings.end());
        previous = entries[i].key; ++unique; ++blockEntries;
        if (blockEntries >= 256 || block.size() >= 65536) flush();
        i = j;
    }
    flush();
    uint64_t directory = out.offset(); out.write(fences);
    Bytes header{'L','C','P','O','S','0','0','1'};
    put(header, version, 4); put(header, begin, 4); put(header, end, 4); put(header, skipped, 4);
    put(header, entries.size(), 8); put(header, unique, 8); put(header, directory, 8);
    put(header, fences.size() / fenceSize, 4); put(header, total, 4); put(header, checksum(fences.data(),fences.size()), 4);
    put(header, checksum(header.data(), header.size()), 4);
    if (fseeko(out.handle, 0, SEEK_SET)) throw std::runtime_error("Could not finish index header.");
    out.write(header); out.sync(); fs::rename(partial, final);
}

class Part {
    CatalogMappedFile file;
    uint64_t directory;
    uint32_t blocks;
    const uint8_t* bytes;
    const uint8_t* fence(size_t index) const { return bytes + directory + index * fenceSize; }
public:
    uint32_t begin, end, total, skipped;
    explicit Part(const fs::path& path) : file(path.string()), bytes(file.bytes) {
        if (file.size < headerSize || memcmp(bytes, "LCPOS001", 8) || number(bytes + 8, 4) != version ||
            checksum(bytes, 60) != number(bytes + 60, 4)) throw std::runtime_error("Invalid position index header. Prepare this source again.");
        begin = uint32_t(number(bytes + 12, 4)); end = uint32_t(number(bytes + 16, 4));
        skipped = uint32_t(number(bytes + 20, 4)); total = uint32_t(number(bytes + 52, 4));
        directory = number(bytes + 40, 8); blocks = uint32_t(number(bytes + 48, 4));
        if (begin > end || end > total || skipped > end - begin || directory < headerSize || directory > file.size ||
            uint64_t(blocks) * fenceSize != file.size - directory) throw std::runtime_error("Incomplete position index.");
        if(checksum(bytes+directory,file.size-directory)!=number(bytes+56,4))throw std::runtime_error("Damaged position directory.");
        for(uint32_t i=1;i<blocks;++i)if(memcmp(fence(i-1),fence(i),33)>=0)throw std::runtime_error("Invalid position directory order.");
    }
    void lookup(const Key& target, std::vector<uint64_t>& bits) const {
        if (!blocks) return;
        size_t low = 0, high = blocks;
        while (low < high) { size_t mid = (low + high) / 2; if (memcmp(fence(mid), target.data(), 33) <= 0) low = mid + 1; else high = mid; }
        if (!low) return;
        const auto* f = fence(low - 1);
        uint64_t offset = number(f + 33, 8);
        uint32_t encoded = uint32_t(number(f + 41, 4)), size = encoded & 0x7fffffff, rawSize = uint32_t(number(f + 45, 4));
        if (offset < headerSize || offset > directory || size > directory - offset || rawSize > 64 * 1024 * 1024)
            throw std::runtime_error("Invalid position index block.");
        Bytes raw(rawSize);
        if (encoded & 0x80000000) { if (size != rawSize) throw std::runtime_error("Invalid raw block."); memcpy(raw.data(), bytes + offset, size); }
        else if (compression_decode_buffer(raw.data(), raw.size(), bytes + offset, size, nullptr, COMPRESSION_LZFSE) != raw.size())
            throw std::runtime_error("Could not decode position index.");
        if (checksum(raw.data(), raw.size()) != number(f + 49, 4)) throw std::runtime_error("Damaged position index block.");
        auto p = raw.data(); const auto* limit = p + raw.size(); Key key{};bool firstEntry=true;
        while (p < limit) {
            unsigned prefix = *p++;
            if (prefix > 33 || size_t(limit - p) < 33 - prefix) throw std::runtime_error("Invalid position key.");
            memcpy(key.data() + prefix, p, 33 - prefix); p += 33 - prefix;
            if(firstEntry && (prefix!=0 || memcmp(key.data(),f,33)!=0))throw std::runtime_error("Position directory key does not match its block.");firstEntry=false;
            const uint8_t* cursor = p;
            auto count = varint(cursor, limit), lengthCode = varint(cursor, limit);bool dense=lengthCode&1;auto length=lengthCode>>1;p = const_cast<uint8_t*>(cursor);
            if (length > size_t(limit - p)) throw std::runtime_error("Invalid position postings.");
            if (key > target) return;
            if (key == target) {
                if(dense){
                    if(length!=(uint64_t(end-begin)+7)/8)throw std::runtime_error("Invalid dense posting size.");
                    uint32_t observed=0;
                    for(uint32_t i=0;i<length;++i){
                        auto byte=p[i];uint64_t record=uint64_t(begin)+uint64_t(i)*8;
                        if(record>=end || (end-record<8 && (byte>>(end-record))))throw std::runtime_error("Invalid dense source record.");
                        observed+=std::popcount(byte);auto word=record/64;unsigned shift=record%64;
                        if(word>=bits.size())throw std::runtime_error("Invalid dense source record.");bits[word]|=uint64_t(byte)<<shift;
                        if(shift>56 && byte>>(64-shift)){if(word+1>=bits.size())throw std::runtime_error("Invalid dense source record.");bits[word+1]|=uint64_t(byte)>>(64-shift);}
                    }
                    if(observed!=count)throw std::runtime_error("Invalid dense posting count.");return;
                }
                uint32_t record = 0; const uint8_t* post = p; const auto* postEnd = p + length;
                for (uint32_t i = 0; i < count; ++i) {
                    auto delta = varint(post, postEnd);
                    if ((i && !delta) || delta > UINT32_MAX - record) throw std::runtime_error("Invalid record delta.");
                    record += delta;
                    if (record < begin || record >= end || record / 64 >= bits.size()) throw std::runtime_error("Invalid source record.");
                    bits[record / 64] |= uint64_t(1) << (record % 64);
                }
                if (post != postEnd) throw std::runtime_error("Invalid posting length.");
                return;
            }
            p += length;
        }
    }
};

inline std::string readText(const fs::path& path) {
    std::ifstream f(path); return std::string(std::istreambuf_iterator<char>(f), {});
}
inline void atomicText(const fs::path& path, const std::string& value) {
    auto temp = fs::path(path.string() + ".partial"); File f(temp); f.write(Bytes(value.begin(), value.end())); f.sync(); fs::rename(temp, path);
}
inline std::string sourceStamp(const std::string& source, bool cbh) {
    std::string result = "lucent-exact-position-2-mainline-3\n" + source + "\n";
    if(!cbh)result+="chess-library:53e6a841dcda7059a2af363d85f785ef1817304a\n";
    auto append = [&](const fs::path& path) {
        result += path.string() + ":";
        if (fs::exists(path)) result += std::to_string(fs::file_size(path)) + ":" + std::to_string(std::chrono::duration_cast<std::chrono::nanoseconds>(fs::last_write_time(path).time_since_epoch()).count());
        result += "\n";
    };
    if (cbh) for (const char* extension : {".cbh", ".cbg", ".cba"}) { fs::path p(source); p.replace_extension(extension); append(p); }
    else append(source);
    return result;
}

// A fatal decoder signal ends this process; it never resumes unsafe C++ state.
// The next attempt quarantines that exact record and exposes incomplete coverage.
// Cancellation (SIGTERM) and out-of-memory termination (SIGKILL) are not quarantined.
inline volatile sig_atomic_t decodingRecord = 0, decodingActive = 0;
inline int crashDescriptor = -1;
inline void recordFatalSignal(int signal) {
    if (decodingActive && crashDescriptor >= 0) {
        uint32_t record = uint32_t(decodingRecord);
        uint8_t bytes[8];
        for (unsigned i=0;i<4;++i) {bytes[i]=uint8_t(record>>(8*i));bytes[4+i]=uint8_t(uint32_t(signal)>>(8*i));}
        (void)::write(crashDescriptor,bytes,sizeof(bytes));
    }
    _exit(128+signal);
}
struct CrashGuard {
    static constexpr int signals[] = {SIGSEGV,SIGBUS,SIGABRT,SIGFPE,SIGILL};
    struct sigaction old[5]{};
    std::set<uint32_t> quarantined;
    explicit CrashGuard(const fs::path& directory,uint32_t total) {
        auto path=directory/"decoder-crashes.bin";
        if(fs::exists(path)){
            auto data=readText(path);if(data.size()%8)throw std::runtime_error("Invalid decoder recovery marker.");
            for(size_t i=0;i<data.size();i+=8){auto record=number(reinterpret_cast<const uint8_t*>(data.data()+i),4);if(record>=total)throw std::runtime_error("Invalid quarantined source record.");quarantined.insert(uint32_t(record));}
        }
        crashDescriptor=::open(path.c_str(),O_WRONLY|O_CREAT|O_APPEND,0600);
        if(crashDescriptor<0)throw std::runtime_error("Could not create decoder recovery marker.");
        struct sigaction action{};action.sa_handler=recordFatalSignal;sigemptyset(&action.sa_mask);
        for(size_t i=0;i<5;++i)sigaction(signals[i],&action,&old[i]);
    }
    ~CrashGuard(){decodingActive=0;for(size_t i=0;i<5;++i)sigaction(signals[i],&old[i],nullptr);::close(crashDescriptor);crashDescriptor=-1;}
};

// The decoder callback returns true for a fully readable game. Valid prefixes
// are retained for damaged records and the incomplete-record count is exposed.
inline void build(const fs::path& directory, const std::string& stamp, uint32_t total,
                  const std::function<bool(uint32_t, std::vector<Key>&)>& decode,
                  const std::function<bool()>& unchanged, bool ownLock = true) {
    fs::create_directories(directory);
    auto lock=ownLock?std::make_unique<BuildLock>(directory):nullptr;
    auto parent=getppid();
    if (fs::exists(directory / "source.txt") && readText(directory / "source.txt") != stamp)
        throw std::runtime_error("The source changed. Use a fresh position index directory.");
    atomicText(directory / "source.txt", stamp);
    CrashGuard crashGuard(directory,total);
    uint32_t begin = 0, allSkipped = 0;
    while (begin < total && fs::exists(partPath(directory, begin))) {
        Part part(partPath(directory, begin));
        if (part.begin != begin || part.end <= begin || part.total != total) throw std::runtime_error("Invalid position preparation checkpoint.");
        begin = part.end; allSkipped += part.skipped;
    }
    auto started = std::chrono::steady_clock::now();
    while (begin < total) {
        checkSpace(directory);
        std::vector<Entry> entries; entries.reserve(std::min<size_t>(entryBudget + 4097, size_t(total - begin) * 90));
        uint32_t end = begin, skipped = 0;
        while (end < total && entries.size() < entryBudget && end - begin < 500000) {
            if(end%1000==0 && getppid()!=parent)throw std::runtime_error("The application closed during position preparation.");
            std::vector<Key> keys;
            if(crashGuard.quarantined.contains(end)) ++skipped;
            else {
                decodingRecord=sig_atomic_t(end);decodingActive=1;
                bool readable=false;
                try {readable=decode(end,keys);} catch (...) {decodingActive=0;throw;}
                decodingActive=0;
                if(!readable)++skipped;
            }
            std::sort(keys.begin(), keys.end()); keys.erase(std::unique(keys.begin(), keys.end()), keys.end());
            for (const auto& key : keys) entries.push_back({key, end});
            ++end;
        }
        if (!unchanged()) throw std::runtime_error("Source changed during position preparation.");
        writePart(directory, begin, end, total, skipped, entries);
        allSkipped += skipped; begin = end;
        std::cout << "{\"prepared\":" << end << ",\"total\":" << total << ",\"skipped\":" << allSkipped
                  << ",\"seconds\":" << std::chrono::duration<double>(std::chrono::steady_clock::now() - started).count() << "}\n" << std::flush;
    }
    if (!unchanged()) throw std::runtime_error("Source changed during position preparation.");
    atomicText(directory / "complete.txt", std::to_string(total) + "\n" + std::to_string(allSkipped) + "\n");
}

inline void buildCBH(const std::string& path, const fs::path& directory, uint32_t limit = UINT32_MAX) {
    const std::string stem = path.substr(0, path.size() - 4), game = stem + ".cbg", annotation = stem + ".cba";
    CatalogMappedFile index(path);
    if (index.size < 46 || (index.size - 46) / 46 > UINT32_MAX) throw std::runtime_error("Invalid CBH source size.");
    uint32_t count = uint32_t(std::min<uint64_t>((index.size - 46) / 46, limit));
    const auto stamp = sourceStamp(path, true) + "limit:" + std::to_string(limit) + "\n";
    CbhGameDecoder decoder(game.c_str(), annotation.c_str());
    if (decoder.decode_header() != OK) throw std::runtime_error("Could not open CBH position decoder.");
    build(directory, stamp, count, [&](uint32_t record, std::vector<Key>& keys) {
        if (index.number(46 + size_t(record) * 46, 1) & 2) return true; // non-game record
        try { return decoder.visitMainline(uint32_t(index.number(46 + size_t(record) * 46 + 1, 4)),
            [&](const Position& p, uint32_t) { keys.push_back(fromPosition(p)); }) >= 0; }
        catch (...) { return false; }
    }, [&] { return sourceStamp(path, true) + "limit:" + std::to_string(limit) + "\n" == stamp; });
}

class PGNVisitor final : public chess::pgn::Visitor {
public:
    std::vector<Key> keys;
    chess::Board board;
    bool failed = false, started = false;
    unsigned games = 0;
    void startPgn() override { if (++games > 1) { failed = true; skipPgn(true); } }
    void header(std::string_view tag, std::string_view value) override {
        if (tag == "FEN") { if (!board.setFen(value)) { failed = true; skipPgn(true); } }
        if (tag == "Variant" && value != "Standard" && value != "Chess") { failed = true; skipPgn(true); }
    }
    void startMoves() override {
        started = true;
        if (board.pieces(chess::PieceType::KING, chess::Color::WHITE).count() != 1 ||
            board.pieces(chess::PieceType::KING, chess::Color::BLACK).count() != 1) {
            failed = true; skipPgn(true); return;
        }
        keys.push_back(fromBoard(board));
    }
    void move(std::string_view san, std::string_view) override {
        if (failed) return;
        try {
            if (keys.size() > 4096) throw std::runtime_error("Unusually long PGN game.");
            if (san == "--" || san == "Z0") board.makeNullMove();
            else board.makeMove(chess::uci::parseSan(board, san));
            keys.push_back(fromBoard(board));
        } catch (...) { failed = true; skipPgn(true); }
    }
    void endPgn() override { if (!started && !failed) keys.push_back(fromBoard(board)); }
};

struct ReadOnlyDB {
    sqlite3* handle = nullptr;
    explicit ReadOnlyDB(const std::string& path) {
        if (sqlite3_open_v2(path.c_str(), &handle, SQLITE_OPEN_READONLY, nullptr) != SQLITE_OK) {
            if (handle) sqlite3_close(handle);
            throw std::runtime_error("Could not read the source catalog.");
        }
        sqlite3_busy_timeout(handle, 1000);
    }
    ~ReadOnlyDB() { sqlite3_close(handle); }
};
struct ReadStatement {
    sqlite3_stmt* handle = nullptr;
    explicit ReadStatement(ReadOnlyDB& db, const char* sql) {
        if (sqlite3_prepare_v2(db.handle, sql, -1, &handle, nullptr) != SQLITE_OK) throw std::runtime_error(sqlite3_errmsg(db.handle));
    }
    ~ReadStatement() { sqlite3_finalize(handle); }
    bool next() {
        int status = sqlite3_step(handle);
        if (status == SQLITE_ROW) return true;
        if (status != SQLITE_DONE) throw std::runtime_error(sqlite3_errmsg(sqlite3_db_handle(handle)));
        return false;
    }
    void text(int index, const std::string& value) { sqlite3_bind_text(handle, index, value.c_str(), int(value.size()), SQLITE_TRANSIENT); }
};

inline void buildPGN(const std::string& path, const std::string& catalog, const std::string& sourceID, const fs::path& directory) {
    struct Range { uint64_t offset, length; };
    std::vector<Range> ranges;
    {
        // Close the SQLite snapshot before any replay or sorting work.
        ReadOnlyDB db(catalog);
        ReadStatement rows(db, "SELECT record,record_length FROM games WHERE source_id=? AND payload IS NULL ORDER BY record");
        rows.text(1, sourceID);
        while (rows.next()) {
            auto offset = sqlite3_column_int64(rows.handle, 0), length = sqlite3_column_int64(rows.handle, 1);
            if (offset < 0 || length <= 0 || (!ranges.empty() && uint64_t(offset) <= ranges.back().offset))
                throw std::runtime_error("Invalid PGN source ranges.");
            ranges.push_back({uint64_t(offset), uint64_t(length)});
        }
    }
    if (ranges.size() > UINT32_MAX) throw std::runtime_error("Too many games for this position index format.");
    Bytes recordMap;
    for (const auto& range : ranges) { put(recordMap, range.offset, 8); put(recordMap, range.length, 8); }
    fs::create_directories(directory);
    BuildLock lock(directory);
    if(fs::exists(directory/"records.bin")) {
        // Original ordinals survive deletions while preparation was paused.
        // Current metadata maps these offsets back to the surviving game IDs.
        auto previous=readText(directory/"records.bin");if(previous.size()%16)throw std::runtime_error("Invalid PGN record map.");
        recordMap.assign(previous.begin(),previous.end());ranges.clear();
        for(size_t at=0;at<recordMap.size();at+=16){Range range{number(recordMap.data()+at,8),number(recordMap.data()+at+8,8)};if(!range.length||(!ranges.empty()&&range.offset<=ranges.back().offset))throw std::runtime_error("Invalid PGN record map.");ranges.push_back(range);}
    }
    const std::string mapText(recordMap.begin(), recordMap.end());
    atomicText(directory / "records.bin", mapText);
    const auto fileStamp = sourceStamp(path, false);
    const auto stamp = fileStamp + sourceID + "\nrecords:" + std::to_string(ranges.size()) + ":" + std::to_string(checksum(recordMap.data(), recordMap.size())) + "\n";
    std::ifstream input(path, std::ios::binary);
    if (!input) throw std::runtime_error("Missing managed PGN source.");
    const auto sourceSize = fs::file_size(path);
    build(directory, stamp, uint32_t(ranges.size()), [&](uint32_t record, std::vector<Key>& keys) {
        const auto range = ranges[record];
        if (range.offset > sourceSize || range.length > sourceSize - range.offset || range.length > 64 * 1024 * 1024) return false;
        input.clear(); input.seekg(std::streamoff(range.offset));
        std::string text(size_t(range.length), '\0');
        if (!input.read(text.data(), std::streamsize(text.size()))) return false;
        std::istringstream stream(text); PGNVisitor visitor;
        try {
            chess::pgn::StreamParser parser(stream);
            auto error = parser.readGames(visitor);
            keys = std::move(visitor.keys);
            return !error && !visitor.failed && visitor.games == 1;
        } catch (...) { keys = std::move(visitor.keys); return false; }
    }, [&] { return sourceStamp(path, false) == fileStamp; },false);
}

struct IndexReadLock {
    int descriptor=-1;
    explicit IndexReadLock(const fs::path& directory){descriptor=::open((directory/"build.lock").c_str(),O_RDONLY);if(descriptor<0||flock(descriptor,LOCK_SH|LOCK_NB)){if(descriptor>=0)::close(descriptor);throw std::runtime_error("Position preparation is still running.");}}
    ~IndexReadLock(){if(descriptor>=0)::close(descriptor);}
};
inline std::vector<uint64_t> lookup(const fs::path& directory, const Key& key, uint32_t& skipped) {
    IndexReadLock readLock(directory);
    std::istringstream complete(readText(directory / "complete.txt"));
    uint64_t total = 0; if (!(complete >> total >> skipped) || total > UINT32_MAX) throw std::runtime_error("This source's position index is not ready.");
    if(total){Part first(partPath(directory,0));if(first.begin!=0 || first.total!=total)throw std::runtime_error("Invalid position index completion marker.");}
    std::vector<uint64_t> bits((total + 63) / 64);
    uint32_t start = 0, observedSkipped = 0;
    while (start < total) {
        Part part(partPath(directory, start));
        if (part.begin != start || part.end <= start || part.total != total) throw std::runtime_error("Incomplete position index parts.");
        part.lookup(key, bits); observedSkipped += part.skipped; start = part.end;
    }
    if (observedSkipped != skipped) throw std::runtime_error("Inconsistent position index counts.");
    return bits;
}
inline void query(const fs::path& directory, const std::string& fen, const fs::path& output) {
    auto started = std::chrono::steady_clock::now(); uint32_t skipped = 0;
    auto bits = lookup(directory, fromFEN(fen), skipped); uint64_t count = 0;
    for (auto word : bits) count += std::popcount(word);
    File file(output); Bytes header{'L','C','B','I','T','0','0','1'};
    put(header, count, 8); put(header, skipped, 8); put(header, bits.size(), 8); file.write(header);
    for (size_t i = 0; i < bits.size(); i += 8192) { Bytes chunk; for (size_t j = i; j < std::min(bits.size(), i + 8192); ++j) put(chunk, bits[j], 8); file.write(chunk); }
    file.sync();
    std::cout << "{\"matches\":" << count << ",\"skipped\":" << skipped << ",\"seconds\":"
              << std::chrono::duration<double>(std::chrono::steady_clock::now() - started).count() << "}\n";
}
} // namespace lucent_positions
