// Exercises storage failures and process recovery without a production database.
#define main lucent_reader_main
#include "../Tools/ChessBaseReader/main.cpp"
#undef main
#include <sys/wait.h>
#include <cassert>
int main(int argc,char**argv) {
    using namespace lucent_positions;
    if(argc!=2)return 2;
    fs::path root=argv[1];fs::create_directories(root);
    auto key=fromFEN("rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w - - 0 1");
    auto prepare=[&](bool crash){build(root,"test source",3,[&](uint32_t record,std::vector<Key>& keys){if(crash&&record==1)raise(SIGSEGV);keys.push_back(key);return true;},[]{return true;});};
    auto pid=fork();if(pid==0){prepare(true);_exit(0);}int status=0;waitpid(pid,&status,0);
    if(!WIFEXITED(status)||WEXITSTATUS(status)!=128+SIGSEGV)throw std::runtime_error("Expected isolated decoder crash");
    prepare(true);uint32_t incomplete=0;auto bits=lookup(root,key,incomplete);
    if(incomplete!=1||bits.size()!=1||bits[0]!=5)throw std::runtime_error("Crash resume lost or misidentified a record");
    auto original=readText(partPath(root,0));prepare(false);
    if(readText(partPath(root,0))!=original)throw std::runtime_error("Completed parts were rewritten");
    {BuildLock held(root);pid=fork();if(pid==0){try{BuildLock conflict(root);_exit(1);}catch(...){_exit(0);}}waitpid(pid,&status,0);if(!WIFEXITED(status)||WEXITSTATUS(status)!=0)throw std::runtime_error("Concurrent builder acquired lock");}
    auto damaged=original;auto directory=number(reinterpret_cast<const uint8_t*>(original.data()+40),8);damaged.at(directory)^=1;
    atomicText(partPath(root,0),damaged);bool rejected=false;
    try{lookup(root,key,incomplete);}catch(...){rejected=true;}
    if(!rejected)throw std::runtime_error("Corrupt fence accepted");
    atomicText(partPath(root,0),original);atomicText(root/"complete.txt","4294967295\n0\n");rejected=false;
    try{lookup(root,key,incomplete);}catch(...){rejected=true;}
    if(!rejected)throw std::runtime_error("Invalid completion marker accepted");
    std::cout<<"Passed: crash quarantine/resume, immutable checkpoints, concurrent build exclusion, corrupt fences, oversized completion marker\n";
}
