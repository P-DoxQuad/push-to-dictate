# push-to-dictate

A menu-bar dictation utility for macOS. Activates on a global hotkey, transcribes speech, and inserts the text into whatever field currently has keyboard focus.

## Target platform

- macOS 10.13 High Sierra
- Mac Pro 5,1 (Xeon, 32 GB DDR3, RX 580) — reference hardware
- Built with Xcode 10.1 / Swift 4.2

## Features (planned)

- Menu-bar resident app (no Dock icon, no main window)
- Global hotkey with two modes:
  - **Toggle** (default): tap to start, tap again to stop and transcribe
  - **Push-to-talk**: hold to record, release to transcribe
- Swappable transcription backend:
  - **Local** — [whisper.cpp](https://github.com/ggerganov/whisper.cpp) running on CPU
  - **Remote** — OpenAI Whisper API (`whisper-1`)
- Text insertion via synthetic paste (default) or synthesized keystrokes (fallback)
- Preferences for hotkey, mode, backend, local model selection, and API key (stored in Keychain)

## Status

Pre-scaffold. See `DEVLOG.md` for the build plan.

## Required permissions

- **Accessibility** — for the global event tap and synthetic keystroke injection
- Microphone access is not prompted on High Sierra (that dialog was introduced in macOS 10.14)

## License

TBD.
