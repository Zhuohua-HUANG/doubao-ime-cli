# <img src="assets/AppIcon.png" align="center" width="48" height="48" /> doubao-ime-cli

MacOS 豆包输入法 CLI。让电脑上的Agent能够调用豆包输入法，辅助进行语音输入。

[![Build Status](https://github.com/Zhuohua-HUANG/doubao-ime-cli/actions/workflows/build.yml/badge.svg)](https://github.com/Zhuohua-HUANG/doubao-ime-cli/actions)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![Platform](https://img.shields.io/badge/Platform-macOS%2010.15%2B-blue.svg)](#)

读取本机豆包输入法安装和部分可见配置，然后通过 macOS Accessibility/CoreGraphics 发送与豆包设置页一致的快捷键事件。

```text
/Applications/DoubaoVoiceCLI.app
```

`DoubaoVoiceCLI.app` 是右上角菜单栏助手。点击它的麦克风图标，可以设置：

- 免按模式快捷键：对标豆包设置里的“按一次即可开始说话，再按任意键可结束”
- 长按模式快捷键：对标豆包设置里的“按住说话，松手结束”
- CLI 使用说明：一键复制给语音助手或 Agent

默认语言是简体中文。英文用户可以看 [README.en.md](README.en.md)，CLI 也支持英文输出：

```bash
doubao-voice inspect --lang en
DOUBAO_VOICE_LANG=en doubao-voice --help
```

## 当前支持

- `doubao-voice`  
  触发“智能免按模式”：默认发送右 Option 单击开始语音输入；使用 FunASR FSMN-VAD 检测中文语音开始和结束，然后自动再次触发快捷键结束/提交。

- `doubao-voice handsfree`  
  显式触发“免按模式”：发送一次免按快捷键。这个命令不做智能判停，适合你需要手动控制开始/结束的场景。

- `doubao-voice hold --duration-ms 5000`  
  触发“长按模式”：默认按住 fn，持续指定毫秒数后松开。

- `doubao-voice inspect`  
  查看豆包输入法安装状态、当前输入法、辅助功能权限和本工具推断出的快捷键。

## 安装

### 方式一：DMG 拖拽安装

下载 release 里的：

```text
doubao-ime-cli-0.1.0.dmg
```

打开 DMG，把 `DoubaoVoiceCLI.app` 拖到 `Applications`。App 内已包含 FSMN-VAD Python 运行时、依赖、模型缓存和 CLI 二进制，不需要运行 macOS Installer。

拖拽安装后的 CLI 完整路径是：

```bash
/Applications/DoubaoVoiceCLI.app/Contents/Resources/doubao-voice
```

### 方式二：pkg 安装包

下载 release 里的：

```text
doubao-ime-cli-0.1.0.pkg
```

双击安装。安装完成后命令会写入：

```bash
/usr/local/bin/doubao-voice
/usr/local/bin/doubao-voice-install-fsmn-vad
```

菜单栏助手会写入：

```text
/Applications/DoubaoVoiceCLI.app
```

当前 `make pkg` 默认生成未签名安装包。自己本机测试可以直接安装；公开发布时建议用 Developer ID Installer 证书重新构建：

```bash
SIGN_IDENTITY="Developer ID Installer: Your Name (TEAMID)" make pkg
```

安装包会尝试打开菜单栏助手和 macOS 辅助功能授权页面。macOS 不允许安装包静默授予权限，所以你仍然需要在系统设置里手动允许：

```text
豆包 Voice CLI
```

授权向导也可以手动重跑：

```bash
doubao-voice-authorize
```

智能判停默认使用阿里 FunASR 的 FSMN-VAD。安装包已内置 Python 运行时、FunASR 依赖和 FSMN-VAD 模型；如果运行时损坏或需要手动修复，可以重跑：

```bash
doubao-voice-install-fsmn-vad
```

### 方式三：源码安装

```bash
git clone https://github.com/Zhuohua-HUANG/doubao-ime-cli.git
cd doubao-ime-cli
./install.sh
```

默认安装到：

```bash
~/.local/bin/doubao-voice
```

如果你的 `PATH` 没有 `~/.local/bin`，可以加入：

```bash
echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.zshrc
```

## 权限

macOS 会拦截全局键盘事件。安装包模式下，真正发送快捷键的是菜单栏助手，所以第一次使用前需要授权：

```bash
doubao-voice check --prompt
```

然后在系统设置里允许“豆包 Voice CLI”访问“辅助功能 / Accessibility”。

如果你只用源码安装了 CLI、没有安装菜单栏助手，才需要允许 Terminal、iTerm、Codex 或语音助手这类实际运行 `doubao-voice` 的应用。

## 使用

```bash
# 开始智能免按语音输入；说完停顿后自动结束/提交
doubao-voice

# 手动免按模式：只发送一次免按模式快捷键
doubao-voice handsfree

# 长按 fn 8 秒
doubao-voice hold --duration-ms 8000

# 查看环境和推断配置
doubao-voice inspect
```

如果你在豆包设置里改了快捷键，可以覆盖默认键位：

```bash
doubao-voice handsfree --key left-shift
doubao-voice hold --key fn --duration-ms 5000
```

更推荐的方式是点击右上角“豆包 Voice CLI”图标，在设置里把两个快捷键改成和豆包输入法一致：点击快捷键框，然后按下实体按键录制，不需要逐字输入按键名称。这样 Agent 后续只需要调用 `doubao-voice`，不用关心具体按键。

支持的快捷键范围：只能使用 `fn`、`shift`、`command`、`option`、`control` 中的单键或组合键，并保留左右侧按键。

```text
fn
left-shift
left-command+left-shift
fn+control
```

## 逆向边界

豆包输入法内部的语音输入链路大致是：

```text
ASRShortcutMonitor
  -> DoubaoImeASRShortcutCoordinator.handleShortcut(action:)
  -> ASRPanelManager.openASRPanelIfNeeded(source:type:)
```

用户设置字段在二进制里能看到这些名字：

```text
asrShortcutKeyCode
asrShortcutModifierFlags
asrShortcutKeyDisplay
asrLongPressShortcutKeyCode
asrLongPressShortcutModifierFlags
asrLongPressShortcutKeyDisplay
```

但这些值通常存放在豆包自己的 MMKV/内部存储里，不是稳定公开 API。本工具只做“尽力读取”和“安全 fallback”：

- 免按模式默认：右 Option 单击
- 长按模式默认：fn 长按

如果后续豆包输入法改版，优先点击菜单栏助手手动更新两个快捷键；临时场景也可以使用命令行 `--key` 覆盖。

我也尝试找过“不依赖快捷键、直接调用豆包语音输入 function”的入口。当前结论是：内部函数存在，但没有找到稳定的外部 API。细节见 [docs/DIRECT_ENTRY_RESEARCH.md](docs/DIRECT_ENTRY_RESEARCH.md)。

## 开发与构建

### 构建环境要求

本项目的构建和打包已经在以下环境进行了验证：
- **操作系统**：macOS 15.0+ (Darwin 24.0.0+)
- **编译器**：Apple Clang / Xcode Command Line Tools 15.0+ (支持 Objective-C)
- **Python 环境**：Python 3.9.6+ (系统自带或 Homebrew 安装，用于打包内置的 FSMN-VAD Python 虚拟环境)
- **架构支持**：默认构建当前主机架构的 Native 二进制；打包脚本会自动编译出适用于 macOS 10.15+ 的 Universal/Native 安装包与 DMG。

### 构建步骤

```bash
# 1. 编译本地调试版本
make build
build/doubao-voice inspect

# 2. 编译并制作 macOS pkg 安装包 (.pkg)
make pkg

# 3. 编译并制作拖拽安装 DMG 镜像 (.dmg)
make dmg

# 4. 默认构建中文优先包，若要构建英文优先的包，可运行：
LANGUAGE=en make pkg
```

构建成功后，生成的 Release 产物会存放在 `dist/` 目录下：
```text
dist/doubao-ime-cli-0.1.0.pkg
dist/doubao-ime-cli-0.1.0.dmg
```

## 给语音助手的说明

可以点击右上角“豆包 Voice CLI”图标，在设置窗口里直接复制“CLI 使用说明”；也可以把 [docs/VOICE_ASSISTANT_PROMPT.md](docs/VOICE_ASSISTANT_PROMPT.md) 里的文本复制给语音助手或 Agent。核心调用规则是：

```text
调用 `doubao-voice` 开始智能免按语音输入，说完停顿后自动结束。
调用 `doubao-voice handsfree` 手动触发免按模式。
调用 `doubao-voice hold --duration-ms 5000` 表示按住 fn 说话 5 秒。
如果权限不足，调用 `doubao-voice-authorize` 引导用户授权辅助功能。
```

英文版在 [docs/en/VOICE_ASSISTANT_PROMPT.md](docs/en/VOICE_ASSISTANT_PROMPT.md)。

## 卸载

```bash
./uninstall.sh
```

## License

```text
MIT License

Copyright (c) 2026 doubao-ime-cli contributors

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```
