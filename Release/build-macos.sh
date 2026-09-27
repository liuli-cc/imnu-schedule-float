#!/bin/bash
set -euo pipefail
project_dir="$(cd "$(dirname "$0")/.." && pwd -P)"
release_arch="${1:-$(uname -m)}"
case "$release_arch" in arm64|x86_64) ;; *) echo 'Supported architectures: arm64, x86_64' >&2; exit 1;; esac
release_version="$(cat "$project_dir/VERSION")"
release_package="$project_dir/release-out/macos-$release_arch/IMNU-Schedule-Float"
release_app="$release_package/教务悬浮助手.app"
release_build="$project_dir/.build/github-release-$release_arch"
release_cache="$project_dir/.build/github-release-cache-$release_arch"
export SDKROOT="$(xcrun --sdk macosx --show-sdk-path)"
export MACOSX_DEPLOYMENT_TARGET=14.0
mkdir -p "$release_cache/clang" "$release_cache/swiftpm" "$release_package"
export CLANG_MODULE_CACHE_PATH="$release_cache/clang"
export SWIFTPM_MODULECACHE_OVERRIDE="$release_cache/swiftpm"
cd "$project_dir"
swift build --configuration release --disable-sandbox --scratch-path "$release_build" \
  --triple "$release_arch-apple-macosx14.0"
release_bin="$(swift build --configuration release --scratch-path "$release_build" \
  --triple "$release_arch-apple-macosx14.0" --show-bin-path)"
mkdir -p "$release_app/Contents/MacOS" "$release_app/Contents/Resources"
cp "$release_bin/IMNUScheduleFloat" "$release_app/Contents/MacOS/IMNUScheduleFloat"
cp "$project_dir/Resources/Info.plist" "$release_app/Contents/Info.plist"
test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$release_app/Contents/Info.plist")" = "$release_version"
cp "$project_dir/Release/install-macos.command" "$release_package/安装.command"
cp "$project_dir/Release/uninstall-macos.command" "$release_package/卸载.command"
cp "$project_dir/Release/使用说明.txt" "$release_package/使用说明.txt"
cp "$project_dir/LICENSE" "$release_package/LICENSE.txt"
chmod +x "$release_app/Contents/MacOS/IMNUScheduleFloat" "$release_package/"*.command
codesign --force --deep --sign - "$release_app"
codesign --verify --deep --strict "$release_app"
binary="$release_app/Contents/MacOS/IMNUScheduleFloat"
lipo "$binary" -verify_arch "$release_arch"
if otool -L "$binary" | tail -n +2 | grep -E '/opt/homebrew|/usr/local' >/dev/null; then
  echo 'Non-portable runtime dependency' >&2; exit 1
fi
output="$project_dir/release-out/IMNU-Schedule-Float-macOS-$release_arch-$release_version.zip"
# Explicit UTF-8 ZIP names work across macOS, Windows and GitHub verification.
# Include file permissions, without the developer machine's extended attributes.
python3 "$project_dir/Release/zip-macos.py" "$release_package" "$output"
shasum -a 256 "$output"
