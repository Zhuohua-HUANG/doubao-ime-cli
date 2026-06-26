# Prompt for Voice Assistants

Copy the block below into your voice assistant, Agent, or automation tool:

```text
You can call the local CLI `doubao-voice` to control Doubao IME voice input.

Rules:
1. Start smart hands-free Doubao voice input: run `doubao-voice`
2. The CLI will auto-finish after it detects speech followed by silence.
3. Manual hands-free mode: run `doubao-voice handsfree`
4. Hold-to-talk for N seconds: run `doubao-voice hold --duration-ms N000`
   Example for 5 seconds: `doubao-voice hold --duration-ms 5000`
5. Check environment and permission: run `doubao-voice inspect --lang en`
6. If the output says Accessibility permission is not granted, ask the user to run:
   `doubao-voice-authorize`

Default shortcuts:
- hands-free mode: right Option tap
- hold-to-talk mode: fn hold

Menu bar settings:
- The installer provides the "Doubao Voice CLI" menu bar helper.
- The user can click its microphone icon in the top-right menu bar and set the hands-free and hold-to-talk shortcuts.
- To set a shortcut, click the shortcut field and press the physical keys to record them; do not type key names.
- These two shortcuts should match the Doubao IME settings page.
- Shortcuts must use single keys or combinations made from fn, shift, command, option, control, and preserve left/right-side keys. Examples: fn, left-shift, left-command+left-shift, fn+control.
- Do not add `--key` unless the user explicitly wants a temporary override.

Notes:
- `doubao-voice` waits for speech start and silence end by itself; do not call it again while it is running.
- With the pkg installer, grant macOS Accessibility permission to "Doubao Voice CLI".
- This CLI does not transcribe audio. It only triggers Doubao IME voice input and performs local silence endpointing.
```

## Short Version

```text
Run `doubao-voice` to start Doubao voice input; it auto-finishes after speech plus silence.
Run `doubao-voice handsfree` to trigger hands-free mode manually.
Run `doubao-voice hold --duration-ms 5000` to hold fn for 5 seconds.
If permission is missing, run `doubao-voice-authorize`.
```
