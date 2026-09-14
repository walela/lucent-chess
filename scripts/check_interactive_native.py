#!/usr/bin/env python3
"""Differential tests for exact native orders, dense/sparse paging and overlays."""
import json, pathlib, sqlite3, subprocess, sys, tempfile

reader = str(pathlib.Path(sys.argv[1]).resolve())
with tempfile.TemporaryDirectory(prefix='lucent-native-catalog-') as tmp:
    root=pathlib.Path(tmp);db=sqlite3.connect(root/'Library.sqlite')
    db.executescript('''
    CREATE TABLE sources(id TEXT,path TEXT,kind TEXT,count INTEGER);
    CREATE TABLE games(id TEXT PRIMARY KEY,source_id TEXT,record INTEGER,folder TEXT,white TEXT,black TEXT,event TEXT,title TEXT,source_name TEXT,round_sort TEXT,result TEXT,players TEXT,date REAL,modified REAL,white_elo TEXT,black_elo TEXT,moves INTEGER,dirty INTEGER,file_path TEXT,starter TEXT,payload BLOB,elo_indexed INTEGER,record_length INTEGER);
    ''')
    source='11111111-2222-3333-4444-555555555555';folder='AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE'
    db.execute('INSERT INTO sources VALUES(?,?,?,?)',(source,str(root/'source.pgn'),'pgn',65537))
    names=['Müller','MÜLLER','Mu\u0308ller','Łukasz','Đorđević','Ærø','İnönü',"O’Kelly",'Nakamura♞','棋手','Иванов','Йванов','Άλφα','Αλφα','']
    def identity(i):return '11111111-2222-3333-4444-%012X'%i
    rows=[]
    for i in range(65537):
        white='A '+names[i%len(names)] if i<65536 else 'B Last'
        elo=['0','2700','2700?','-5','9223372036854775807'][i%5]
        rows.append((identity(i),source,i,folder,white,'Opponent',names[i%len(names)],'', 'Archive',('%020.4f'%(i%13)) if i%4 else '',['*','1-0','0-1','1/2-1/2'][i%4],white.lower()+' – Opponent',1700000000+i/1000000,1700000000,elo,'2500',i%100,0,None,None,None,1,1))
    db.executemany('INSERT INTO games VALUES('+','.join('?'*23)+')',rows)
    # Legacy catalogs can contain raw CP1252 TEXT. Sort keys must survive JSON
    # and cursor transport byte-for-byte even before their headers are reimported.
    db.execute('UPDATE games SET players=CAST(? AS TEXT) WHERE id=?',(b'M\xfcller',identity(60000)))
    db.commit()
    metadata=root/'metadata'
    subprocess.run([reader,'--prepare-catalog-metadata',str(root/'Library.sqlite'),str(metadata),'test-generation'],check=True,stdout=subprocess.DEVNULL)
    subprocess.run([reader,'--verify-catalog-metadata',str(metadata)],check=True)
    columns={'date':'date','players':'players','whiteElo':"CAST(coalesce(white_elo,'0') AS INTEGER)",'blackElo':"CAST(coalesce(black_elo,'0') AS INTEGER)",'event':'event','result':'result','moves':'moves','round':'round_sort'}
    def query(request):
        (root/'request.json').write_text(json.dumps(request))
        subprocess.run([reader,'--query-catalog-metadata',str(metadata),str(root/'request.json'),str(root/'result.json')],check=True,stdout=subprocess.DEVNULL)
        return json.loads((root/'result.json').read_text())
    comparisons=0
    for sort,column in columns.items():
      for ascending in [True,False]:
       for extra,predicate in [({},'1'),({'white':'A'},"white LIKE 'A %'"),({'whiteMin':2600},"CAST(white_elo AS INTEGER)>=2600")]:
        request=dict(sort=sort,ascending=ascending,**extra);direction='ASC' if ascending else 'DESC'
        expected=[r[0] for r in db.execute(f'SELECT id FROM games WHERE {predicate} ORDER BY {column} {direction},id {direction} LIMIT 601')]
        count=db.execute(f'SELECT count(*) FROM games WHERE {predicate}').fetchone()[0]
        actual=[]
        for page in range(3):
            result=query(request);assert result['count']==count,(sort,ascending,extra,'count')
            actual += [row['id'] for row in result['rows'][:200]]
            last=result['rows'][199];raw=bytes.fromhex(last['valueHex'])
            request.update(cursorValue=raw.decode('utf8',errors='replace'),cursorHex=last['valueHex'],cursorID=last['id'])
        assert actual==expected[:600],(sort,ascending,extra,'page order')
        comparisons+=1
    db.execute("CREATE VIRTUAL TABLE names_fts USING fts5(white,tokenize='unicode61 remove_diacritics 2')")
    db.execute('INSERT INTO names_fts(rowid,white) SELECT rowid,white FROM games')
    db.commit()
    for prefix in ['mül','mu','ł','đ','æ','inö','棋','ив','йв','άλ','αλ']:
        actual=query(dict(white=prefix))
        expected=db.execute('SELECT count(*) FROM names_fts WHERE names_fts MATCH ?',('white : "'+prefix+'"*',)).fetchone()[0]
        assert actual['count']==expected,('Unicode prefix',prefix,actual['count'],expected)
    moved='FFFFFFFF-EEEE-DDDD-CCCC-BBBBBBBBBBBB'
    overlay=[dict(id=identity(1),source=source,record=1,folder=moved,deleted=0),dict(id=identity(2),source=source,record=2,folder=folder,deleted=1)]
    assert query(dict(folder=moved,overrides=overlay))['count']==1
    assert query(dict(folder=folder,overrides=overlay))['count']==65535
    assert query(dict(overrides=overlay))['count']==65536
    # Body corruption must be detected before the app publishes any rows.
    order=metadata/'name-order.bin';bad=bytearray(order.read_bytes());bad[0]^=1;order.write_bytes(bad)
    assert subprocess.run([reader,'--verify-catalog-metadata',str(metadata)],capture_output=True).returncode!=0
    print(f'Passed: {comparisons} native/SQLite differential cases × 3 pages, all 8 sorts/directions, sparse/dense boundary, Int64/date/raw-text cursors, Unicode61 prefix parity, overlays, body corruption')
