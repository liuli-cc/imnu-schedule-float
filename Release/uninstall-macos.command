#!/bin/bash
set -euo pipefail
label='cn.liuli.imnu-schedule-float.login'
launchctl bootout "gui/$(id -u)/$label" 2>/dev/null || true
rm -f "$HOME/Library/LaunchAgents/$label.plist"
pkill -x IMNUScheduleFloat 2>/dev/null || true
echo '已关闭自动启动并退出助手。要移除应用，将“教务悬浮助手.app”移到废纸篓即可。'
echo '本机课表和登录会话保留，可在应用内主动清除。'
