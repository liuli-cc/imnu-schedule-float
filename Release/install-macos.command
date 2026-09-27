#!/bin/bash
set -euo pipefail
package_dir="$(cd "$(dirname "$0")" && pwd)"
source_app="$package_dir/教务悬浮助手.app"
if [[ -d '/Applications/教务悬浮助手.app' && -w '/Applications/教务悬浮助手.app' ]]; then
  target_app='/Applications/教务悬浮助手.app'
else
  target_app="$HOME/Applications/教务悬浮助手.app"
fi
codesign --verify --deep --strict "$source_app"
mkdir -p "$(dirname "$target_app")"
staging="$(mktemp -d "$(dirname "$target_app")/.imnu-install.XXXXXX")"
trap 'rm -rf "$staging"' EXIT
/usr/bin/ditto "$source_app" "$staging/教务悬浮助手.app"
codesign --verify --deep --strict "$staging/教务悬浮助手.app"
label='cn.liuli.imnu-schedule-float.login'
agent="$HOME/Library/LaunchAgents/$label.plist"
launchctl bootout "gui/$(id -u)/$label" 2>/dev/null || true
pkill -x IMNUScheduleFloat 2>/dev/null || true
if [[ -d "$target_app" ]]; then
  backup="$HOME/Library/Application Support/IMNUScheduleFloat/InstallBackups/上一版.app"
  mkdir -p "$(dirname "$backup")"
  if [[ -d "$backup" ]]; then mv "$backup" "$staging/OlderBackup.app"; fi
  mv "$target_app" "$backup"
fi
if ! mv "$staging/教务悬浮助手.app" "$target_app"; then
  if [[ -n "${backup:-}" && -d "$backup" ]]; then mv "$backup" "$target_app"; fi
  exit 1
fi
codesign --verify --deep --strict "$target_app"
mkdir -p "$(dirname "$agent")"
temporary="$staging/agent.plist"
/usr/bin/plutil -create xml1 "$temporary"
/usr/libexec/PlistBuddy -c "Add :Label string $label" "$temporary"
/usr/libexec/PlistBuddy -c 'Add :ProgramArguments array' "$temporary"
/usr/libexec/PlistBuddy -c "Add :ProgramArguments:0 string $target_app/Contents/MacOS/IMNUScheduleFloat" "$temporary"
/usr/libexec/PlistBuddy -c 'Add :RunAtLoad bool true' "$temporary"
/usr/libexec/PlistBuddy -c 'Add :LimitLoadToSessionType string Aqua' "$temporary"
/usr/libexec/PlistBuddy -c 'Add :ProcessType string Interactive' "$temporary"
chmod 600 "$temporary"
mv "$temporary" "$agent"
launchctl bootstrap "gui/$(id -u)" "$agent"
echo '教务悬浮助手已安装，登录后会自动显示悬浮球。已有课表与登录会话保留。'
