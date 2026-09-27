#!/usr/bin/env python3
"""Create an offline Scriptable delivery; private cache is never added to git."""
import argparse
import base64
import datetime as dt
import hashlib
import json
import os
from pathlib import Path
import shutil
import zipfile

ROOT = Path(__file__).resolve().parent
VERSION = '1.1.0'
NAME = '内师大课表'
UTC = dt.timezone.utc
SHANGHAI = dt.timezone(dt.timedelta(hours=8))
SWIFT_EPOCH = dt.datetime(2001, 1, 1, tzinfo=UTC)


def iso(value):
    if isinstance(value, (int, float)) and not isinstance(value, bool):
        return (SWIFT_EPOCH + dt.timedelta(seconds=value)).isoformat().replace('+00:00', 'Z')
    if isinstance(value, str):
        try:
            parsed = dt.datetime.fromisoformat(value.replace('Z', '+00:00'))
            return parsed.astimezone(UTC).isoformat().replace('+00:00', 'Z')
        except ValueError:
            return ''
    return ''


def sanitize(cache):
    if not isinstance(cache.get('courses'), list):
        raise ValueError('桌面课表缓存格式无效')
    text = lambda value: str(value if value is not None else '')[:300]
    fields = ['id', 'name', 'teacher', 'location', 'weeks']
    courses = []
    for row in cache['courses']:
        course = {key: text(row.get(key)) for key in fields}
        for key in ['weekday', 'startSection', 'endSection']:
            course[key] = int(row[key])
        active = row.get('activeWeeks')
        course['activeWeeks'] = sorted({w for w in active if isinstance(w, int) and 1 <= w <= 60}) if isinstance(active, list) else None
        courses.append(course)
    anchor = iso(cache.get('currentWeekAnchorDate') or cache.get('updatedAt'))
    anchor_key = dt.datetime.fromisoformat(anchor.replace('Z', '+00:00')).astimezone(SHANGHAI).date().isoformat() if anchor else None
    grade_keys = ['id', 'term', 'courseName', 'score', 'credit', 'gradePoint', 'courseNature', 'examType']
    return {
        'schemaVersion': 1, 'term': text(cache.get('term')), 'timeZone': 'Asia/Shanghai',
        'maxWeek': cache.get('maxWeek') or 20, 'currentWeek': cache.get('weekAnchor', cache.get('currentWeek')),
        'weekAnchorDate': anchor_key, 'updatedAt': iso(cache.get('updatedAt')),
        'gradesUpdatedAt': iso(cache.get('gradesUpdatedAt')),
        'exportedAt': dt.datetime.now(UTC).isoformat().replace('+00:00', 'Z'),
        'courses': courses, 'grades': [{k: text(g.get(k)) for k in grade_keys} for g in cache.get('grades', [])],
        'gpa': text((cache.get('profile') or {}).get('gpa'))
    }


def scriptable_manifest(script):
    return {'name': NAME, 'icon': {'color': 'purple', 'glyph': 'calendar-alt'},
            'always_run_in_app': False, 'share_sheet_inputs': ['file-url'], 'script': script}


def script_json(value):
    return json.dumps(value, ensure_ascii=False, separators=(',', ':')).replace('<', '\\u003c').replace('\u2028', '\\u2028').replace('\u2029', '\\u2029')


def image_payload(path):
    if path is None:
        return None
    payload = path.read_bytes()
    if len(payload) > 4 * 1024 * 1024:
        raise ValueError('横幅图片请控制在 4 MB 以内，避免 iOS 小组件内存不足')
    if not (payload.startswith(b'\x89PNG\r\n\x1a\n') or payload.startswith(b'\xff\xd8\xff')):
        raise ValueError('背景仅支持 PNG 或 JPEG；请先生成约 2.15:1 的浅色横幅')
    return base64.b64encode(payload).decode('ascii')


def build(output, data, refresh=False, background=None):
    artwork = image_payload(background)
    expected = {NAME + '.js', NAME + '.scriptable', NAME + '.json', '手机离线课表.html', '安装说明.txt', 'SHA256SUMS.txt'}
    if data and (ROOT.parent / '.git').exists() and output.is_relative_to(ROOT.parent) and not any(output.is_relative_to(folder) for folder in
        [ROOT.parent / 'release-out', ROOT / 'out', ROOT / 'private', ROOT.parent / '.build']):
        raise ValueError('专用包含个人课表，请导出到仓库外或忽略的 release-out / Mobile/private 目录')
    if output.exists() and any(output.iterdir()) and not refresh:
        raise ValueError('输出目录不是空目录，请选择一个新的目录，避免覆盖旧包')
    if refresh and output.exists() and any(p.name not in expected or not p.is_file() for p in output.iterdir()):
        raise ValueError('输出目录包含其他文件，无法原位更新')
    if not data and output.exists() and any((output / p).exists() for p in [NAME + '.json', '手机离线课表.html']):
        raise ValueError('这个目录曾包含个人课表，不能作为公开包输出目录')
    output.mkdir(parents=True, exist_ok=True, mode=0o700)
    core = (ROOT / 'core.js').read_text(encoding='utf-8')
    panel = (ROOT / 'panel.html').read_text(encoding='utf-8').replace('/* __MOBILE_CORE__ */', core)
    script = (ROOT / 'widget.js').read_text(encoding='utf-8').replace('/* __MOBILE_CORE__ */', core)
    script = script.replace('/* __MOBILE_BACKGROUND__ */', script_json(artwork), 1)
    # The marker also appears quoted in phoneView's runtime replacement. Only
    # embed the first occurrence; the quoted marker must stay intact.
    script = script.replace('/* __MOBILE_DATA__ */', script_json(data), 1)
    script = script.replace('/* __MOBILE_HTML__ */', script_json(panel.replace('/* __MOBILE_HOST__ */', 'true')))
    (output / (NAME + '.js')).write_text(script, encoding='utf-8')
    (output / (NAME + '.scriptable')).write_text(json.dumps(scriptable_manifest(script), ensure_ascii=False, indent=2), encoding='utf-8')
    if data:
        (output / (NAME + '.json')).write_text(json.dumps(data, ensure_ascii=False, indent=2), encoding='utf-8')
        (output / '手机离线课表.html').write_text(panel.replace('/* __MOBILE_DATA__ */', script_json(data)).replace('/* __MOBILE_HOST__ */', 'false'), encoding='utf-8')
    shutil.copyfile(ROOT / '安装说明.txt', output / '安装说明.txt')
    checksums = []
    for path in sorted(output.iterdir()):
        if path.is_file() and path.name != 'SHA256SUMS.txt':
            os.chmod(path, 0o600 if data else 0o644)
            checksums.append(hashlib.sha256(path.read_bytes()).hexdigest() + '  ' + path.name)
    (output / 'SHA256SUMS.txt').write_text('\n'.join(checksums) + '\n', encoding='utf-8')
    os.chmod(output / 'SHA256SUMS.txt', 0o600 if data else 0o644)
    zip_path = output.parent / (output.name + '.zip')
    if zip_path.exists() and not refresh:
        raise ValueError('ZIP 已存在，请选择新的输出目录名')
    with zipfile.ZipFile(zip_path, 'w', zipfile.ZIP_DEFLATED) as archive:
        for path in sorted(output.iterdir()):
            archive.write(path, output.name + '/' + path.name)
    os.chmod(zip_path, 0o600 if data else 0o644)
    print(json.dumps({'version': VERSION, 'output': str(output), 'zip': str(zip_path),
                      'private_schedule_included': data is not None,
                      'course_records': len(data['courses']) if data else 0}, ensure_ascii=False))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--cache', type=Path, help='Mac Swift JSON cache or Windows cached JSON')
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--generic', action='store_true', help='Build a public package without private data')
    parser.add_argument('--refresh', action='store_true', help='Update only files produced by this exporter')
    parser.add_argument('--background', type=Path, help='Optional PNG/JPEG wide artwork with blurred light left half')
    args = parser.parse_args()
    if args.generic and args.cache:
        parser.error('--generic 与 --cache 不能同时使用')
    if not args.generic and not args.cache:
        parser.error('请选择 --cache，或使用 --generic 生成无私人数据的公开包')
    data = sanitize(json.loads(args.cache.expanduser().read_text(encoding='utf-8-sig'))) if args.cache else None
    build(args.output.expanduser().resolve(), data, args.refresh, args.background)


if __name__ == '__main__':
    main()
