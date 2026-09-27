"""Regenerate the Windows browser parser from the native, regression-tested parser."""
import pathlib
import re

root = pathlib.Path(__file__).resolve().parents[1]
native = (root / "Sources/IMNUScheduleFloat/WebSession.swift").read_text()
script = re.search(r'let script = #"""\n([\s\S]*?)\n        """#', native)[1]
script = re.sub(r'^ {8}', '', script, flags=re.M)
literal = script.replace('\\', '\\\\').replace('`', '\\`').replace('${', '\\${')
(root / "windows/src/portal-snapshot.js").write_text(
    "// Generated from WebSession.swift by Release/sync-portal-parser.py.\n"
    "// PortalSnapshotRegression.cjs verifies native / Windows parser parity.\n"
    "module.exports = `" + literal + "`;\n"
)
