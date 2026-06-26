# 直接调用入口研究

这份文档记录一次“不依赖快捷键，直接启动豆包语音输入”的入口探测。

目标：

```text
直接调用豆包语音输入功能，不依赖用户设置的快捷键。
```

当前结论：

```text
没有找到稳定的外部 direct-call 入口。
```

因此当前 CLI 仍应把快捷键触发作为默认 provider；只有未来确认存在稳定 IPC/API 时，才把 direct provider 作为正式能力。

## 已找到的线索

### 内部语音函数确实存在

主二进制里能看到内部 Swift/Objective-C 符号和 selector：

```text
DoubaoImeASRShortcutCoordinator.handleShortcut(action:)
ASRPanelManager.openASRPanelIfNeeded(source:type:)
ASRPanelManager.openASRPanel(source:type:)
ASRPanelController
startASR / stopASR
```

另外，`DoubaoImeInputController` 上有一个 Objective-C action selector：

```text
createASRPanelIfNeed:
```

这个符号最值得关注，因为它看起来像“打开 ASR 面板”的菜单 action。但它存在于豆包输入法进程内部的 input method controller 实例上，外部 CLI 不能直接拿到这个对象。

### InputMethodKit 连接存在

`launchctl print gui/<uid>` 可以看到一个 Mach service：

```text
com.bytedance.inputmethod.doubaoime_Connection
```

非沙盒环境下，一个小型 `NSConnection` 探针可以连上它：

```text
rootProxy class: NSDistantObject
createASRPanelIfNeed:: no
openSettings:: no
menu: no
recognizedEvents:: yes
handleEvent:client:: no
```

这强烈说明该连接是标准 InputMethodKit 服务表面，而不是公开的应用控制 API。它没有把 `createASRPanelIfNeed:` 暴露给普通外部客户端。

### 有通知常量，但看起来是进程内使用

`OimeCommon.framework` 里有这些通知名：

```text
DoubaoImeSettings.asrLongPressShortcutKeyNotification
DoubaoImeSettings.asrShortcutKeyNotification
DoubaoImeSettings.asrShortcutRecordingStateNotification
DoubaoImeSettings.enableGloableASRShortcutNotification
DoubaoImeSettings.enableStartASRShortcutNotification
DoubaoImeSettings.requestOpenASRFeedbackPanel
```

这些更像设置页和公共模块之间的进程内 `NotificationCenter` 消息。字符串和导入信息里没有看到稳定的 `DistributedNotificationCenter` 语音开关命令。

主 app 确实使用了 `NSDistributedNotificationCenter`，但可见用途是系统输入源变化、麦克风设置变化等，不是开始/结束语音输入。

### 没有发现公开 app 入口

主 app 和设置 app 的 Info.plist 没有声明：

```text
CFBundleURLTypes
NSServices
MachServices
NSXPCServices
NSUserActivityTypes
```

app bundle 里也没有找到 `.xpc` service。

设置 app 里有这些启动参数相关字符串：

```text
didHandleLaunchArguments
voiceInput
menu_bar
```

它们看起来用于把设置窗口导航到“语音输入”页面，不像是启动/停止语音输入。

## 为什么当前不做 direct invocation

真正的直接调用需要满足其中之一：

1. 豆包提供稳定 URL scheme、XPC service、Mach service 或 distributed notification，明确用于切换 ASR。
2. 能从外部拿到实时的 `DoubaoImeInputController` 实例，并调用 `createASRPanelIfNeed:`。
3. 向豆包输入法进程注入代码或 hook。

只有第 1 种适合公开 GitHub 项目。第 2 和第 3 种都很脆弱、侵入性强：

- Swift 符号和 ABI 细节可能随豆包版本变化。
- 目标对象活在豆包输入法进程里，不在 CLI 进程里。
- 注入/hook 会引入签名、SIP、TCC 和维护问题。

## 当前建议

当前架构保持为：

```text
doubao-voice
  provider: shortcut
```

未来如果找到稳定 IPC/API，可以演进成：

```text
doubao-voice
  provider: direct   # 只有找到稳定入口时启用
  provider: shortcut # fallback
```

现阶段 `doubao-voice` 继续发送豆包默认快捷键：

```text
免按模式：右 Option 单击
长按模式：fn 长按
```
