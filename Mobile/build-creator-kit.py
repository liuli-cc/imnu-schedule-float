#!/usr/bin/env python3
"""Build a shareable local-only Windows creator kit; never reads personal caches."""
import argparse
import hashlib
import html
import json
from pathlib import Path
import re
import shutil
import zipfile

ROOT = Path(__file__).resolve().parent
VERSION = '1.1.0'
FILES = ['core.js', 'widget.js', 'panel.html', 'export-mobile.py', 'create-windows.py',
         'Create-Widget-Windows.cmd', '安装说明.txt', 'Windows+iPhone完整流程.md', '验收记录.md']


def inline(value):
    value = html.escape(value)
    value = re.sub(r'\[([^\]]+)\]\((https://[^ )]+)\)', r'<a href="\2">\1</a>', value)
    value = re.sub(r'`([^`]+)`', r'<code>\1</code>', value)
    return re.sub(r'\*\*([^*]+)\*\*', r'<strong>\1</strong>', value)


def guide_html(markdown):
    out, code, table = [], False, False
    for line in markdown.splitlines():
        if line.startswith('```'):
            out.append('</code></pre>' if code else '<pre><code>'); code = not code; continue
        if code: out.append(html.escape(line)+'\n'); continue
        if table and not line.startswith('|'):
            out.append('</table></div>'); table = False
        if line.startswith('|'):
            if re.fullmatch(r'[|:\- ]+', line): continue
            cells = line.strip('|').split('|')
            if not table: out.append('<div class="table"><table>'); table = True
            out.append('<tr>'+''.join('<td>'+inline(c)+'</td>' for c in cells)+'</tr>'); continue
        if line.startswith('# '): out.append('<h1>'+inline(line[2:])+'</h1>')
        elif line.startswith('## '): out.append('<h2>'+inline(line[3:])+'</h2>')
        elif line.startswith('> '): out.append('<blockquote>'+inline(line[2:])+'</blockquote>')
        elif line.startswith('- '): out.append('<p class="step">• '+inline(line[2:])+'</p>')
        elif line: out.append('<p>'+inline(line)+'</p>')
    if table: out.append('</table></div>')
    return '''<!doctype html><html lang="zh-CN"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Windows + iPhone 头像课表制作流程</title><style>
*{box-sizing:border-box}body{margin:0;background:#f7f4ee;color:#252a30;font:16px/1.85 -apple-system,BlinkMacSystemFont,"Segoe UI","Microsoft YaHei",sans-serif}main{max-width:920px;margin:50px auto;padding:0 28px 60px}h1{font-size:clamp(28px,3.6vw,40px);line-height:1.3;letter-spacing:-1px;margin:0 0 25px}h2{font-size:24px;margin:50px 0 18px;padding-top:18px;border-top:1px solid #c8d3db}p{margin:13px 0}a{color:#355b77;text-underline-offset:3px}code{font-size:.9em;background:#e8edf0;padding:2px 5px;border-radius:4px;overflow-wrap:anywhere}pre{padding:20px;background:#202c37;color:#edf2f6;overflow:auto;border-radius:12px;line-height:1.6}pre code{background:none;padding:0}blockquote{margin:20px 0;padding:20px 24px;background:#e4ecf1;border-left:4px solid #66869e;border-radius:0 12px 12px 0}.table{overflow:auto}table{width:100%;border-collapse:collapse;font-size:15px}td{padding:12px;border-bottom:1px solid #d3dbe1;vertical-align:top}tr:first-child{font-weight:700;background:#e8edf0}.label{color:#58758a;font-size:12px;letter-spacing:3px;margin-bottom:18px}.flow{display:flex;gap:8px;flex-wrap:wrap;margin:24px 0}.flow span{background:#fff;padding:8px 14px;border:1px solid #dbe1e4;border-radius:9px}@media print{body{background:white}main{margin:0}h2{break-after:avoid}pre,table,blockquote{break-inside:avoid}a{color:#252a30}}
</style><main><div class="label">OFFLINE WIDGET / CREATOR GUIDE · 1.1.0</div><div class="flow"><span>Windows 同步课表</span><span>→ 头像扩图</span><span>→ 本地生成</span><span>→ iCloud 传输</span><span>→ iPhone 中号组件</span></div>'''+''.join(out)+'</main></html>'


def build(output):
    if output.exists(): raise ValueError('请选择新的输出目录，避免覆盖现有文件')
    output.mkdir(parents=True)
    for name in FILES: shutil.copyfile(ROOT/name, output/name)
    # CMD needs ordinary Windows CRLF and UTF-8 without BOM.
    cmd = (ROOT/'Create-Widget-Windows.cmd').read_text(encoding='utf-8')
    (output/'Create-Widget-Windows.cmd').write_bytes(cmd.replace('\r\n','\n').replace('\n','\r\n').encode('utf-8'))
    (output/'Windows+iPhone完整流程.html').write_text(guide_html((ROOT/'Windows+iPhone完整流程.md').read_text(encoding='utf-8')),encoding='utf-8')
    shutil.copyfile(ROOT.parent/'LICENSE',output/'LICENSE.txt')
    (output/'先读我.txt').write_text('先双击 Windows+iPhone完整流程.html 阅读完整教程。\n安装 Python 3.10+ 后运行 Create-Widget-Windows.cmd。\n本包不含任何人的课程、成绩、头像或登录凭据。\n',encoding='utf-8')
    sums=''.join(hashlib.sha256(p.read_bytes()).hexdigest()+'  '+p.name+'\n' for p in sorted(output.iterdir()) if p.is_file())
    (output/'SHA256SUMS.txt').write_text(sums,encoding='utf-8')
    archive=output.with_name(output.name+'.zip')
    if archive.exists(): raise ValueError('ZIP 已存在，请换一个输出名称')
    with zipfile.ZipFile(archive,'w',zipfile.ZIP_DEFLATED) as z:
        for p in sorted(output.iterdir()): z.write(p,output.name+'/'+p.name)
    print(json.dumps({'version':VERSION,'output':str(output),'zip':str(archive)},ensure_ascii=False))


if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--output',required=True,type=Path)
    build(parser.parse_args().output.resolve())
