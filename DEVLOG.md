# DEVLOG

Plan of record for building `push-to-dictate`. Phases describe *what* gets built; the "Build order" section describes the *sequence* in which they land as working increments.

---

## Phase 0 — Project scaffold

- Xcode 10.1 project, AppKit macOS app, Swift 4.2
- Deployment target: macOS 10.13
- `LSUIElement = YES` in `Info.plist` → menu-bar-only app
- Source layout:
  - `App/` — AppKit entry points (`AppDelegate`, `StatusItemController`)
  - `Core/` — hotkey, audio capture, text injection
  - `Transcribers/` — backend implementations behind a shared protocol
  - `Prefs/` — preferences window + persistence
  - `Resources/` — icons, bundled binaries/models

## Phase 1 — Menu bar presence

- `NSStatusItem` with two icon states: idle and recording
- Menu items: *Start/Stop Dictation*, *Mode ▸ Toggle · Push-to-talk*, *Preferences…*, *Quit*
- No transcription logic — UI shell only

## Phase 2 — Global hotkey

- Implementation: `CGEventTap` (handles both modes with one code path)
- **Toggle mode** (default): tap hotkey → start recording. Tap again → stop, transcribe, inject.
- **Push-to-talk mode**: keyDown starts, keyUp stops and transcribes.
- Default binding: `⌃⌥Space` (reconfigurable in Phase 6)
- Detect Accessibility permission on launch; if missing, prompt once and deep-link to System Preferences → Security & Privacy → Privacy → Accessibility

## Phase 3 — Audio capture

- `AVAudioEngine` tap on `inputNode`
- Convert incoming format to **16 kHz mono Float32 PCM** (whisper's native format — avoids a resample before inference)
- Buffer in memory as `[Float]`; dictation chunks are short enough that no disk spill is needed
- Expose an RMS level so the menu-bar icon can pulse during recording

## Phase 4 — Transcriber abstraction

```swift
protocol Transcriber {
    func transcribe(audio: [Float],
                    completion: @escaping (Result<String, Error>) -> Void)
}
```

Two implementations:

- `WhisperCppTranscriber` — shells out to a bundled `whisper-cli` with `-oj` (JSON output) and parses the result. Simple first pass; can be swapped for direct `libwhisper` linkage later without changing callers.
- `OpenAITranscriber` — `URLSession` multipart POST to `/v1/audio/transcriptions`, model `whisper-1`.

## Phase 5 — Text injection

Default strategy — paste:

1. Snapshot current `NSPasteboard.general` contents
2. Write transcript as plain text
3. Post `⌘V` via `CGEventPost` (keycode 9 + `.maskCommand`)
4. Restore the snapshot after a short delay (~200 ms)

Fallback strategy — typed: `CGEvent.keyboardSetUnicodeString` character-by-character. Slower, but preserves pasteboard and works in apps that intercept paste.

## Phase 6 — Preferences window

- Hotkey picker (record a key combo)
- Mode: Toggle / Push-to-talk
- Backend: Local (whisper.cpp) / OpenAI API
- Local model: `tiny.en` · `base.en` · `small.en` · `medium.en` · `large-v3`
- OpenAI API key — stored in **Keychain**, not in a plist
- Injection method: paste / typed

## Phase 7 — whisper.cpp integration (build side)

- Clone whisper.cpp, build `whisper-cli` for x86_64 on High Sierra
- Model storage: `~/Library/Application Support/push-to-dictate/models/`
- First-run offer: auto-download `small.en` (~450 MB)
- Later milestone: replace the CLI shell-out with Swift↔C bridging-header calls into `libwhisper` (`whisper_init_from_file`, `whisper_full`, `whisper_full_get_segment_text`) for lower latency

## Phase 8 — Polish

- Animated/colored recording indicator in the menu bar
- Optional start/stop sounds
- Error surfaces: no mic, API key missing, model not found, network failure
- Launch-at-login option

---

## Build order

Each step is a working, demo-able increment.

1. **Phases 0 + 1** — empty menu-bar app that launches and quits. Proves the toolchain works on High Sierra.
2. **Phase 2** — hotkey logs "pressed" / "released" to the console.
3. **Phase 3** — hotkey records 5 seconds of audio and writes a WAV to `/tmp`. Verify in QuickTime.
4. **Phases 4 + 7** — shell out to `whisper-cli` on that WAV, print the transcript.
5. **Phase 5** — inject the transcript into the focused field.
6. **Phase 4 (again)** — add the OpenAI backend behind the same protocol.
7. **Phase 6** — preferences UI to switch backends and models.
8. **Phase 8** — polish.

---

## Open questions

1. Default hotkey — `⌃⌥Space` acceptable, or preferred alternative?
2. First-run model acquisition — auto-download `small.en`, or require the user to place a model file manually?
3. OpenAI API key — available for testing, or deferred?
