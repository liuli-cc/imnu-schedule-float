#!/bin/zsh
set -euo pipefail

project_dir="${0:A:h}"
cd "$project_dir"

build_cache="/tmp/imnu-schedule-float-build-cache"
mkdir -p "$build_cache/clang" "$build_cache/swiftpm"
export SDKROOT="/Library/Developer/CommandLineTools/SDKs/MacOSX26.sdk"
export CLANG_MODULE_CACHE_PATH="$build_cache/clang"
export SWIFTPM_MODULECACHE_OVERRIDE="$build_cache/swiftpm"

swift build -c release --disable-sandbox \
  --cache-path "$build_cache/package-cache" \
  --config-path "$build_cache/config" \
  --security-path "$build_cache/security"

app_dir="$project_dir/dist/教务悬浮助手.app"
contents_dir="$app_dir/Contents"
rm -rf "$app_dir"
mkdir -p "$contents_dir/MacOS" "$contents_dir/Resources"
cp "$project_dir/.build/release/IMNUScheduleFloat" "$contents_dir/MacOS/IMNUScheduleFloat"
cp "$project_dir/Resources/Info.plist" "$contents_dir/Info.plist"
chmod +x "$contents_dir/MacOS/IMNUScheduleFloat"
/usr/bin/codesign --force --deep --sign - "$app_dir"
echo "$app_dir"
