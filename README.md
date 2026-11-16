# Push to Dictate

Menu-bar dictation application for macOS. A configurable global hotkey activates audio capture. On release, captured audio is transcribed and inserted into the focused text field via synthesized paste or keystroke events.

Runs on CPU. No GPU, Neural Engine, or network connection is used by the local backend.

## Version

2026.11.2 (CalVer: `YYYY.MM.PATCH`).

## Supported platforms

- macOS 10.11 El Capitan through macOS 15 Sequoia.
- Intel x86_64 CPUs, Nehalem microarchitecture or newer. Covers every Intel Mac from 2009 onward: Mac Pro 4,1 and 5,1, every iMac, MacBook Pro, MacBook Air, MacBook, Mac mini, iMac Pro, and Intel Mac Pro 7,1. SSE4.2 required; AVX / AVX2 / FMA / F16C are not required and explicitly disabled in the whisper.cpp build.
- Apple Silicon runs the binary under Rosetta 2. Native arm64 is not currently targeted.

## Capabilities

- Global hotkey. Default `⌃⌥Space`. Configurable in Preferences.
- Two activation modes: Toggle (tap on, tap off) and Push-to-talk (hold to record, release to transcribe).
- Local transcription backend: [whisper.cpp](https://github.com/ggerganov/whisper.cpp) v1.7.2 compiled with SSE4.2 only, Accelerate BLAS auto-detected.
- Remote transcription backend: OpenAI Whisper API (`whisper-1`).
- Text insertion methods: pasteboard or synthetic Unicode keystrokes.
- Model catalog with hardware-aware per-model rating.
- Custom model download via arbitrary `ggml-*.bin` URL.
- Continuous dictation (experimental, Toggle mode only): transcribes mid-session on short pauses instead of waiting for the user to stop, with prompt-chaining across chunks for context. Mutually exclusive with silence auto-stop.
- Silence auto-stop: ends the recording session automatically after a configurable period of silence.
- Preferences backup and restore to plist. Reset-to-defaults button in Advanced.
- Manual update check against the GitHub Releases API. User-initiated, no auto-download. Skipping a version is persistent until a newer one appears.

## Installation

### Pre-built application

`Push-to-Dictate-v2026.11.1-Full.zip` is attached to each release at https://github.com/P-DoxQuad/push-to-dictate/releases. The archive expands to `Push to Dictate.app`. Installation location: `/Applications/`.

### Build from source

Requires Xcode 10.1+ and CMake (MacPorts `cmake` or system).

```
git clone https://github.com/P-DoxQuad/push-to-dictate.git
cd push-to-dictate
./scripts/setup.sh
open push-to-dictate.xcodeproj
```

`scripts/setup.sh` is idempotent. It clones whisper.cpp at the pinned commit into `vendor/whisper.cpp/`, runs CMake with the no-AVX flags, compiles `whisper-cli`, and downloads `ggml-tiny.en-q8_0.bin` and `ggml-base.en-q8_0.bin` into `vendor/models/`.

The Xcode `push-to-dictate` scheme produces `Push to Dictate.app` in its DerivedData `Build/Products/` directory.

## Permissions

- **Accessibility**: required for `CGEventTap` (global hotkey capture) and `CGEvent.post` (synthesized keystroke injection). First launch presents an alert and opens System Preferences → Security & Privacy → Privacy → Accessibility.
- **Microphone**: prompted automatically on macOS 10.14 Mojave and newer, using the `NSMicrophoneUsageDescription` string from `Info.plist`. No microphone permission model exists on 10.11 through 10.13; audio capture works without a prompt.
- **Notifications**: delivered via `UNUserNotificationCenter` on macOS 10.14 and newer (requires one-time user authorization at first launch), falling back to `NSUserNotificationCenter` on 10.11 through 10.13.

## Code signing

Signed with the `Sign to Run Locally` identity. Apple Developer Program signing and notarization require a deployment target newer than the lowest supported OS.

On first launch of a bundle not built on the current machine, Gatekeeper rejects it with "cannot be opened because the developer cannot be verified". Finder right-click → Open bypasses this prompt. The acknowledgment persists per machine.

## Bundled models

Shipped inside `Push to Dictate.app/Contents/Resources/`:

| Filename                        | Size   |
|---------------------------------|--------|
| `ggml-tiny.en-q8_0.bin`         | 42 MB  |
| `ggml-base.en-q8_0.bin`         | 78 MB  |

Default `Preferences.localModelFilename` resolves to `ggml-base.en-q8_0.bin`. First-launch auto-selection picks the highest-tier model that is rated Recommended for the host CPU and is already on disk.

## Downloadable models

Exposed through Preferences → Transcription → Manage Models:

| Filename                             | Size   |
|--------------------------------------|--------|
| `ggml-small.en-q8_0.bin`             | 252 MB |

Download target: `~/Library/Application Support/push-to-dictate/models/`. Overridable via `Preferences.modelsDirectory`. A custom-URL field accepts any `ggml-*.bin`.

Per-model rating (Recommended, Slow, Not recommended) is derived from AVX2 and FMA support (via `sysctl hw.optional.*`) and logical CPU count (via `ProcessInfo.activeProcessorCount`).

## OpenAI backend

Implemented. Not yet verified end-to-end against a live API key. The multipart upload path compiles and the Keychain entry for the API key is defined.

## Menu bar menu

Clicking the status-bar icon reveals, top to bottom: a disabled status block (active model, thread count for the local backend, activation mode · output method), Start/Stop Dictation with the current hotkey, Mode submenu (Toggle / Push-to-talk), Preferences, Help, About, Grant Accessibility Access (only when permission is missing), Check for Updates, and Quit. Help opens an in-app scrollable window covering permissions, hotkey usage, models, backends, and troubleshooting. When a pending update has been detected, the icon gains a small orange "1" badge and the Check for Updates row bolds to blue.

## Preferences categories

- **General**: hotkey, launch at login, preferences backup export/import.
- **Transcription**: backend, local model, Manage Models, models folder override, OpenAI API key.
- **Audio**: input device, start/stop sounds, silence auto-stop, continuous dictation (pause length, max chunk length).
- **Output**: text insertion method, typed keystroke delay.
- **Interface**: colored menu-bar icon toggle.
- **Advanced**: transcription threads, accuracy (beam size), debug recording toggle, logging, reset-to-defaults.

Storage: `UserDefaults` for most values. OpenAI API key is stored in the Keychain under service `push-to-dictate`.

## Repository layout

```
App/           AppKit entry points, status item, About, menu bar
Core/          Hotkey monitor, audio capture, text injection, logger
Transcribers/  Transcriber protocol, whisper.cpp and OpenAI implementations
Prefs/         Preferences, Preferences window, Manage Models window, model catalog
icons/         Source PNGs and generated .icns
Licenses/      Third-party license texts, bundled into Resources
scripts/       setup.sh for whisper.cpp vendoring and model fetch
vendor/        Gitignored. Populated by setup.sh.
```

## License

MIT. See [`LICENSE`](LICENSE). Third-party components retain their original licenses. Full text: [`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md).
