# Reverse Engineering Notes

This document records the local observations used by the CLI. It is intentionally conservative: the tool does not patch Doubao IME and does not call private cloud or authentication endpoints.

## Installed Bundle

On macOS, Doubao IME is installed as an input method bundle:

```text
/Library/Input Methods/DoubaoIme.app
```

Useful bundle identifiers:

```text
com.bytedance.inputmethod.doubaoime
com.bytedance.inputmethod.doubaoime.settings
com.bytedance.inputmethod.doubaoime.pinyin
```

## Voice Shortcut Path

Strings in the app bundle indicate the voice shortcut flow:

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

That suggests the least invasive external trigger is not linking private Swift classes, but sending the same keyboard events the app already listens for.

## Settings Keys

Strings in `DoubaoIme` and `DoubaoImeSettings` include:

```text
asrShortcutKeyCode
asrShortcutModifierFlags
asrShortcutKeyDisplay
asrLongPressShortcutKeyCode
asrLongPressShortcutModifierFlags
asrLongPressShortcutKeyDisplay
pressRespondMode
```

The app uses MMKV internally. These settings are not guaranteed to be readable as ordinary macOS defaults. The CLI therefore:

1. Reads public plist/defaults where possible.
2. Attempts a small, non-invasive scan of the Doubao application support folder.
3. Falls back to the observed settings UI defaults:
   - hands-free mode: left Shift tap
   - hold mode: fn hold

## Why Accessibility Permission Is Required

The CLI posts synthetic `flagsChanged` events through CoreGraphics. macOS TCC requires Accessibility permission for this to affect other apps/input methods.

## Direct-Call Research

See [DIRECT_ENTRY_RESEARCH.md](DIRECT_ENTRY_RESEARCH.md) for the current attempt to find a non-shortcut API. In short: internal ASR functions exist, but no stable external direct-call entry has been found yet.
