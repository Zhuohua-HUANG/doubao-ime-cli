# <img src="assets/AppIcon.png" align="center" width="48" height="48" /> doubao-ime-cli

`doubao-ime-cli` is a macOS command line tool plus a menu bar helper for triggering Doubao IME voice input.

[![Build Status](https://github.com/Zhuohua-HUANG/doubao-ime-cli/actions/workflows/build.yml/badge.svg)](https://github.com/Zhuohua-HUANG/doubao-ime-cli/actions)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![Platform](https://img.shields.io/badge/Platform-macOS%2010.15%2B-blue.svg)](#)

The `doubao-ime-cli` reads local installation/configuration hints where possible, then sends the same macOS keyboard events that Doubao IME listens for.


```text
/Applications/DoubaoVoiceCLI.app
```

Click `DoubaoVoiceCLI.app` microphone icon in the top-right menu bar to configure:

- hands-free shortcut: match Doubao's press-once voice shortcut
- hold-to-talk shortcut: match Doubao's hold voice shortcut
- CLI instructions: copy a prompt for your voice assistant or Agent

Default language:

```text
Simplified Chinese
```

English CLI output:

```bash
doubao-voice inspect --lang en
DOUBAO_VOICE_LANG=en doubao-voice --help
```

## Features

- `doubao-voice`  
  Trigger smart hands-free voice input. It sends the right Option tap to start Doubao voice input, then uses FunASR FSMN-VAD to detect speech start/end before auto-finishing.

- `doubao-voice handsfree`  
  Trigger hands-free mode manually. This sends the hands-free shortcut once and does not run smart endpointing, so it is useful when you want to control start/finish yourself.

- `doubao-voice hold --duration-ms 5000`  
  Trigger hold-to-talk mode. Default shortcut: hold `fn`.

- `doubao-voice inspect`  
  Show Doubao installation, current input source, Accessibility permission, and inferred shortcuts.

## Install

Download and install:

```text
doubao-ime-cli-0.1.0.dmg
```

Open the DMG and drag `DoubaoVoiceCLI.app` to `Applications`. The app bundle contains the FSMN-VAD Python runtime, dependencies, model cache, and CLI binary, so macOS Installer is not required.

The bundled CLI path is:

```bash
/Applications/DoubaoVoiceCLI.app/Contents/Resources/doubao-voice
```

The legacy pkg installer is still available as:

```text
doubao-ime-cli-0.1.0.pkg
```

It installs:

```bash
/usr/local/bin/doubao-voice
/usr/local/bin/doubao-voice-authorize
/usr/local/bin/doubao-voice-install-fsmn-vad
/Applications/DoubaoVoiceCLI.app
```

macOS does not allow an installer to silently grant Accessibility permission. Run:

```bash
doubao-voice-authorize
```

Then allow the app that launches the CLI in:

```text
System Settings > Privacy & Security > Accessibility
```

For the pkg install, allow:

```text
Doubao Voice CLI
```

Smart endpointing uses Alibaba FunASR FSMN-VAD. The package includes a bundled Python runtime, FunASR dependencies, and the FSMN-VAD model. If the bundled runtime is damaged or needs repair, rerun:

```bash
doubao-voice-install-fsmn-vad
```

## Usage

```bash
doubao-voice
doubao-voice handsfree
doubao-voice hold --duration-ms 5000
doubao-voice inspect --lang en
```

If you changed Doubao's shortcuts, click the menu bar helper icon and update the two saved shortcuts there: click a shortcut field, then press the physical keys to record them. Do not type key names. The helper accepts only single keys or combinations made from `fn`, `shift`, `command`, `option`, `control`, and it preserves left/right-side keys. Agents can keep calling `doubao-voice` without passing `--key`.

## Build and Development

### Build Requirements

This project's build and packaging has been verified under:
- **OS**: macOS 15.0+ (Darwin 24.0.0+)
- **Compiler**: Apple Clang / Xcode Command Line Tools 15.0+ (with Objective-C support)
- **Python**: Python 3.9.6+ (for packaging the FSMN-VAD worker's virtualenv)
- **Architecture**: Supports native builds for both Apple Silicon (arm64) and Intel (x86_64). The packaging scripts produce Universal/Native packages targetting macOS 10.15+.

### Build Steps

```bash
# 1. Build local debug binary
make build
build/doubao-voice inspect

# 2. Build the installer package (.pkg)
make pkg

# 3. Build the drag-to-Applications DMG image (.dmg)
make dmg

# 4. Build an English-default package:
LANGUAGE=en make pkg
```

The output artifacts will be written to the `dist/` directory:
```text
dist/doubao-ime-cli-0.1.0.pkg
dist/doubao-ime-cli-0.1.0.dmg
```

## More

- Chinese usage: [docs/USAGE.md](docs/USAGE.md)
- English usage: [docs/en/USAGE.md](docs/en/USAGE.md)
- Voice assistant prompt: [docs/VOICE_ASSISTANT_PROMPT.md](docs/VOICE_ASSISTANT_PROMPT.md)
- Direct entry research: [docs/DIRECT_ENTRY_RESEARCH.md](docs/DIRECT_ENTRY_RESEARCH.md)

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
