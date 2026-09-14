// SPDX-License-Identifier: GPL-2.0-or-later
#pragma once
#include <CoreFoundation/CoreFoundation.h>
#include <unordered_map>
#include <numeric>
#include <cmath>
#include <thread>
#include "position_index.h"

namespace lucent_catalog {
using namespace lucent_positions;
enum Column : size_t { UUIDColumn, Source, Record, Folder, White, Black, Event, Title, SourceName,
    Round, Result, PlayersOffset, PlayersLength, Date, Modified, WhiteElo, BlackElo, Moves, Flags, ColumnCount };
constexpr size_t catalogHeaderSize = 512, orderCount = 8;
constexpr size_t widths[] = {16,4,8,4,4,4,4,4,4,4,4,8,4,8,8,8,8,8,4};
constexpr const char* orderNames[] = {"date", "players", "whiteElo", "blackElo", "event", "result", "moves", "round"};
using ID = std::array<uint8_t, 16>;

inline ID parseID(const std::string& text) {
    ID result{}; size_t digits = 0;
    for (char c : text) {
        if (c == '-') continue;
        int n = c >= '0' && c <= '9' ? c - '0' : c >= 'A' && c <= 'F' ? c - 'A' + 10 : c >= 'a' && c <= 'f' ? c - 'a' + 10 : -1;
        if (n < 0 || digits >= 32) throw std::runtime_error("Invalid catalog game identity.");
        result[digits / 2] |= uint8_t(n << (digits % 2 ? 0 : 4)); ++digits;
    }
    if (digits != 32) throw std::runtime_error("Invalid catalog game identity.");
    return result;
}
inline std::string idText(const ID& id) {
    const char* hex = "0123456789ABCDEF"; std::string out;
    for (size_t i = 0; i < 16; ++i) { if (i == 4 || i == 6 || i == 8 || i == 10) out += '-'; out += hex[id[i] >> 4]; out += hex[id[i] & 15]; }
    return out;
}
inline std::string json(const std::string& text) {
    const char* hex = "0123456789abcdef"; std::string out = "\"";
    for (uint8_t c : text) {
        if (c == '"' || c == '\\') { out += '\\'; out += char(c); }
        else if (c < 32) { out += "\\u00"; out += hex[c >> 4]; out += hex[c & 15]; }
        else out += char(c);
    }
    return out + '"';
}
inline std::string hex(const std::string& text) {
    static const char* digits="0123456789abcdef";std::string result;result.reserve(text.size()*2);
    for(uint8_t byte:text){result+=digits[byte>>4];result+=digits[byte&15];}return result;
}
inline std::string unhex(const std::string& text) {
    if(text.size()%2)throw std::runtime_error("Invalid sort cursor.");std::string result;
    auto digit=[](char c){if(c>='0'&&c<='9')return c-'0';if(c>='a'&&c<='f')return c-'a'+10;throw std::runtime_error("Invalid sort cursor.");};
    for(size_t i=0;i<text.size();i+=2)result+=char(digit(text[i])*16+digit(text[i+1]));return result;
}
inline std::string sqlText(sqlite3_stmt* stmt, int col) {
    const auto* text = sqlite3_column_text(stmt, col); int size = sqlite3_column_bytes(stmt, col);
    return text ? std::string(reinterpret_cast<const char*>(text), size_t(size)) : "";
}

// Use SQLite's actual tokenizer, including its Unicode/Latin-diacritic rules,
// for both the prepared name dictionary and queries. General accent stripping
// would incorrectly conflate distinct Cyrillic and Greek names.
struct NameTokenizer {
    sqlite3* db=nullptr;fts5_tokenizer methods{};Fts5Tokenizer* instance=nullptr;
    NameTokenizer(){
        if(sqlite3_open(":memory:",&db)!=SQLITE_OK)throw std::runtime_error("Could not initialize name search.");
        fts5_api* api=nullptr;sqlite3_stmt* statement=nullptr;
        if(sqlite3_prepare_v2(db,"SELECT fts5(?1)",-1,&statement,nullptr)!=SQLITE_OK){sqlite3_close(db);throw std::runtime_error("FTS5 name search is unavailable.");}
        sqlite3_bind_pointer(statement,1,&api,"fts5_api_ptr",nullptr);sqlite3_step(statement);sqlite3_finalize(statement);
        void* context=nullptr;const char* options[]={"remove_diacritics","2"};
        if(!api||api->xFindTokenizer(api,"unicode61",&context,&methods)!=SQLITE_OK||methods.xCreate(context,options,2,&instance)!=SQLITE_OK){sqlite3_close(db);throw std::runtime_error("Unicode name search is unavailable.");}
    }
    ~NameTokenizer(){if(instance)methods.xDelete(instance);if(db)sqlite3_close(db);}
};
inline std::vector<std::string> tokens(const std::string& text) {
    static thread_local NameTokenizer tokenizer;
    auto utf8=pgnHeaderUTF8(text);std::vector<std::string> result;
    int status=tokenizer.methods.xTokenize(tokenizer.instance,&result,FTS5_TOKENIZE_DOCUMENT,utf8.data(),int(utf8.size()),[](void* context,int,const char* word,int length,int,int){static_cast<std::vector<std::string>*>(context)->emplace_back(word,size_t(length));return SQLITE_OK;});
    if(status!=SQLITE_OK)throw std::runtime_error("Could not tokenize a catalog name.");
    std::sort(result.begin(),result.end());result.erase(std::unique(result.begin(),result.end()),result.end());return result;
}

struct Names {
    std::vector<std::string> values{ "" };
    std::unordered_map<std::string, uint32_t> ids{{"", 0}};
    uint32_t add(const std::string& text) {
        if (auto found = ids.find(text); found != ids.end()) return found->second;
        if (values.size() >= UINT32_MAX) throw std::runtime_error("Too many distinct catalog names.");
        uint32_t id = uint32_t(values.size()); ids.emplace(text, id); values.push_back(text); return id;
    }
    void write(const fs::path& dir) const {
        File file(dir / "names.bin"); Bytes header{'L','C','N','A','M','E','0','1'}; put(header, values.size(), 8);
        uint64_t offset = 0;
        for (const auto& value : values) { put(header, offset, 8); offset += value.size(); }
        put(header, offset, 8); file.write(header);
        Bytes buffer;
        for (const auto& value : values) { buffer.insert(buffer.end(), value.begin(), value.end()); if (buffer.size() >= 65536) { file.write(buffer); buffer.clear(); } }
        file.write(buffer); file.sync();
        std::vector<uint32_t> order(values.size()); std::iota(order.begin(),order.end(),0);
        std::sort(order.begin(),order.end(),[&](uint32_t a,uint32_t b){return values[a]<values[b];});
        File sorted(dir / "name-order.bin"); buffer.clear();
        for (auto id : order) put(buffer,id,4); sorted.write(buffer); sorted.sync();
    }
    void writeTokens(const fs::path& dir) const {
        std::vector<std::pair<std::string, uint32_t>> entries;
        for (uint32_t i = 0; i < values.size(); ++i) for (auto& token : tokens(values[i])) entries.emplace_back(std::move(token), i);
        std::sort(entries.begin(), entries.end());
        Bytes refs, text, postings;
        for (size_t i = 0; i < entries.size();) {
            size_t end = i + 1; while (end < entries.size() && entries[end].first == entries[i].first) ++end;
            put(refs, text.size(), 8); put(refs, entries[i].first.size(), 4); put(refs, end - i, 4); put(refs, postings.size(), 8);
            text.insert(text.end(), entries[i].first.begin(), entries[i].first.end());
            for (size_t j = i; j < end; ++j) put(postings, entries[j].second, 4);
            i = end;
        }
        File file(dir / "tokens.bin"); Bytes header{'L','C','T','O','K','E','N','1'};
        put(header, refs.size() / 24, 8); put(header, 32 + refs.size(), 8); put(header, 32 + refs.size() + text.size(), 8);
        file.write(header); file.write(refs); file.write(text); file.write(postings); file.sync();
    }
};

struct Row {
    ID id;
    uint32_t source, folder, white, black, event, title, sourceName, round, result;
    uint64_t record, playersOffset;
    uint32_t playersLength;
    double date, modified;
    int64_t whiteElo, blackElo, moves;
    uint32_t flags;
    uint64_t value(size_t column) const {
        switch (column) {
        case Source: return source; case Record: return record; case Folder: return folder;
        case White: return white; case Black: return black; case Event: return event;
        case Title: return title; case SourceName: return sourceName; case Round: return round;
        case Result: return result; case PlayersOffset: return playersOffset; case PlayersLength: return playersLength;
        case Date: return std::bit_cast<uint64_t>(date); case Modified: return std::bit_cast<uint64_t>(modified);
        case WhiteElo: return whiteElo; case BlackElo: return blackElo; case Moves: return moves; case Flags: return flags;
        default: throw std::runtime_error("Unknown catalog column.");
        }
    }
};
static_assert(sizeof(Row) <= 136);

inline constexpr const char* metadataFiles[] = {"catalog.bin","names.bin","name-order.bin","tokens.bin","players.bin","sources.json","groups.bin"};
inline uint32_t fileChecksum(const CatalogMappedFile& file) {
    uLong crc=0;
    for(size_t offset=0;offset<file.size;offset+=1024*1024)crc=crc32(crc,file.bytes+offset,uInt(std::min<size_t>(1024*1024,file.size-offset)));
    return uint32_t(crc);
}
inline void writeChecksums(const fs::path& dir) {
    std::ostringstream text;
    for(auto name:metadataFiles){auto size=fs::file_size(dir/name);uint32_t crc=0;if(size){CatalogMappedFile file((dir/name).string());crc=fileChecksum(file);}text<<name<<' '<<size<<' '<<crc<<'\n';}
    atomicText(dir/"checksums.txt",text.str());
}
inline void verifyMetadata(const fs::path& dir) {
    std::istringstream text(readText(dir/"checksums.txt"));
    for(auto expected:metadataFiles){std::string name;uint64_t size=0,crc=0;
        if(!(text>>name>>size>>crc)||name!=expected||crc>UINT32_MAX)throw std::runtime_error("Invalid metadata integrity manifest.");
        auto actual=fs::file_size(dir/name);uint32_t checksum=0;if(actual){CatalogMappedFile file((dir/name).string());checksum=fileChecksum(file);}
        if(actual!=size||checksum!=crc)throw std::runtime_error("Prepared database metadata is damaged. Rebuild its derived index.");
    }
    std::string extra;if(text>>extra)throw std::runtime_error("Invalid metadata integrity manifest.");
}
// Result files are disposable and owned by a single request. They do not need
// a durable fsync; immutable published indexes do.
inline void writeResult(const fs::path& path,const std::string& value) {
    std::ofstream file(path,std::ios::binary|std::ios::trunc);file.write(value.data(),std::streamsize(value.size()));file.close();
    if(!file)throw std::runtime_error("Could not return database results.");
}
inline void buildMetadata(const std::string& catalog, const fs::path& dir, const std::string& stamp) {
    fs::create_directories(dir); checkSpace(dir);
    BuildLock buildLock(dir);
    // Incomplete metadata is never served. A replacement lives in a different
    // generation directory, so this marker belongs solely to the current build.
    if (fs::exists(dir / "complete.txt")) {
        if (readText(dir / "complete.txt") == stamp) return;
        throw std::runtime_error("Use a new directory for a changed catalog generation.");
    }
    auto parent=getppid();
    Names names; Bytes players{0}; std::vector<Row> rows;
    std::string sourceJSON = "[";
    {
        ReadOnlyDB db(catalog);
        if(sqlite3_exec(db.handle,"BEGIN",nullptr,nullptr,nullptr)!=SQLITE_OK)throw std::runtime_error("Could not start catalog snapshot.");
        ReadStatement estimate(db,"SELECT coalesce(sum(count),0) FROM sources WHERE count>0 AND kind IN ('cbh','pgn')");
        if (estimate.next()) {
            auto count=sqlite3_column_int64(estimate.handle,0);
            if (count<0 || count>UINT32_MAX) throw std::runtime_error("Too many catalog records.");
            rows.reserve(size_t(count));
        }
        ReadStatement sources(db, "SELECT id,path,kind FROM sources WHERE count>0 AND kind IN ('cbh','pgn') ORDER BY id");
        bool first = true;
        while (sources.next()) {
            if (!first) sourceJSON += ','; first = false;
            sourceJSON += "{\"id\":" + json(sqlText(sources.handle,0)) + ",\"path\":" + json(sqlText(sources.handle,1)) + ",\"kind\":" + json(sqlText(sources.handle,2)) + "}";
        }
        sourceJSON += ']';
        ReadStatement query(db, "SELECT g.id,g.source_id,g.record,g.folder,g.white,g.black,g.event,g.title,g.source_name,g.round_sort,g.result,g.players,g.date,g.modified,CAST(coalesce(g.white_elo,'0') AS INTEGER),CAST(coalesce(g.black_elo,'0') AS INTEGER),g.moves,g.dirty,g.file_path IS NOT NULL,g.starter IS NOT NULL,g.source_name IS NOT NULL,g.elo_indexed,s.path,s.kind,g.record_length FROM games g JOIN sources s ON s.id=g.source_id WHERE g.payload IS NULL AND s.count>0 AND s.kind IN ('cbh','pgn') ORDER BY g.source_id,g.record,g.id");
        std::string ratingPath; std::unique_ptr<CatalogMappedFile> ratingFile;
        while (query.next()) {
            auto q = query.handle; Row r{};
            r.id = parseID(sqlText(q,0)); if(idText(r.id)!=sqlText(q,0))throw std::runtime_error("Catalog IDs must be canonical uppercase UUIDs."); r.source = names.add(sqlText(q,1));
            auto record = sqlite3_column_int64(q,2); if (record < 0) throw std::runtime_error("Invalid source record."); r.record = uint64_t(record);
            r.folder = names.add(sqlText(q,3)); r.white = names.add(sqlText(q,4)); r.black = names.add(sqlText(q,5));
            r.event = names.add(sqlText(q,6)); r.title = names.add(sqlText(q,7)); r.sourceName = names.add(sqlText(q,8));
            r.round = names.add(sqlText(q,9)); r.result = names.add(sqlText(q,10));
            auto pair = sqlText(q,11); r.playersOffset = players.size(); r.playersLength = uint32_t(pair.size()); players.insert(players.end(), pair.begin(), pair.end());
            r.date = sqlite3_column_double(q,12); r.modified = sqlite3_column_double(q,13);
            r.whiteElo = sqlite3_column_int64(q,14); r.blackElo = sqlite3_column_int64(q,15); r.moves = sqlite3_column_int64(q,16);
            if (!sqlite3_column_int(q,21)) {
                auto path=sqlText(q,22),kind=sqlText(q,23);
                if(path!=ratingPath){ratingFile=std::make_unique<CatalogMappedFile>(path);ratingPath=path;}
                if(kind=="cbh"){
                    if(r.record>(UINT64_MAX-81)/46 || 46+r.record*46+35>ratingFile->size)throw std::runtime_error("Missing ChessBase rating header.");
                    auto at=ratingFile->bytes+46+r.record*46+31;
                    r.whiteElo=((uint32_t(at[0])<<8)|at[1])&0xFFF;r.blackElo=((uint32_t(at[2])<<8)|at[3])&0xFFF;
                }else{
                    auto length=sqlite3_column_int64(q,24);
                    if(length<0||r.record>ratingFile->size||uint64_t(length)>ratingFile->size-r.record)throw std::runtime_error("Missing PGN rating header.");
                    std::istringstream headers(std::string(reinterpret_cast<const char*>(ratingFile->bytes+r.record),size_t(std::min<int64_t>(length,65536))));std::string line;
                    while(std::getline(headers,line)){
                        auto begin=line.find_first_not_of(" \t\r");if(begin==std::string::npos)continue;
                        if(line.compare(begin,3,"\xef\xbb\xbf")==0)begin+=3;
                        if(begin>=line.size()||line[begin]!='[')break;
                        auto quote=line.find('"',begin),end=line.find('"',quote==std::string::npos?line.size():quote+1);if(quote==std::string::npos||end==std::string::npos)continue;
                        auto tag=line.substr(begin+1,quote-begin-1);while(!tag.empty()&&isspace(uint8_t(tag.back())))tag.pop_back();
                        if(tag=="WhiteElo"||tag=="BlackElo"){auto value=line.substr(quote+1,end-quote-1);char* last=nullptr;errno=0;auto rating=strtoll(value.c_str(),&last,10);if(last==value.c_str())rating=0;(tag=="WhiteElo"?r.whiteElo:r.blackElo)=rating;}
                    }
                }
            }
            r.flags = (sqlite3_column_int(q,17) ? 1 : 0) | (sqlite3_column_int(q,18) ? 2 : 0) | (sqlite3_column_int(q,19) ? 4 : 0) | (sqlite3_column_int(q,20) ? 8 : 0);
            if (rows.size() >= UINT32_MAX) throw std::runtime_error("Too many catalog records.");
            rows.push_back(r);
            if(rows.size()%10000==0&&getppid()!=parent)throw std::runtime_error("Application closed during metadata preparation.");
            if (rows.size() % 500000 == 0) std::cout << "{\"phase\":\"metadata\",\"games\":" << rows.size() << "}\n" << std::flush;
        }
    }
    checkSpace(dir, uint64_t(rows.size()) * 160 + players.size());
    names.write(dir);
    { File file(dir / "players.bin"); file.write(players); file.sync(); }
    File file(dir / "catalog.bin"); file.write(Bytes(catalogHeaderSize));
    std::array<uint64_t,ColumnCount> offsets{}; std::array<uint64_t,orderCount> orders{};
    for (size_t column = 0; column < ColumnCount; ++column) {
        file.write(Bytes((8 - file.offset() % 8) % 8));
        offsets[column] = file.offset(); Bytes buffer; buffer.reserve(65536);
        for (const auto& row : rows) {
            if (column == UUIDColumn) buffer.insert(buffer.end(), row.id.begin(), row.id.end());
            else put(buffer, row.value(column), widths[column]);
            if (buffer.size() >= 65536) { file.write(buffer); buffer.clear(); }
        }
        file.write(buffer);
    }
    std::vector<uint32_t> permutation(rows.size());
    auto textFor = [&](const Row& row, size_t order) -> std::string_view {
        if (order == 1) return {reinterpret_cast<const char*>(players.data() + row.playersOffset), row.playersLength};
        return names.values[order == 4 ? row.event : order == 5 ? row.result : row.round];
    };
    for (size_t order = 0; order < orderCount; ++order) {
        std::iota(permutation.begin(), permutation.end(), 0);
        std::sort(permutation.begin(), permutation.end(), [&](uint32_t a, uint32_t b) {
            const auto& x = rows[a]; const auto& y = rows[b];
            if (order == 0) { if (x.date != y.date) return x.date < y.date; }
            else if (order == 2 || order == 3 || order == 6) {
                int64_t p = order == 2 ? x.whiteElo : order == 3 ? x.blackElo : x.moves;
                int64_t q = order == 2 ? y.whiteElo : order == 3 ? y.blackElo : y.moves;
                if (p != q) return p < q;
            } else { auto p = textFor(x,order), q = textFor(y,order); if (p != q) return p < q; }
            return x.id < y.id;
        });
        if(getppid()!=parent)throw std::runtime_error("Application closed during metadata preparation.");
        file.write(Bytes((8 - file.offset() % 8) % 8));
        orders[order] = file.offset(); Bytes buffer; buffer.reserve(65536);
        for (auto id : permutation) { put(buffer,id,4); if (buffer.size() >= 65536) { file.write(buffer); buffer.clear(); } }
        file.write(buffer);
        std::cout << "{\"phase\":\"sort\",\"order\":" << json(orderNames[order]) << "}\n" << std::flush;
    }
    Bytes header{'L','C','C','A','T','0','0','1'}; put(header,2,4); put(header,ColumnCount,4); put(header,rows.size(),8); put(header,names.values.size(),8);
    for (auto offset : offsets) put(header,offset,8);
    header.resize(256); for (auto offset : orders) put(header,offset,8);
    put(header,file.offset(),8); header.resize(catalogHeaderSize - 4); put(header,checksum(header.data(),header.size()),4);
    if (fseeko(file.handle,0,SEEK_SET)) throw std::runtime_error("Could not finish metadata header."); file.write(header); file.sync();
    std::cout << "{\"phase\":\"names\",\"names\":" << names.values.size() << "}\n" << std::flush;
    names.writeTokens(dir); atomicText(dir / "sources.json",sourceJSON);
    Bytes groups;
    for (size_t begin=0;begin<rows.size();) {
        size_t end=begin+1;uint32_t folder=rows[begin].folder;
        while(end<rows.size() && rows[end].source==rows[begin].source){if(rows[end].folder!=folder)folder=UINT32_MAX;++end;}
        put(groups,rows[begin].source,4);put(groups,begin,4);put(groups,end,4);put(groups,folder,4);begin=end;
    }
    {File output(dir/"groups.bin");output.write(groups);output.sync();}
    // The verification pass maps the completed files. Release build-only
    // columns first so verification does not double the preparation working set.
    std::vector<Row>().swap(rows);Bytes().swap(players);std::vector<uint32_t>().swap(permutation);
    names.ids.clear();names.ids.rehash(0);std::vector<std::string>().swap(names.values);
    writeChecksums(dir);
    if(getppid()!=parent)throw std::runtime_error("Application closed during metadata preparation.");
    atomicText(dir / "complete.txt",stamp);
}
class Dictionary {
    CatalogMappedFile file, sorted, tokenFile;
    uint64_t dataStart, tokenCount, tokenText, tokenPosts;
public:
    uint32_t count;
    explicit Dictionary(const fs::path& dir): file((dir/"names.bin").string()), sorted((dir/"name-order.bin").string()), tokenFile((dir/"tokens.bin").string()) {
        if(file.size<24 || memcmp(file.bytes,"LCNAME01",8))throw std::runtime_error("Invalid name dictionary.");
        auto n=number(file.bytes+8,8);
        if(n>UINT32_MAX || n+1>(file.size-16)/8 || sorted.size!=n*4)throw std::runtime_error("Invalid name dictionary size.");
        count=uint32_t(n);dataStart=16+(n+1)*8;
        if(number(file.bytes+16+n*8,8)!=file.size-dataStart)throw std::runtime_error("Truncated name dictionary.");
        if(tokenFile.size<32 || memcmp(tokenFile.bytes,"LCTOKEN1",8))throw std::runtime_error("Invalid name search index.");
        tokenCount=number(tokenFile.bytes+8,8);tokenText=number(tokenFile.bytes+16,8);tokenPosts=number(tokenFile.bytes+24,8);
        if(tokenCount>(tokenFile.size-32)/24 || tokenText!=32+tokenCount*24 || tokenPosts<tokenText || tokenPosts>tokenFile.size)throw std::runtime_error("Truncated name search index.");
    }
    std::string_view text(uint32_t id) const {
        if(id>=count)throw std::runtime_error("Invalid name identity.");
        auto begin=number(file.bytes+16+uint64_t(id)*8,8),end=number(file.bytes+24+uint64_t(id)*8,8);
        if(end<begin || end>file.size-dataStart)throw std::runtime_error("Invalid name range.");
        return {reinterpret_cast<const char*>(file.bytes+dataStart+begin),size_t(end-begin)};
    }
    uint32_t find(std::string_view value) const {
        uint32_t low=0,high=count;
        while(low<high){auto mid=low+(high-low)/2;auto id=uint32_t(number(sorted.bytes+uint64_t(mid)*4,4));if(text(id)<value)low=mid+1;else high=mid;}
        if(low==count)return UINT32_MAX;
        auto id=uint32_t(number(sorted.bytes+uint64_t(low)*4,4));return text(id)==value?id:UINT32_MAX;
    }
    std::string_view token(uint64_t index) const {
        auto p=tokenFile.bytes+32+index*24;
        auto offset=number(p,8),length=number(p+8,4);
        if(offset>tokenPosts-tokenText || length>tokenPosts-tokenText-offset)throw std::runtime_error("Invalid search token.");
        return {reinterpret_cast<const char*>(tokenFile.bytes+tokenText+offset),size_t(length)};
    }
    std::vector<uint64_t> prefix(const std::string& word) const {
        std::vector<uint64_t> bits((uint64_t(count)+63)/64);uint64_t low=0,high=tokenCount;
        while(low<high){auto mid=(low+high)/2;if(token(mid)<word)low=mid+1;else high=mid;}
        for(uint64_t i=low;i<tokenCount && token(i).starts_with(word);++i){
            auto p=tokenFile.bytes+32+i*24;auto n=number(p+12,4),offset=number(p+16,8);
            if(offset>tokenFile.size-tokenPosts || n>(tokenFile.size-tokenPosts-offset)/4)throw std::runtime_error("Invalid name postings.");
            for(uint64_t j=0;j<n;++j){auto id=number(tokenFile.bytes+tokenPosts+offset+j*4,4);if(id>=count)throw std::runtime_error("Invalid search name.");bits[id/64]|=uint64_t(1)<<(id%64);}
        }
        return bits;
    }
};

struct JSONValues {
    std::map<std::string,std::string> values;
    explicit JSONValues(const std::string& text) {
        if(text.size()>16*1024*1024)throw std::runtime_error("Catalog request is too large.");
        sqlite3* db=nullptr;
        if(sqlite3_open(":memory:",&db)!=SQLITE_OK)throw std::runtime_error("Could not parse catalog request.");
        sqlite3_stmt* q=nullptr;
        if(sqlite3_prepare_v2(db,"SELECT key,CAST(value AS TEXT) FROM json_each(?)",-1,&q,nullptr)!=SQLITE_OK){sqlite3_close(db);throw std::runtime_error("JSON support is unavailable.");}
        sqlite3_bind_text(q,1,text.data(),int(text.size()),SQLITE_TRANSIENT);
        int status;
        while((status=sqlite3_step(q))==SQLITE_ROW)values[sqlText(q,0)]=sqlText(q,1);
        sqlite3_finalize(q);sqlite3_close(db);
        if(status!=SQLITE_DONE)throw std::runtime_error("Invalid catalog request JSON.");
    }
    std::string get(const std::string& key,const std::string& fallback="") const {auto it=values.find(key);return it==values.end()?fallback:it->second;}
    bool has(const std::string& key) const {auto it=values.find(key);return it!=values.end() && !it->second.empty();}
};

class Snapshot {
    struct ReadLock {
        int descriptor=-1;
        explicit ReadLock(const fs::path& dir){descriptor=::open((dir/"build.lock").c_str(),O_RDONLY);if(descriptor<0||flock(descriptor,LOCK_SH|LOCK_NB)){if(descriptor>=0)::close(descriptor);throw std::runtime_error("Database metadata is being prepared. Retry shortly.");}}
        ~ReadLock(){if(descriptor>=0)::close(descriptor);}
    } readLock;
    CatalogMappedFile file, players;
    std::array<uint64_t,ColumnCount> offsets;
    std::array<uint64_t,orderCount> orders;
public:
    Dictionary names;
    uint32_t count;
    explicit Snapshot(const fs::path& dir):readLock(dir),file((dir/"catalog.bin").string()),players((dir/"players.bin").string()),names(dir){
        auto p=file.bytes;
        if(!fs::exists(dir/"complete.txt") || file.size<catalogHeaderSize || memcmp(p,"LCCAT001",8) || number(p+8,4)!=2 || number(p+12,4)!=ColumnCount || checksum(p,catalogHeaderSize-4)!=number(p+catalogHeaderSize-4,4))throw std::runtime_error("Catalog preparation is incomplete.");
        auto n=number(p+16,8);if(n>UINT32_MAX || number(p+24,8)!=names.count || number(p+320,8)!=file.size)throw std::runtime_error("Invalid catalog snapshot size.");count=uint32_t(n);
        for(size_t i=0;i<ColumnCount;++i){offsets[i]=number(p+32+i*8,8);if(offsets[i]<catalogHeaderSize || offsets[i]%8 || offsets[i]>file.size || uint64_t(count)*widths[i]>file.size-offsets[i])throw std::runtime_error("Invalid catalog column.");}
        for(size_t i=0;i<orderCount;++i){orders[i]=number(p+256+i*8,8);if(orders[i]<catalogHeaderSize || orders[i]%8 || orders[i]>file.size || uint64_t(count)*4>file.size-orders[i])throw std::runtime_error("Invalid catalog order.");}
    }
    const uint32_t* u32(Column c) const {return reinterpret_cast<const uint32_t*>(file.bytes+offsets[c]);}
    const uint64_t* u64(Column c) const {return reinterpret_cast<const uint64_t*>(file.bytes+offsets[c]);}
    const int64_t* integer(Column c) const {return reinterpret_cast<const int64_t*>(file.bytes+offsets[c]);}
    const double* real(Column c) const {return reinterpret_cast<const double*>(file.bytes+offsets[c]);}
    ID id(uint32_t row) const {if(row>=count)throw std::runtime_error("Invalid catalog row.");ID result;memcpy(result.data(),file.bytes+offsets[UUIDColumn]+uint64_t(row)*16,16);return result;}
    uint32_t ordered(size_t order,uint32_t rank) const {auto id=uint32_t(number(file.bytes+orders[order]+uint64_t(rank)*4,4));if(id>=count)throw std::runtime_error("Invalid sort permutation.");return id;}
    std::string_view pair(uint32_t row) const {auto begin=u64(PlayersOffset)[row];auto length=u32(PlayersLength)[row];if(begin>players.size || length>players.size-begin)throw std::runtime_error("Invalid player sort key.");return {reinterpret_cast<const char*>(players.bytes+begin),length};}
    std::string value(size_t order,uint32_t row) const {
        if(order==0){std::ostringstream out;out<<std::setprecision(17)<<real(Date)[row];return out.str();}
        if(order==1)return std::string(pair(row));
        if(order==2 || order==3 || order==6)return std::to_string(integer(order==2?WhiteElo:order==3?BlackElo:Moves)[row]);
        return std::string(names.text(u32(order==4?Event:order==5?Result:Round)[row]));
    }
    int compare(size_t order,uint32_t row,const std::string& value,const ID& identity) const {
        if(order==0){auto a=real(Date)[row],b=std::stod(value);if(a!=b)return a<b?-1:1;}
        else if(order==2 || order==3 || order==6){auto a=integer(order==2?WhiteElo:order==3?BlackElo:Moves)[row],b=std::stoll(value);if(a!=b)return a<b?-1:1;}
        else{auto a=order==1?pair(row):names.text(u32(order==4?Event:order==5?Result:Round)[row]);if(a!=value)return a<value?-1:1;}
        auto a=id(row);return a==identity?0:a<identity?-1:1;
    }
    bool less(size_t order,uint32_t a,uint32_t b) const {
        if(order==0){auto x=real(Date)[a],y=real(Date)[b];if(x!=y)return x<y;}
        else if(order==2||order==3||order==6){auto col=order==2?WhiteElo:order==3?BlackElo:Moves;auto x=integer(col)[a],y=integer(col)[b];if(x!=y)return x<y;}
        else{auto x=order==1?pair(a):names.text(u32(order==4?Event:order==5?Result:Round)[a]);auto y=order==1?pair(b):names.text(u32(order==4?Event:order==5?Result:Round)[b]);if(x!=y)return x<y;}
        return id(a)<id(b);
    }
};

inline bool member(const std::vector<uint64_t>& bits,uint64_t id){return id/64<bits.size() && (bits[id/64]&(uint64_t(1)<<(id%64)));}
inline void include(std::vector<uint64_t>& bits,uint32_t id){bits[id/64]|=uint64_t(1)<<(id%64);}

struct Override {std::string source,folder,id;uint64_t record;bool deleted;};
inline std::vector<Override> readOverrides(const JSONValues& request) {
    JSONValues values(request.get("overrides","[]"));std::vector<Override> result;
    for(const auto& [_,text]:values.values){JSONValues row(text);result.push_back({row.get("source"),row.get("folder"),row.get("id"),std::stoull(row.get("record")),row.get("deleted")=="1"});}
    return result;
}
inline bool addedToScope(const std::vector<Override>& overrides,std::string_view source,const JSONValues& request) {
    auto folder=request.get("folder");
    for(const auto& row:overrides)if(!row.deleted&&row.source==source&&row.folder==folder)return true;
    return false;
}
inline std::vector<uint64_t> applyOverrides(const fs::path& dir,const Snapshot& snapshot,const JSONValues& request,std::vector<uint64_t>& matches) {
    auto overrides=readOverrides(request);std::vector<uint64_t> additions;
    if(overrides.empty())return additions;
    additions.resize((uint64_t(snapshot.count)+63)/64);
    auto groups=readText(dir/"groups.bin");if(groups.size()%16)throw std::runtime_error("Invalid source groups.");
    bool scoped=request.has("folder")||request.get("unfiled")=="1";auto folder=request.get("folder");
    for(const auto& item:overrides){
        auto source=snapshot.names.find(item.source);if(source==UINT32_MAX)continue;
        for(size_t i=0;i<groups.size();i+=16){auto p=reinterpret_cast<const uint8_t*>(groups.data()+i);if(number(p,4)!=source)continue;
            auto begin=number(p+4,4),end=number(p+8,4);if(begin>end||end>snapshot.count)throw std::runtime_error("Invalid source range.");
            const auto* records=snapshot.u64(Record);auto at=std::lower_bound(records+begin,records+end,item.record);
            while(at<records+end&&*at==item.record){auto row=uint32_t(at-records);++at;if(idText(snapshot.id(row))!=item.id)continue;
                if(item.deleted||(scoped&&item.folder!=folder))matches[row/64]&=~(uint64_t(1)<<(row%64));
                else if(scoped)include(additions,row);
            }
        }
    }
    return additions;
}

inline void sourceScope(const fs::path& dir,const fs::path& requestPath,const fs::path& output){
    JSONValues request(readText(requestPath));Snapshot snapshot(dir);auto groups=readText(dir/"groups.bin");auto overrides=readOverrides(request);
    if(groups.size()%16)throw std::runtime_error("Invalid source groups.");
    bool scoped=request.has("folder")||request.get("unfiled")=="1";
    uint32_t wanted=request.has("folder")?snapshot.names.find(request.get("folder")):0;
    std::string result="[";bool first=true;
    for(size_t offset=0;offset<groups.size();offset+=16){
        auto p=reinterpret_cast<const uint8_t*>(groups.data()+offset);auto source=uint32_t(number(p,4)),begin=uint32_t(number(p+4,4)),end=uint32_t(number(p+8,4)),folder=uint32_t(number(p+12,4));
        if(begin>end||end>snapshot.count)throw std::runtime_error("Invalid source group.");
        bool include=!scoped||folder==wanted;
        if(scoped&&folder==UINT32_MAX)include=std::find(snapshot.u32(Folder)+begin,snapshot.u32(Folder)+end,wanted)!=snapshot.u32(Folder)+end;
        if(scoped&&addedToScope(overrides,snapshot.names.text(source),request))include=true;
        if(request.has("folder")&&request.get("unfiled")=="1")include=false;
        if(include){if(!first)result+=',';first=false;result+=json(std::string(snapshot.names.text(source)));}
    }
    writeResult(output,result+"]");
}

inline std::vector<uint64_t> positionMatches(const fs::path& dir,const Snapshot& snapshot,const JSONValues& request,uint32_t& skipped){
    std::vector<uint64_t> bits((uint64_t(snapshot.count)+63)/64);
    auto groupText=readText(dir/"groups.bin");if(groupText.size()%16)throw std::runtime_error("Invalid source groups.");
    JSONValues sources(readText(dir/"sources.json"));
    std::map<std::string,JSONValues> sourceMap;
    for(const auto& [_,value]:sources.values){JSONValues source(value);sourceMap.emplace(source.get("id"),std::move(source));}
    bool scoped=request.has("folder") || request.get("unfiled")=="1";
    uint32_t folder=request.has("folder")?snapshot.names.find(request.get("folder")):0;
    Key key=fromFEN(request.get("board"));auto overrides=readOverrides(request);
    for(size_t g=0;g<groupText.size();g+=16){
        auto p=reinterpret_cast<const uint8_t*>(groupText.data()+g);
        uint32_t source=uint32_t(number(p,4)),begin=uint32_t(number(p+4,4)),end=uint32_t(number(p+8,4)),uniform=uint32_t(number(p+12,4));
        if(begin>end || end>snapshot.count)throw std::runtime_error("Invalid source range.");
        bool addition=scoped&&addedToScope(overrides,snapshot.names.text(source),request);
        if(scoped&&!addition&&uniform!=UINT32_MAX&&uniform!=folder)continue;
        if(scoped&&!addition&&uniform==UINT32_MAX&&std::find(snapshot.u32(Folder)+begin,snapshot.u32(Folder)+end,folder)==snapshot.u32(Folder)+end)continue;
        auto name=std::string(snapshot.names.text(source));auto found=sourceMap.find(name);
        if(found==sourceMap.end())throw std::runtime_error("Missing source identity.");
        const auto& info=found->second;bool cbh=info.get("kind")=="cbh";
        fs::path positions=fs::path(request.get("positionRoot"))/name;
        if(!readText(positions/"source.txt").starts_with(sourceStamp(info.get("path"),cbh)))throw std::runtime_error("Source positions need preparation or the source changed.");
        uint32_t sourceSkipped=0;auto sourceBits=lookup(positions,key,sourceSkipped);skipped+=sourceSkipped;
        std::unique_ptr<CatalogMappedFile> ranges;
        uint64_t sourceCount=0;std::istringstream(readText(positions/"complete.txt"))>>sourceCount;
        if(cbh){auto size=fs::file_size(info.get("path"));if(size<46 || sourceCount!=(size-46)/46)throw std::runtime_error("Position index does not cover this source.");}
        else{ranges=std::make_unique<CatalogMappedFile>((positions/"records.bin").string());if(ranges->size%16 || sourceCount!=ranges->size/16)throw std::runtime_error("Invalid PGN position record map.");}
        uint64_t matches=0;for(auto word:sourceBits)matches+=std::popcount(word);
        const auto* records=snapshot.u64(Record);
        auto mapRecord=[&](uint64_t record){auto at=std::lower_bound(records+begin,records+end,record);while(at<records+end && *at==record){include(bits,uint32_t(at-records));++at;}};
        if(matches<10000){
            for(size_t w=0;w<sourceBits.size();++w){auto word=sourceBits[w];while(word){unsigned bit=std::countr_zero(word);uint64_t ordinal=w*64+bit;word&=word-1;if(ordinal>=sourceCount)throw std::runtime_error("Invalid position ordinal.");mapRecord(cbh?ordinal:number(ranges->bytes+ordinal*16,8));}}
        }else{
            uint64_t ordinal=0;
            for(uint32_t row=begin;row<end;++row){
                if(cbh){if(member(sourceBits,records[row]))include(bits,row);}
                else{while(ordinal<sourceCount && number(ranges->bytes+ordinal*16,8)<records[row])++ordinal;if(ordinal<sourceCount && number(ranges->bytes+ordinal*16,8)==records[row] && member(sourceBits,ordinal))include(bits,row);}
            }
        }
    }
    return bits;
}

inline void queryMetadata(const fs::path& dir,const fs::path& requestPath,const fs::path& output){
    auto started=std::chrono::steady_clock::now();JSONValues request(readText(requestPath));Snapshot snapshot(dir);
    size_t order=0;for(size_t i=0;i<orderCount;++i)if(request.get("sort")==orderNames[i])order=i;
    bool ascending=request.get("ascending")=="1";uint32_t skipped=0;
    std::vector<uint64_t> bits;
    if(request.has("board"))bits=positionMatches(dir,snapshot,request,skipped);
    else {bits.assign((uint64_t(snapshot.count)+63)/64,UINT64_MAX);if(snapshot.count%64)bits.back()=(uint64_t(1)<<(snapshot.count%64))-1;}
    auto scopeAdditions=applyOverrides(dir,snapshot,request,bits);
    using Masks=std::vector<std::vector<uint64_t>>;
    auto masks=[&](const std::string& text){Masks result;for(const auto& token:tokens(text))result.push_back(snapshot.names.prefix(token));return result;};
    auto search=masks(request.get("search")),player=masks(request.get("player")),white=masks(request.get("white")),black=masks(request.get("black")),event=masks(request.get("tournament"));
    auto all=[&](const Masks& masks,uint32_t id){for(const auto& mask:masks)if(!member(mask,id))return false;return true;};
    bool scoped=request.has("folder") || request.get("unfiled")=="1";uint32_t folder=request.has("folder")?snapshot.names.find(request.get("folder")):0;
    auto result=request.get("result","all"),file=request.get("file","all");
    auto numeric=[&](const char* key,double fallback){return request.has(key)?std::stod(request.get(key)):fallback;};
    double whiteMin=numeric("whiteMin",-INFINITY),whiteMax=numeric("whiteMax",INFINITY),blackMin=numeric("blackMin",-INFINITY),blackMax=numeric("blackMax",INFINITY),dateMin=numeric("dateMin",-INFINITY),dateMax=numeric("dateMax",INFINITY),recent=numeric("recentAfter",-INFINITY);
    bool whiteRated=request.has("whiteMin")||request.has("whiteMax"),blackRated=request.has("blackMin")||request.has("blackMax");
    bool dates=request.has("dateMin")||request.has("dateMax"),recents=request.has("recentAfter");
    bool nameFilter=!search.empty()||!player.empty()||!white.empty()||!black.empty()||!event.empty();
    bool impossibleScope=request.has("folder")&&request.get("unfiled")=="1";
    bool filters=scoped||whiteRated||blackRated||dates||recents||nameFilter||result!="all"||file!="all";
    uint32_t win=snapshot.names.find("1-0"),loss=snapshot.names.find("0-1"),draw=snapshot.names.find("1/2-1/2");
    auto filterWords=[&](size_t start,size_t end){uint64_t count=0;
    for(size_t wordIndex=start;wordIndex<end;++wordIndex){auto word=bits[wordIndex];if(!filters){count+=std::popcount(word);continue;}while(word){unsigned bit=std::countr_zero(word);word&=word-1;uint32_t row=uint32_t(wordIndex*64+bit);
        auto keep=[&]{
            if(impossibleScope)return false;
            if(scoped && snapshot.u32(Folder)[row]!=folder && !member(scopeAdditions,row))return false;
            if(whiteRated){auto w=snapshot.integer(WhiteElo)[row];if(w<=0||w<whiteMin||w>whiteMax)return false;}
            if(blackRated){auto b=snapshot.integer(BlackElo)[row];if(b<=0||b<blackMin||b>blackMax)return false;}
            if(dates){double date=snapshot.real(Date)[row];if(date<dateMin||date>=dateMax)return false;}
            if(recents&&snapshot.real(Modified)[row]<=recent)return false;
            if(result!="all"){auto r=snapshot.u32(Result)[row];if((result=="whiteWin"&&r!=win)||(result=="blackWin"&&r!=loss)||(result=="draw"&&r!=draw)||(result=="unfinished"&&(r==win||r==loss||r==draw)))return false;}
            if(file!="all"){auto flags=snapshot.u32(Flags)[row];if((file=="savedPGN"&&(!(flags&2)||(flags&1)))||(file=="needsSaving"&&!(flags&1))||(file=="included"&&!(flags&4))||(file=="imported"&&!(flags&8))||(file=="autosaved"&&(flags&14)))return false;}
            if(nameFilter){auto wi=snapshot.u32(White)[row],bi=snapshot.u32(Black)[row],ev=snapshot.u32(Event)[row];
                if(!all(white,wi)||!all(black,bi)||!all(event,ev)||(!all(player,wi)&&!all(player,bi)))return false;
                for(const auto& token:search)if(!member(token,wi)&&!member(token,bi)&&!member(token,ev)&&!member(token,snapshot.u32(Title)[row])&&!member(token,snapshot.u32(SourceName)[row]))return false;
            }
            return true;
        };
        if(keep())++count;else bits[wordIndex]&=~(uint64_t(1)<<bit);
    }}return count;};
    uint64_t count=0;
    if(filters&&snapshot.count>100000){
        std::array<uint64_t,4> counts{};std::array<std::exception_ptr,4> failures{};std::array<std::jthread,4> workers;
        for(size_t i=0;i<4;++i)workers[i]=std::jthread([&,i]{try{counts[i]=filterWords(bits.size()*i/4,bits.size()*(i+1)/4);}catch(...){failures[i]=std::current_exception();}});
        for(auto& worker:workers)worker.join();for(auto failure:failures)if(failure)std::rethrow_exception(failure);for(auto value:counts)count+=value;
    }else count=filterWords(0,bits.size());
    std::vector<uint32_t> sparse;
    if(count<=65536){
        sparse.reserve(size_t(count));for(size_t i=0;i<bits.size();++i){auto word=bits[i];while(word){unsigned bit=std::countr_zero(word);word&=word-1;sparse.push_back(uint32_t(i*64+bit));}}
        std::sort(sparse.begin(),sparse.end(),[&](uint32_t a,uint32_t b){return snapshot.less(order,a,b);});
    }
    bool useSparse=count<=65536;uint32_t extent=useSparse?uint32_t(sparse.size()):snapshot.count;
    auto ordered=[&](uint32_t rank){return useSparse?sparse[rank]:snapshot.ordered(order,rank);};
    uint32_t rank=ascending?0:extent;
    if(request.values.contains("cursorValue")&&request.has("cursorID")){
        auto identity=parseID(request.get("cursorID"));auto value=request.has("cursorHex")?unhex(request.get("cursorHex")):request.get("cursorValue");uint32_t low=0,high=extent;
        while(low<high){auto mid=low+(high-low)/2;int comparison=snapshot.compare(order,ordered(mid),value,identity);if(comparison<0||(ascending&&comparison==0))low=mid+1;else high=mid;}
        rank=low;
    }
    std::ostringstream rows;rows<<'[';size_t emitted=0;
    while(ascending?rank<extent:rank>0){uint32_t row=ordered(ascending?rank++:--rank);if(!member(bits,row))continue;if(emitted++)rows<<',';rows<<"{\"id\":"<<json(idText(snapshot.id(row)))<<",\"valueHex\":"<<json(hex(snapshot.value(order,row)))<<",\"whiteElo\":"<<snapshot.integer(WhiteElo)[row]<<",\"blackElo\":"<<snapshot.integer(BlackElo)[row]<<'}';if(emitted==201)break;}
    rows<<']';
    std::ostringstream resultJSON;resultJSON<<"{\"count\":"<<count<<",\"skipped\":"<<skipped<<",\"rows\":"<<rows.str()<<",\"seconds\":"<<std::chrono::duration<double>(std::chrono::steady_clock::now()-started).count()<<'}';
    writeResult(output,resultJSON.str());
}
} // namespace lucent_catalog
