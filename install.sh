#!/bin/zsh
set -euo pipefail

project_dir="${0:A:h}"
source_app="$project_dir/dist/教务悬浮助手.app"
installed_app="/Applications/教务悬浮助手.app"
label="cn.liuli.imnu-schedule-float.login"
agent_file="$HOME/Library/LaunchAgents/$label.plist"

[[ -x "$source_app/Contents/MacOS/IMNUScheduleFloat" ]] || { print -u2 "请先运行 ./build.sh"; exit 1; }
/usr/bin/codesign --verify --deep --strict "$source_app"
if [[ -d "$installed_app" ]]; then
  mkdir -p "$project_dir/dist/previous"
  /usr/bin/ditto "$installed_app" "$project_dir/dist/previous/教务悬浮助手.app"
fi
# The app owns no unsaved document. Keep its session/cache in Application Support.
/bin/launchctl bootout "gui/$(id -u)/$label" 2>/dev/null || true
/usr/bin/pkill -x IMNUScheduleFloat 2>/dev/null || true
/usr/bin/ditto "$source_app" "$installed_app"
/usr/bin/codesign --verify --deep --strict "$installed_app"
mkdir -p "$HOME/Library/LaunchAgents"
/usr/bin/python3 - "$agent_file" "$installed_app/Contents/MacOS/IMNUScheduleFloat" "$label" <<'PY'
import os, plistlib, sys
path, executable, label = sys.argv[1:]
with open(path, 'wb') as stream:
    plistlib.dump({
        'Label': label, 'ProgramArguments': [executable], 'RunAtLoad': True,
        'LimitLoadToSessionType': 'Aqua', 'ProcessType': 'Interactive'
    }, stream)
os.chmod(path, 0o600)
PY
/usr/bin/plutil -lint "$agent_file"
/bin/launchctl enable "gui/$(id -u)/$label"
/bin/launchctl bootstrap "gui/$(id -u)" "$agent_file"
print "教务悬浮助手已安装，并设为登录后自动显示悬浮球。"
