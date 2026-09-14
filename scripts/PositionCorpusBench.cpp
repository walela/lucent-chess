// Read-only full-source validation using the full CBH decoder and an independent
// chess board implementation. Every previously unqueried position must include
// its originating physical source record in the persistent exact index.
#define main lucent_reader_main
#include "../Tools/ChessBaseReader/main.cpp"
#undef main
#include <random>
int main(int argc,char**argv) {
    if(argc!=4){std::cerr<<"Usage: PositionCorpusBench source.cbh prepared-position-directory output.json\n";return 2;}
    CbhCodec codec;if(codec.open(argv[1])!=OK)return 2;
    std::mt19937 random(20260914);std::set<std::string> seen;std::vector<double> times;std::ostringstream result;result<<'[';
    for(size_t attempt=0;attempt<10000&&times.size()<1000;++attempt){
        uint32_t record=random()%codec.numGames();GameReturnValue game{};
        if(codec.setGameIndex(record)!=OK||codec.parseNext(game)!=OK)continue;
        chess::Board board;if(!board.setFen(game.startFen))continue;
        std::vector<std::string> positions;
        bool valid=true;
        for(const auto& encoded:game.annotatedMoves){
            if(encoded.promote==254)break;
            if(encoded.promote==255||encoded.promote==253)continue;
            if(encoded.from>=64||encoded.to>=64||encoded.from==encoded.to){valid=false;break;}
            auto uci=square(encoded.from)+square(encoded.to);
            if(encoded.promote>=2&&encoded.promote<=5)uci += "  qrbn"[encoded.promote];
            else if(encoded.promote!=1&&encoded.promote!=7){valid=false;break;}
            auto move=chess::uci::uciToMove(board,uci);chess::Movelist legal;chess::movegen::legalmoves(legal,board);
            if(std::find(legal.begin(),legal.end(),move)==legal.end()){valid=false;break;}
            board.makeMove(move);positions.push_back(board.getFen());
        }
        if(!valid||positions.size()<8)continue;
        auto fen=positions[4+random()%(positions.size()-4)];
        if(!seen.insert(fen.substr(0,fen.find(' ',fen.find(' ')+1))).second)continue;
        auto start=std::chrono::steady_clock::now();uint32_t skipped=0;
        auto bits=lucent_positions::lookup(argv[2],lucent_positions::fromFEN(fen),skipped);
        auto milliseconds=std::chrono::duration<double,std::milli>(std::chrono::steady_clock::now()-start).count();
        if(!lucent_catalog::member(bits,record)){std::cerr<<"Missing originating record "<<record<<" for "<<fen<<'\n';return 1;}
        uint64_t count=0;for(auto word:bits)count+=std::popcount(word);
        if(!times.empty())result<<',';result<<"{\"record\":"<<record<<",\"fen\":"<<lucent_catalog::json(fen)<<",\"milliseconds\":"<<milliseconds<<",\"count\":"<<count<<'}';
        times.push_back(milliseconds);if(times.size()%100==0)std::cout<<times.size()<<" positions checked\n"<<std::flush;
    }
    result<<']';lucent_catalog::writeResult(argv[3],result.str());
    if(times.size()!=1000)throw std::runtime_error("Insufficient independent positions.");
    std::sort(times.begin(),times.end());
    std::cout<<"1000 distinct positions include their independently replayed source game. Native lookup p50="<<times[500]<<" ms, p95="<<times[950]<<" ms, p99="<<times[990]<<" ms, max="<<times.back()<<" ms\n";
}
