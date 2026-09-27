"""Require all six user downloads and inspect the actual Windows executable architecture."""
import pathlib
import struct
import sys
import zipfile

directory, version = pathlib.Path(sys.argv[1]), sys.argv[2]
names = [f"IMNU-Schedule-Float-macOS-{arch}-{version}.zip" for arch in ("arm64", "x86_64")]
names += [f"IMNU-Schedule-Float-Windows-{arch}-{version}{suffix}"
          for arch in ("x64", "arm64") for suffix in ("-Setup.exe", ".zip")]
for name in names:
    artifact = directory / name
    if not artifact.is_file() or artifact.stat().st_size < 100_000:
        raise SystemExit(f"Missing or empty platform package: {name}")
extras = [p.name for p in directory.glob("IMNU-Schedule-Float-*") if p.name not in names]
if extras:
    raise SystemExit(f"Unexpected platform packages: {extras}")
for arch, wanted in (("x64", 0x8664), ("arm64", 0xAA64)):
    with zipfile.ZipFile(directory / f"IMNU-Schedule-Float-Windows-{arch}-{version}.zip") as package:
        data = package.read("IMNUScheduleFloat.exe")
        offset = struct.unpack_from("<I", data, 0x3C)[0]
        if data[offset:offset+4] != b"PE\0\0" or struct.unpack_from("<H", data, offset+4)[0] != wanted:
            raise SystemExit(f"Wrong packaged Windows architecture: {arch}")
        for included in ("resources/app.asar", "LICENSE.txt", "使用说明.md"):
            package.getinfo(included)
for arch in ("arm64", "x86_64"):
    with zipfile.ZipFile(directory / f"IMNU-Schedule-Float-macOS-{arch}-{version}.zip") as package:
        for included in ("教务悬浮助手.app/Contents/MacOS/IMNUScheduleFloat", "安装.command", "使用说明.txt"):
            package.getinfo("IMNU-Schedule-Float/" + included)
print("Verified six platform downloads:", *names, sep="\n")
