#!/bin/bash
# 卸载：撤掉 Claude Code 接入、关掉奶蛙，删掉 App、命令行链接、登录自启、偏好设置和自己挑的安排
set -uo pipefail

DEST=~/Applications/Naiwa.app
BIN=~/.local/bin/naiwa
AGENT=~/Library/LaunchAgents/com.nwverse.naiwa.plist
SETTINGS=${NAIWA_CLAUDE_SETTINGS:-~/.claude/settings.json}

if [ -x "$DEST/Contents/MacOS/naiwa" ]; then
    # 撤不掉接入就什么都别删：删了 naiwa，settings.json 里的 hook 就指向一个不存在的文件。
    # 没有 settings.json 就没什么可撤的
    if [ -e "$SETTINGS" ] && ! "$DEST/Contents/MacOS/naiwa" hooks uninstall; then
        echo "没能撤掉 Claude Code 接入，什么都没删。先手动删掉 ${SETTINGS} 的 hooks 里含 naiwa 的条目，再重跑这个脚本" >&2
        exit 1
    fi
    "$DEST/Contents/MacOS/naiwa" quit 2>/dev/null
fi
launchctl bootout "gui/$(id -u)/com.nwverse.naiwa" 2>/dev/null
rm -f "$AGENT"
# 只删指向 Naiwa.app 的那个链接，不碰别人放在这里的同名文件
if [ -L "$BIN" ] && [ "$(readlink "$BIN")" = "$DEST/Contents/MacOS/naiwa" ]; then
    rm -f "$BIN"
fi
rm -rf "$DEST"
defaults delete com.nwverse.naiwa 2>/dev/null
# 自己挑的安排（右键「空闲时」「干活时」）；目录里还有别的东西就留着目录
rm -f ~/.config/naiwa/config.json
rmdir ~/.config/naiwa 2>/dev/null
echo "已卸载奶蛙"
