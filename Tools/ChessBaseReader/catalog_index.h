// SPDX-License-Identifier: GPL-2.0-or-later
#pragma once

static std::string catalogUTF8(const std::string& text) {
    static const unsigned cp[32] = {0x20ac,0x81,0x201a,0x192,0x201e,0x2026,0x2020,0x2021,0x2c6,0x2030,0x160,0x2039,0x152,0x8d,0x17d,0x8f,0x90,0x2018,0x2019,0x201c,0x201d,0x2022,0x2013,0x2014,0x2dc,0x2122,0x161,0x203a,0x153,0x9d,0x17e,0x178};
    std::string out;
    for (unsigned char byte : text) {
        unsigned c = byte >= 128 && byte < 160 ? cp[byte-128] : byte;
        if (c < 128) out += char(c);
        else if (c < 2048) { out += char(0xc0 | c >> 6); out += char(0x80 | (c & 63)); }
        else { out += char(0xe0 | c >> 12); out += char(0x80 | ((c >> 6) & 63)); out += char(0x80 | (c & 63)); }
    }
    return out;
}
struct CatalogDB {
    sqlite3* db = nullptr;
    explicit CatalogDB(const char* path) {
        if (sqlite3_open(path, &db) != SQLITE_OK) throw std::runtime_error("Could not open the library index.");
        sqlite3_busy_timeout(db, 30000);
        exec("PRAGMA cache_size=-32768; PRAGMA temp_store=FILE; PRAGMA synchronous=NORMAL;");
    }
    ~CatalogDB() { if(db) sqlite3_close(db); }
    void exec(const char* sql) { if (sqlite3_exec(db,sql,nullptr,nullptr,nullptr) != SQLITE_OK) throw std::runtime_error(sqlite3_errmsg(db)); }
};
struct CatalogStatement {
    CatalogDB& db; sqlite3_stmt* stmt = nullptr;
    CatalogStatement(CatalogDB& db, const char* sql): db(db) {
        if(sqlite3_prepare_v2(db.db,sql,-1,&stmt,nullptr)!=SQLITE_OK) throw std::runtime_error(sqlite3_errmsg(db.db));
    }
    ~CatalogStatement() { sqlite3_finalize(stmt); }
    void text(int i,const std::string& value) { sqlite3_bind_text(stmt,i,value.c_str(),int(value.size()),SQLITE_TRANSIENT); }
    std::string text(int i) { auto v=sqlite3_column_text(stmt,i); return v ? reinterpret_cast<const char*>(v) : ""; }
    void integer(int i,sqlite3_int64 value) { sqlite3_bind_int64(stmt,i,value); }
    void number(int i,double value) { sqlite3_bind_double(stmt,i,value); }
    void run() { if(sqlite3_step(stmt)!=SQLITE_DONE) throw std::runtime_error(sqlite3_errmsg(db.db)); sqlite3_reset(stmt); sqlite3_clear_bindings(stmt); }
};

// Read fixed-size header tables directly. Indexing never visits the move or annotation streams.
#include <sys/mman.h>
#include <sys/stat.h>
#include <fcntl.h>
struct CatalogMappedFile {
    int fd = -1; size_t size = 0; const unsigned char* bytes = nullptr;
    explicit CatalogMappedFile(const std::string& path) {
        fd = ::open(path.c_str(),O_RDONLY);
        struct stat status{};
        if(fd<0 || fstat(fd,&status)!=0 || status.st_size<=0) { if(fd>=0)close(fd); throw std::runtime_error("Missing database header table."); }
        size=size_t(status.st_size);
        auto mapping=mmap(nullptr,size,PROT_READ,MAP_PRIVATE,fd,0);
        if(mapping==MAP_FAILED) {close(fd);throw std::runtime_error("Could not map database headers.");}
        bytes=static_cast<const unsigned char*>(mapping);
    }
    ~CatalogMappedFile(){if(bytes)munmap(const_cast<unsigned char*>(bytes),size);if(fd>=0)close(fd);}
    unsigned number(size_t offset,size_t length) const {
        if(offset>size || length>size-offset) throw std::runtime_error("Truncated database header record.");
        unsigned value=0;for(size_t i=0;i<length;++i)value=(value<<8)|bytes[offset+i];return value;
    }
    std::string text(size_t offset,size_t length) const {
        if(offset>size || length>size-offset)throw std::runtime_error("Truncated database name record.");
        size_t count=0;while(count<length && bytes[offset+count])++count;
        return std::string(reinterpret_cast<const char*>(bytes+offset),count);
    }
};
struct CatalogHeaders {
    CatalogMappedFile index,players,tournaments;
    size_t playerHeader,tournamentHeader;
    explicit CatalogHeaders(const std::string& path):index(path),players(path.substr(0,path.size()-4)+".cbp"),tournaments(path.substr(0,path.size()-4)+".cbt") {
        playerHeader=28+players.number(24,1);tournamentHeader=28+tournaments.number(24,1);
    }
    bool read(size_t record,GameReturnValue& game) const {
        size_t offset=46+record*46;
        if(index.number(offset,1)&2)return false;
        size_t white=playerHeader+size_t(index.number(offset+9,3))*67+9;
        size_t black=playerHeader+size_t(index.number(offset+12,3))*67+9;
        game.whiteName=players.text(white,30);game.whiteFirstName=players.text(white+30,20);
        game.blackName=players.text(black,30);game.blackFirstName=players.text(black+30,20);
        size_t tournament=tournamentHeader+size_t(index.number(offset+15,3))*99+9;
        game.eventTitle=tournaments.text(tournament,40);game.eventPlace=tournaments.text(tournament+40,30);
        auto date=index.number(offset+24,3);game.gameDate=Date((date>>9)&4095,(date>>5)&15,date&31);
        auto result=index.number(offset+27,1);game.result=result==2?1:result==1?3:result==0?2:0;
        game.round=index.number(offset+29,1);game.subround=index.number(offset+30,1);game.fullMoves=index.number(offset+45,1);
        return true;
    }
};

static int indexDatabase(const char* sourcePath, const char* catalogPath, const char* sourceID) {
    CbhCodec codec;
    if(codec.open(sourcePath)!=OK) throw std::runtime_error("Could not read the ChessBase database headers.");
    CatalogHeaders headers(sourcePath);
    CatalogDB db(catalogPath);
    CatalogStatement source(db,"SELECT folder,name,url FROM sources WHERE id=?"); source.text(1,sourceID);
    if(sqlite3_step(source.stmt)!=SQLITE_ROW) throw std::runtime_error("Missing database registration.");
    const auto folder=source.text(0), name=source.text(1), url=source.text(2);
    sqlite3_reset(source.stmt);
    CatalogStatement insert(db,"INSERT INTO games(id,source_id,record,white,black,event,title,site,date,result,moves,round,players,round_sort,folder,source_name,source_url,dirty,modified,created,saved) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,0,?,?,?)");
    db.exec("BEGIN IMMEDIATE");
    size_t accepted=0,skipped=0; const double imported=std::time(nullptr);
    const auto parent = getppid();
    std::cout << "0 " << codec.numGames() << std::endl;
    try {
        for(size_t index=0;index<codec.numGames();++index) {
            if(index%10000==0 && getppid()!=parent) throw std::runtime_error("Import cancelled because Lucent Chess closed.");
            GameReturnValue game{};
            if(!headers.read(index,game)) { ++skipped; continue; }
            std::ostringstream suffix; suffix << std::uppercase << std::hex << std::setw(12) << std::setfill('0') << index;
            std::string id=std::string(sourceID).substr(0,24)+suffix.str();
            auto player=[](const std::string& last,const std::string& first) { return catalogUTF8(last+(first.empty()?"":", "+first)); };
            auto white=player(game.whiteName,game.whiteFirstName),black=player(game.blackName,game.blackFirstName);
            auto event=catalogUTF8(game.eventTitle); auto players=white+" – "+black;
            std::transform(players.begin(),players.end(),players.begin(),[](unsigned char c){return c<128?std::tolower(c):c;});
            auto round=game.round?std::to_string(game.round)+(game.subround?"."+std::to_string(game.subround):""):"";
            char roundSort[64]; std::snprintf(roundSort,sizeof(roundSort),"%020.4f",round.empty()?0:std::stod(round));
            std::tm date{};date.tm_year=std::max(1u,game.gameDate.year)-1900;date.tm_mon=std::max(1u,game.gameDate.month)-1;date.tm_mday=std::max(1u,game.gameDate.day);
            const char* results[]={"*","1-0","0-1","1/2-1/2"};
            insert.text(1,id);insert.text(2,sourceID);insert.integer(3,index);
            insert.text(4,white);insert.text(5,black);insert.text(6,event);insert.text(7,event.empty()?"Imported game":event);insert.text(8,catalogUTF8(game.eventPlace));
            insert.number(9,timegm(&date));insert.text(10,results[game.result<4?game.result:0]);insert.integer(11,game.fullMoves*2);
            insert.text(12,round);insert.text(13,players);insert.text(14,roundSort);insert.text(15,folder);insert.text(16,name);insert.text(17,url);
            insert.number(18,imported);insert.number(19,imported);insert.number(20,imported);insert.run();++accepted;
            if(index%10000==0) std::cout << index+1 << ' ' << codec.numGames() << std::endl;
        }
        CatalogStatement update(db,"UPDATE sources SET count=? WHERE id=?");update.integer(1,accepted);update.text(2,sourceID);update.run();
        db.exec("COMMIT");
        std::cout << codec.numGames() << ' ' << codec.numGames() << ' ' << accepted << ' ' << skipped << std::endl;
        return 0;
    } catch(...) { try{db.exec("ROLLBACK");}catch(...){} throw; }
}

#include <map>
// Stream PGN headers and byte ranges. SAN parsing and move-tree construction happen only on open.
static int indexPGN(const char* sourcePath,const char* catalogPath,const char* sourceID) {
    std::ifstream input(sourcePath,std::ios::binary);
    if(!input)throw std::runtime_error("Could not read the PGN database.");
    input.seekg(0,std::ios::end);auto total=uint64_t(input.tellg());input.seekg(0);
    CatalogDB db(catalogPath);
    CatalogStatement source(db,"SELECT folder,name,url FROM sources WHERE id=?");source.text(1,sourceID);
    if(sqlite3_step(source.stmt)!=SQLITE_ROW)throw std::runtime_error("Missing PGN registration.");
    const auto folder=source.text(0),name=source.text(1),url=source.text(2);sqlite3_reset(source.stmt);
    CatalogStatement insert(db,"INSERT INTO games(id,source_id,record,record_length,white,black,event,title,site,date,result,moves,round,players,round_sort,folder,source_name,source_url,dirty,modified,created,saved) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,0,?,?,?)");
    db.exec("BEGIN IMMEDIATE");
    std::map<std::string,std::string> tags;
    uint64_t start=0,position=0,accepted=0;bool active=false,movetext=false,ended=false;int braces=0,variation=0,moves=0;
    const double imported=std::time(nullptr);
    const auto parent = getppid();
    auto flush=[&](uint64_t end) {
        if(!active)return;
        if(accepted%10000==0 && getppid()!=parent) throw std::runtime_error("Import cancelled because Lucent Chess closed.");
        std::ostringstream suffix;suffix<<std::uppercase<<std::hex<<std::setw(12)<<std::setfill('0')<<accepted;
        const auto id=std::string(sourceID).substr(0,24)+suffix.str();
        auto white=tags["White"],black=tags["Black"],event=tags["Event"],round=tags["Round"];
        auto players=white+" – "+black;std::transform(players.begin(),players.end(),players.begin(),[](unsigned char c){return c<128?std::tolower(c):c;});
        char roundSort[64];double roundNumber=0;try{roundNumber=std::stod(round);}catch(...){}
        std::snprintf(roundSort,sizeof(roundSort),"%020.4f",roundNumber);
        int y=1970,m=1,d=1;std::sscanf(tags["Date"].c_str(),"%d.%d.%d",&y,&m,&d);
        std::tm date{};date.tm_year=std::max(1,y)-1900;date.tm_mon=std::clamp(m,1,12)-1;date.tm_mday=std::clamp(d,1,31);
        insert.text(1,id);insert.text(2,sourceID);insert.integer(3,start);insert.integer(4,end-start);
        insert.text(5,white);insert.text(6,black);insert.text(7,event);insert.text(8,event.empty()?"Imported game":event);insert.text(9,tags["Site"]);
        insert.number(10,timegm(&date));insert.text(11,tags["Result"].empty()?"*":tags["Result"]);insert.integer(12,moves);insert.text(13,round);insert.text(14,players);insert.text(15,roundSort);
        insert.text(16,folder);insert.text(17,name);insert.text(18,url);insert.number(19,imported);insert.number(20,imported);insert.number(21,imported);insert.run();
        ++accepted;tags.clear();active=false;movetext=false;ended=false;moves=0;braces=0;variation=0;
        if(accepted%10000==0)std::cout<<end<<' '<<total<<std::endl;
    };
    auto token=[&](std::string text) {
        if(text.empty())return;
        if(text=="1-0"||text=="0-1"||text=="1/2-1/2"||text=="*"){ended=true;if(tags["Result"].empty())tags["Result"]=text;return;}
        if(text[0]=='$')return;
        size_t i=0;while(i<text.size()&&(std::isdigit(static_cast<unsigned char>(text[i]))||text[i]=='.'))++i;
        if(i<text.size() && (std::isalpha(static_cast<unsigned char>(text[i]))||text[i]=='O'))++moves;
    };
    try {
        std::string line;
        while(std::getline(input,line)) {
            const uint64_t offset=position;auto next=input.tellg();position=next<0?total:uint64_t(next);
            if(line.size()>64*1024*1024)throw std::runtime_error("A PGN line is too large to index.");
            if(offset==0 && line.rfind("\xef\xbb\xbf",0)==0)line.erase(0,3);
            auto begin=line.find_first_not_of(" \t\r");if(begin==std::string::npos)continue;
            bool header=braces==0 && line[begin]=='[';
            if(header) {
                if(movetext)flush(offset);
                if(!active){start=offset;active=true;}
                auto split=line.find_first_of(" \t",begin+1),quote=line.find('"',split);
                if(split==std::string::npos||quote==std::string::npos)throw std::runtime_error("Malformed PGN tag line.");
                std::string value;bool escape=false,closed=false;
                for(size_t i=quote+1;i<line.size();++i){char c=line[i];if(escape){value+=c;escape=false;}else if(c=='\\')escape=true;else if(c=='"'){closed=true;break;}else value+=c;}
                if(!closed)throw std::runtime_error("Unclosed PGN tag string.");
                tags[line.substr(begin+1,split-begin-1)]=value;continue;
            }
            if(line[begin]=='%')continue;
            if(ended && braces==0 && line[begin]!='{' && line[begin]!=';')flush(offset);
            if(!active){start=offset;active=true;}
            movetext=true;std::string current;
            for(char c:line) {
                if(braces){if(c=='}')--braces;else if(c=='{')++braces;continue;}
                if(c==';')break;
                if(c=='{'||c=='('||c==')'||std::isspace(static_cast<unsigned char>(c))) {
                    if(variation==0)token(current);current.clear();
                    if(c=='{')++braces;else if(c=='(')++variation;else if(c==')')variation=std::max(0,variation-1);
                } else if(variation==0)current+=c;
            }
            if(variation==0)token(current);
        }
        flush(total);
        CatalogStatement update(db,"UPDATE sources SET count=? WHERE id=?");update.integer(1,accepted);update.text(2,sourceID);update.run();
        db.exec("COMMIT");std::cout<<total<<' '<<total<<' '<<accepted<<" 0"<<std::endl;return 0;
    }catch(...){try{db.exec("ROLLBACK");}catch(...){}throw;}
}
