"""Build a 10-million-record synthetic CBH index and measure browsing queries.

Run scripts/build_app.sh first. Requires about 12 GiB of temporary disk space.
The output uses repeated test fixture game headers, not ten million distinct games.
Results and disposable generated files are placed under .build-local/scale-benchmark-*.
"""
from pathlib import Path
import sqlite3, subprocess, time, json, resource, shutil
root=Path(__file__).resolve().parents[1]
work=root/'.build-local'/('scale-benchmark-'+str(int(time.time())))
work.mkdir(parents=True,exist_ok=False)
fixtures=root/'Tests/Fixtures/ChessBase/annotations'
for ext in ('cba','cbg','cbp','cbt','cbc','cbs'):
 shutil.copy2(fixtures/f'TestBase.{ext}',work/f'Scale.{ext}')
original=(fixtures/'TestBase.cbh').read_bytes()
records=original[46:]
count=10_000_000
with (work/'Scale.cbh').open('wb') as f:
 f.write(original[:46])
 block=records*2500
 for _ in range(count//10000): f.write(block)
s=(root/'Sources/LucentChess/Services/DatabaseCatalog.swift').read_text()
schema=s.split('static let schema = """',1)[1].split('"""',1)[0]
path=work/'Catalog.sqlite'
db=sqlite3.connect(path)
db.executescript('PRAGMA journal_mode=WAL;'+schema)
for col in ('date','players'):
 db.execute(f'CREATE INDEX IF NOT EXISTS games_{col} ON games({col},id)')
 db.execute(f'CREATE INDEX IF NOT EXISTS games_folder_{col} ON games(folder,{col},id)')
source='AB8442B9-DB09-4D89-8546-E2A2EE9C22D6';folder='E312649C-8F43-44CF-A90D-A43BCD8B0AF4'
db.execute('INSERT INTO sources(id,path,kind,name,url,folder) VALUES(?,?,?,?,?,?)',(source,str(work/'Scale.cbh'),'cbh','Scale 10M','test:scale10m',folder))
db.commit();db.close()
start=time.perf_counter()
process=subprocess.Popen([str(root/'.build-local/bin/LucentChessCBH'),'--index',str(work/'Scale.cbh'),str(path),source],stdout=subprocess.PIPE,text=True)
for line in process.stdout:
 values=line.split()
 if len(values)>1 and (int(values[0])%500000==1 or len(values)>2):print(f'{time.perf_counter()-start:.1f}s: {line.strip()}',flush=True)
assert process.wait()==0
indexed=time.perf_counter()-start
rss=resource.getrusage(resource.RUSAGE_CHILDREN).ru_maxrss
db=sqlite3.connect(path)
assert db.execute('SELECT count(*) FROM games').fetchone()[0]==count
results={'records':count,'index_seconds':indexed,'max_rss_bytes':rss,'database_bytes':path.stat().st_size}
queries={
 'first_page':('SELECT id,white,black,event,date FROM games ORDER BY date DESC,id DESC LIMIT 200',()),
 'last_page':('SELECT id,white,black,event,date FROM games ORDER BY date ASC,id ASC LIMIT 200',()),
 'collection_page':('SELECT id,white,black,event,date FROM games WHERE folder=? ORDER BY date DESC,id DESC LIMIT 200',(folder,)),
 'players_page':('SELECT id,white,black FROM games ORDER BY players,id LIMIT 200',()),
 'search_page':("SELECT id,white,black FROM games INDEXED BY games_date WHERE rowid IN (SELECT rowid FROM games_fts WHERE games_fts MATCH ?) ORDER BY date DESC,id DESC LIMIT 200",('Evaluation*',)),
 'collection_search_page':("SELECT id,white,black FROM games INDEXED BY games_folder_date WHERE folder=? AND rowid IN (SELECT rowid FROM games_fts WHERE games_fts MATCH ?) ORDER BY date DESC,id DESC LIMIT 200",(folder,'Evaluation* AND folder : \"'+folder+'\"'))
}
for name,(sql,args) in queries.items():
 start=time.perf_counter();rows=db.execute(sql,args).fetchall();elapsed=time.perf_counter()-start
 assert len(rows)==200
 results[name+'_seconds']=elapsed
 print(name,round(elapsed,4),flush=True)
print(json.dumps(results,indent=2),flush=True)
(work/'results.json').write_text(json.dumps(results,indent=2))
