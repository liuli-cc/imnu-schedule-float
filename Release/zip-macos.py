import pathlib
import sys
import zipfile

source, output = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])
with zipfile.ZipFile(output, "w", zipfile.ZIP_DEFLATED, compresslevel=9) as package:
    for item in [source] + sorted(source.rglob("*")):
        if item.name == ".DS_Store" or item.name.startswith("._"):
            continue
        package.write(item, item.relative_to(source.parent))
