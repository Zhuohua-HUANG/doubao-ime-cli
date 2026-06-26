# doubao-ime-cli 使用说明

## 安装

下载安装包后双击安装：

```text
doubao-ime-cli-0.1.0.pkg
```

如果 macOS 提示安装包未签名，可以右键打开，或使用命令行安装：

```bash
sudo installer -pkg doubao-ime-cli-0.1.0.pkg -target /
```

安装后命令会写入系统路径：

```bash
/usr/local/bin/doubao-voice
```

同时会安装菜单栏助手：

```text
/Applications/DoubaoVoiceCLI.app
```

安装完成后，屏幕右上角会出现“豆包 Voice CLI”的麦克风图标。点击图标可以打开设置窗口。

正常情况下可以直接运行：

```bash
doubao-voice inspect
```

## 第一次授权

豆包语音输入是通过全局快捷键触发的，macOS 会要求辅助功能权限。安装包模式下，真正发送快捷键的是菜单栏助手：

```text
豆包 Voice CLI
```

安装包会尝试自动打开授权页面。你也可以手动运行：

```bash
doubao-voice-authorize
```

然后在：

```text
系统设置 > 隐私与安全性 > 辅助功能
```

允许实际运行 `doubao-voice` 的应用。常见情况是：

- 安装包模式：允许“豆包 Voice CLI”
- 仅源码安装 CLI：允许 Terminal / iTerm / Codex / 你的语音助手应用

检查是否成功：

```bash
doubao-voice inspect
```

## FSMN-VAD 依赖

智能判停使用阿里 FunASR 的 `fsmn-vad` 流式模型。安装包已内置 Python 运行时、FunASR 依赖和 FSMN-VAD 模型；如果运行时损坏或需要修复，可以手动重跑：

```bash
doubao-voice-install-fsmn-vad
```

默认每 300ms 送一次音频给 FSMN-VAD 推理。当前机器实测 300ms chunk 的模型推理约 7ms，不会形成模型积压，同时比 1000ms 更快响应。需要微调时可以设置 `DOUBAO_VOICE_FSMN_CHUNK_MS`，建议范围为 200 到 600。

如果没有安装依赖，`doubao-voice` 会在命令行直接提示缺少 FunASR/FSMN-VAD，而不是回退到旧的能量阈值算法。

## 常用命令

```bash
# 开始智能免按语音输入，说完停顿后自动结束/提交
doubao-voice

# 手动触发免按模式：默认右 Option 单击，不做智能判停
doubao-voice handsfree

# 长按 fn 说话 5 秒，然后自动松开
doubao-voice hold --duration-ms 5000

# 查看豆包安装、当前输入法、权限和快捷键推断
doubao-voice inspect

# 重新打开授权引导
doubao-voice-authorize
```

## 默认快捷键

当前按豆包输入法默认设置：

```text
长按模式：fn
免按模式：右 Option 单击
```

如果你在豆包输入法里改过快捷键，请点击右上角“豆包 Voice CLI”图标，在设置窗口里同步修改：

```text
免按模式：点击快捷键框，然后按下与豆包“免按模式”一致的实体按键
长按模式：点击快捷键框，然后按下与豆包“长按模式”一致的实体按键
```

设置窗口会直接监听键盘事件并录制按键；不要逐字输入按键名称。组合键需要同时按下。

保存后，Agent 只需要继续调用 `doubao-voice`，不需要知道具体快捷键。

如果你手动改过豆包设置，可以临时覆盖：

```bash
doubao-voice handsfree --key right-option
doubao-voice hold --key fn --duration-ms 5000
```

支持的快捷键范围：只能使用 `fn`、`shift`、`command`、`option`、`control` 中的单键或组合键，并保留左右侧按键。

```text
fn
right-option
left-command+left-shift
fn+control
```

## 语言

CLI 默认输出简体中文。需要英文时可以这样调用：

```bash
doubao-voice inspect --lang en
DOUBAO_VOICE_LANG=en doubao-voice --help
```

安装包会同时安装中英文文档：

```text
/usr/local/share/doubao-ime-cli/docs/zh-Hans/
/usr/local/share/doubao-ime-cli/docs/en/
```

## 给 Agent 复制说明

点击右上角“豆包 Voice CLI”图标，在设置窗口里点击“复制说明”，然后把复制出来的文字粘贴给语音助手或 Agent。Agent 看到说明后，就知道：

```text
调用 doubao-voice 开始智能语音输入，说完停顿后自动结束/提交
调用 doubao-voice handsfree 手动触发免按模式
调用 doubao-voice hold --duration-ms 5000 做长按说话
```

## 卸载

```bash
sudo rm -f /usr/local/bin/doubao-voice
sudo rm -f /usr/local/bin/doubao-voice-authorize
sudo rm -rf /Applications/DoubaoVoiceCLI.app
sudo rm -rf /usr/local/share/doubao-ime-cli
```
