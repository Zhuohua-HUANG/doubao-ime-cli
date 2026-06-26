# 逆向说明

这份文档记录 CLI 目前依赖的本机观察结果。整体策略是保守的：工具不修改豆包输入法、不 patch 二进制，也不调用私有云端接口或鉴权接口。

## 安装包位置

在 macOS 上，豆包输入法安装为输入法 bundle：

```text
/Library/Input Methods/DoubaoIme.app
```

相关 bundle identifier：

```text
com.bytedance.inputmethod.doubaoime
com.bytedance.inputmethod.doubaoime.settings
com.bytedance.inputmethod.doubaoime.pinyin
```

## 语音快捷键链路

从 app bundle 的字符串里可以看到语音快捷键相关链路：

```text
ASRShortcutMonitor
ASRShortcutAction
doubleClick
longPressStart
longPressEnd
DoubaoImeASRShortcutCoordinator
handleShortcut(action:)
ASRPanelManager.openASRPanelIfNeeded(source:type:)
```

这说明最不侵入的外部触发方式，不是链接豆包的私有 Swift 类，而是发送豆包本来就监听的键盘事件。

## 设置字段

`DoubaoIme` 和 `DoubaoImeSettings` 的字符串里能看到这些设置字段：

```text
asrShortcutKeyCode
asrShortcutModifierFlags
asrShortcutKeyDisplay
asrLongPressShortcutKeyCode
asrLongPressShortcutModifierFlags
asrLongPressShortcutKeyDisplay
pressRespondMode
```

豆包内部使用 MMKV/内部存储。这些值不保证能通过普通 macOS defaults 读取。因此 CLI 采用三层策略：

1. 尽量读取公开 plist/defaults。
2. 做少量只读、非侵入式的 Application Support 扫描。
3. 如果读不到，就回退到观察到的豆包默认设置：
   - 免按模式：右 Option 单击
   - 长按模式：fn 长按

## 为什么需要辅助功能权限

CLI 通过 CoreGraphics 发送合成的 `flagsChanged` 事件。macOS TCC 会拦截这类全局输入事件，所以需要用户在“辅助功能 / Accessibility”里授权。

## 直接调用研究

见 [DIRECT_ENTRY_RESEARCH.md](DIRECT_ENTRY_RESEARCH.md)。当前结论是：豆包内部确实存在 ASR 相关函数，但还没找到稳定、可公开使用的外部 direct-call 入口。
