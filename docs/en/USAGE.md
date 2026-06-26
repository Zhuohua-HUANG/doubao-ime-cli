# doubao-ime-cli Usage

## Install

Install the package:

```text
doubao-ime-cli-0.1.0.pkg
```

If macOS warns that the package is unsigned, right-click and open it, or install from Terminal:

```bash
sudo installer -pkg doubao-ime-cli-0.1.0.pkg -target /
```

The command is installed to:

```bash
/usr/local/bin/doubao-voice
```

The menu bar helper is installed to:

```text
/Applications/DoubaoVoiceCLI.app
```

After installation, click the microphone icon in the top-right menu bar to open settings.

Check the environment:

```bash
doubao-voice inspect --lang en
```

## First Authorization

Doubao voice input is triggered through a global shortcut. macOS requires Accessibility permission for this. With the pkg installer, the app that sends shortcuts is:

```text
Doubao Voice CLI
```

The installer tries to open the permission page. You can also run:

```bash
doubao-voice-authorize
```

Then allow it in:

```text
System Settings > Privacy & Security > Accessibility
```

Common cases:

- pkg install: allow "Doubao Voice CLI"
- CLI-only source install: allow Terminal / iTerm / Codex / your voice assistant app

Verify:

```bash
doubao-voice inspect --lang en
```

## FSMN-VAD Dependency

Smart endpointing uses Alibaba FunASR `fsmn-vad` in streaming mode. The package includes a bundled Python runtime, FunASR dependencies, and the FSMN-VAD model; rerun this manually if the runtime needs repair:

```bash
doubao-voice-install-fsmn-vad
```

By default, the helper sends audio to FSMN-VAD every 300 ms. On the target Mac, a 300 ms chunk takes about 7 ms of model inference, so it improves endpointing latency without creating model backlog. Advanced users can tune `DOUBAO_VOICE_FSMN_CHUNK_MS`; 200 to 600 is the recommended range.

If dependencies are missing, `doubao-voice` prints a clear FunASR/FSMN-VAD error instead of falling back to the old energy-threshold detector.

## Common Commands

```bash
# Start smart hands-free voice input; it auto-finishes after speech plus silence
doubao-voice

# Manual hands-free trigger: right Option tap by default, no smart endpointing
doubao-voice handsfree

# Hold fn for 5 seconds, then release
doubao-voice hold --duration-ms 5000

# Diagnostics in English
doubao-voice inspect --lang en

# Reopen the authorization helper
doubao-voice-authorize
```

## Default Shortcuts

```text
hold-to-talk: fn
hands-free: right Option tap
```

If you changed Doubao's settings, click the "Doubao Voice CLI" menu bar icon and update:

```text
hands-free mode: click the shortcut field, then press the physical keys matching Doubao's hands-free shortcut
hold-to-talk mode: click the shortcut field, then press the physical keys matching Doubao's hold shortcut
```

The settings window records keyboard events directly; do not type key names. Press keys together for combinations.

After saving, Agents can keep calling `doubao-voice` without knowing the exact key.

Override for one run:

```bash
doubao-voice handsfree --key right-option
doubao-voice hold --key fn --duration-ms 5000
```

Supported shortcut range: use only single keys or combinations made from `fn`, `shift`, `command`, `option`, `control`; left/right-side keys are preserved.

```text
fn
right-option
left-command+left-shift
fn+control
```

## Language

CLI output defaults to Simplified Chinese. English is opt-in:

```bash
doubao-voice inspect --lang en
DOUBAO_VOICE_LANG=en doubao-voice --help
```

## Agent Prompt

Click the menu bar icon, then click "复制说明" in the settings window. Paste the copied text into your voice assistant or Agent so it knows how to call `doubao-voice`.

## Uninstall

```bash
sudo rm -f /usr/local/bin/doubao-voice
sudo rm -f /usr/local/bin/doubao-voice-authorize
sudo rm -rf /Applications/DoubaoVoiceCLI.app
sudo rm -rf /usr/local/share/doubao-ime-cli
```
