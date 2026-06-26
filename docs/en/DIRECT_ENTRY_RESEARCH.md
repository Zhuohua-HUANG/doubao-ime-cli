# Direct Entry Research

This note records the attempt to find a non-shortcut entry point for starting Doubao IME voice input.

Goal:

```text
Call Doubao voice input directly, without depending on the user's configured keyboard shortcut.
```

Current result:

```text
No stable external direct-call entry was found.
```

The CLI should therefore keep the shortcut provider as the default and treat any future direct provider as experimental until a supported IPC/API surface is confirmed.

## What Was Found

### Internal Voice Functions Exist

The main binary contains internal Swift/Objective-C symbols and selectors for voice input:

```text
DoubaoImeASRShortcutCoordinator.handleShortcut(action:)
ASRPanelManager.openASRPanelIfNeeded(source:type:)
ASRPanelManager.openASRPanel(source:type:)
ASRPanelController
startASR / stopASR
```

There is also an Objective-C action selector on `DoubaoImeInputController`:

```text
createASRPanelIfNeed:
```

This is the most interesting symbol because it looks like the menu action that opens the ASR panel. However, it lives on the input method controller instance inside the Doubao IME process.

### InputMethodKit Connection Exists

`launchctl print gui/<uid>` shows a Mach service:

```text
com.bytedance.inputmethod.doubaoime_Connection
```

A small `NSConnection` probe can connect to it outside the sandbox:

```text
rootProxy class: NSDistantObject
createASRPanelIfNeed:: no
openSettings:: no
menu: no
recognizedEvents:: yes
handleEvent:client:: no
```

This strongly suggests the connection is the standard InputMethodKit server surface, not a public app-control API. It does not expose `createASRPanelIfNeed:` to ordinary external clients.

### Notification Constants Exist, But Appear Local

`OimeCommon.framework` contains notification names:

```text
DoubaoImeSettings.asrLongPressShortcutKeyNotification
DoubaoImeSettings.asrShortcutKeyNotification
DoubaoImeSettings.asrShortcutRecordingStateNotification
DoubaoImeSettings.enableGloableASRShortcutNotification
DoubaoImeSettings.enableStartASRShortcutNotification
DoubaoImeSettings.requestOpenASRFeedbackPanel
```

These look like in-process `NotificationCenter` messages used between the settings UI and common modules. The strings and imports do not show a stable `DistributedNotificationCenter` command for opening or toggling ASR.

The main app does use `NSDistributedNotificationCenter`, but the visible usages are for system/input-source changes and microphone setting updates, not a voice start/stop command.

### No Public App Entry Point Was Found

The app and settings app Info.plist files do not declare:

```text
CFBundleURLTypes
NSServices
MachServices
NSXPCServices
NSUserActivityTypes
```

No `.xpc` service bundle was found under the app bundle.

The settings app contains launch-argument strings such as:

```text
didHandleLaunchArguments
voiceInput
menu_bar
```

Those appear to navigate the settings window to the voice input page. They do not appear to start/stop voice input.

## Why Direct Invocation Is Not Shipped

A true direct invocation would need one of these:

1. A supported URL scheme, XPC service, Mach service, or distributed notification that explicitly toggles ASR.
2. A way to obtain the live `DoubaoImeInputController` instance and call `createASRPanelIfNeed:` from outside the process.
3. Code injection/hooking inside Doubao IME.

Only option 1 is suitable for a public GitHub project. Options 2 and 3 are fragile and invasive:

- Swift symbols and ABI details can change between Doubao versions.
- The target objects live inside the Doubao IME process, not inside this CLI.
- Injection/hooking would create signing, SIP, TCC, and maintenance problems.

## Current Recommendation

Keep the CLI architecture as:

```text
doubao-voice
  provider: shortcut
```

Potential future architecture:

```text
doubao-voice
  provider: direct   # only if a stable IPC/API is found
  provider: shortcut # fallback
```

For now, `doubao-voice` should continue sending the default Doubao shortcut:

```text
hands-free: right Option tap
hold-to-talk: fn hold
```
