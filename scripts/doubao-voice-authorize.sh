#!/usr/bin/env bash
set -euo pipefail

# This helper exists because macOS does not allow an installer to silently grant
# Accessibility permission. It can only open the right Settings page and ask the
# current user to approve the app that will launch doubao-voice.

BIN="${DOUBAO_VOICE_BIN:-/usr/local/bin/doubao-voice}"
LANGUAGE="${DOUBAO_VOICE_LANG:-zh-Hans}"
APP="${DOUBAO_VOICE_APP:-/Applications/DoubaoVoiceCLI.app}"

if [ "$LANGUAGE" = "en" ] || [ "$LANGUAGE" = "en-US" ]; then
  echo "Doubao IME CLI authorization"
  echo
  echo "macOS requires Accessibility permission before the menu bar helper can"
  echo "send global keyboard events to Doubao IME."
  echo
  echo "Opening System Settings > Privacy & Security > Accessibility..."
else
  echo "豆包输入法 CLI 授权"
  echo
  echo "macOS 要求发送全局键盘事件的菜单栏助手必须获得辅助功能权限。"
  echo
  echo "正在打开 系统设置 > 隐私与安全性 > 辅助功能..."
fi

if [ -d "$APP" ]; then
  open -g "$APP" >/dev/null 2>&1 || true
fi

open "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility" >/dev/null 2>&1 || true

echo
if [ "$LANGUAGE" = "en" ] || [ "$LANGUAGE" = "en-US" ]; then
  echo "Requesting the macOS Accessibility prompt..."
else
  echo "正在请求 macOS 辅助功能授权提示..."
fi
"$BIN" authorize || true

echo
if [ "$LANGUAGE" = "en" ] || [ "$LANGUAGE" = "en-US" ]; then
  echo "If the command is still not trusted, enable this app in Accessibility:"
  echo "  - Doubao Voice CLI"
  echo
  echo "If you installed only the CLI without the helper app, allow the terminal"
  echo "or voice assistant app that runs doubao-voice."
  echo
  echo "Verify:"
  echo "  doubao-voice inspect --lang en"
else
  echo "如果命令仍然没有权限，请在辅助功能里允许这个 App："
  echo "  - 豆包 Voice CLI"
  echo
  echo "如果你只源码安装了 CLI、没有安装菜单栏助手，再允许运行"
  echo "doubao-voice 的终端或语音助手应用。"
  echo
  echo "验证："
  echo "  doubao-voice inspect"
fi
