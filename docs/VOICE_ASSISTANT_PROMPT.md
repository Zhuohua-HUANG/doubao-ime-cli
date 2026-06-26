# 给语音助手复制的调用说明

下面这段可以直接复制给你的语音助手、Agent 或自动化工具：

```text
你可以调用本机 CLI `doubao-voice` 来控制豆包输入法的语音输入。

基础规则：
1. 开始智能免按语音输入：运行 `doubao-voice`
2. CLI 会在检测到说话后，再检测到静音时自动结束/提交。
3. 手动触发免按模式：运行 `doubao-voice handsfree`
4. 长按说话 N 秒：运行 `doubao-voice hold --duration-ms N000`
   例如长按 5 秒：`doubao-voice hold --duration-ms 5000`
5. 检查环境和权限：运行 `doubao-voice inspect`
6. 如果返回 Accessibility permission is not granted，提示用户运行：
   `doubao-voice-authorize`

默认快捷键：
- 豆包免按模式：右 Option 单击
- 豆包长按模式：fn 长按

菜单栏设置：
- 安装包会提供“豆包 Voice CLI”菜单栏助手。
- 用户可以在右上角点击它的麦克风图标，设置“免按模式”和“长按模式”两个快捷键。
- 设置快捷键时应点击快捷键框，然后按下实体按键录制；不要逐字输入按键名称。
- 这两个快捷键应与豆包输入法设置页保持一致。
- 快捷键只能使用 fn、shift、command、option、control 中的单键或组合键，并保留左右侧按键，例如 fn、left-shift、left-command+left-shift、fn+control。
- 除非用户明确要求临时覆盖，否则不要主动给 `doubao-voice` 添加 `--key`。

注意：
- `doubao-voice` 会自己等待语音开始和静音结束；不要在它运行期间重复调用。
- 安装包模式下，macOS 辅助功能权限应授予“豆包 Voice CLI”。
- 这个 CLI 不负责语音识别内容，它只负责触发豆包输入法的语音输入，并在本机做静音判停。
```

## 简短版

```text
调用 `doubao-voice` 开始豆包语音输入；说完停顿后会自动结束。
调用 `doubao-voice handsfree` 手动触发免按模式。
调用 `doubao-voice hold --duration-ms 5000` 表示按住 fn 说话 5 秒。
如果权限不足，调用 `doubao-voice-authorize` 引导用户授权辅助功能。
```
