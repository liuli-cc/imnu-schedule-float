"""Exercise Windows-shaped UTF-8 cache data and the shipped creator kit without a GUI."""
import hashlib
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import zipfile

ROOT=Path(__file__).resolve().parent
with tempfile.TemporaryDirectory(prefix='imnu-creator-') as temp:
    base=Path(temp)
    cache={'term':'演示学期','currentWeek':4,'weekAnchor':4,'currentWeekAnchorDate':'2026-09-27T06:00:00Z','updatedAt':'2026-09-27T07:00:00Z','courses':[{'id':'sample','name':'合成课程','weekday':1,'startSection':1,'endSection':2,'weeks':'1-19','location':'示例教室'}],'profile':{'name':'PRIVATE_SENTINEL','studentNumber':'PRIVATE_SENTINEL'},'cookies':'PRIVATE_SENTINEL'}
    source=base/'Windows缓存.json';source.write_text(json.dumps(cache,ensure_ascii=False),encoding='utf-8-sig')
    output=base/'我的课表'
    result=subprocess.run([sys.executable,str(ROOT/'export-mobile.py'),'--cache',str(source),'--output',str(output)],capture_output=True)
    assert result.returncode==0,result.stderr.decode(errors='replace')
    data=json.loads((output/'内师大课表.json').read_text(encoding='utf-8'))
    assert data['weekAnchorDate']=='2026-09-27' and data['currentWeek']==4
    assert data['courses'][0]['name']=='合成课程'
    for p in output.iterdir(): assert b'PRIVATE_SENTINEL' not in p.read_bytes()
    kit=base/'共享制作工具'
    result=subprocess.run([sys.executable,str(ROOT/'build-creator-kit.py'),'--output',str(kit)],capture_output=True)
    assert result.returncode==0,result.stderr.decode(errors='replace')
    cmd=(kit/'Create-Widget-Windows.cmd').read_bytes();assert b'\r\n' in cmd and b'\n' not in cmd.replace(b'\r\n',b'')
    # Run the exact exporter from the delivered kit, not just the repository copy.
    result=subprocess.run([sys.executable,str(kit/'export-mobile.py'),'--cache',str(source),'--output',str(base/'from-kit')],capture_output=True)
    assert result.returncode==0,result.stderr.decode(errors='replace')
    for line in (kit/'SHA256SUMS.txt').read_text(encoding='utf-8').splitlines():
        digest,name=line.split('  ',1);assert hashlib.sha256((kit/name).read_bytes()).hexdigest()==digest
    with zipfile.ZipFile(kit.with_name(kit.name+'.zip')) as z: assert z.testzip() is None
print('PASS Windows ISO/BOM/Chinese paths, private field filtering, shipped-kit export and checksums (no GUI).')
