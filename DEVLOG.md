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
- Default binding: `⌃⌥Space` (reconfigurable in Phase 7)
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

## Phase 5 — whisper.cpp integration (build side)

- Clone whisper.cpp, build `whisper-cli` for x86_64 on High Sierra
- Binary location: `~/Library/Application Support/push-to-dictate/bin/whisper-cli` (sidecar, not bundled in the app)
- Model storage: `~/Library/Application Support/push-to-dictate/models/`
- First-run offer: auto-download `small.en` (~465 MB)
- Later milestone: replace the CLI shell-out with Swift↔C bridging-header calls into `libwhisper` (`whisper_init_from_file`, `whisper_full`, `whisper_full_get_segment_text`) for lower latency

## Phase 6 — Text injection

Default strategy — paste:

1. Snapshot current `NSPasteboard.general` contents
2. Write transcript as plain text
3. Post `⌘V` via `CGEventPost` (keycode 9 + `.maskCommand`)
4. Restore the snapshot after a short delay (~200 ms)

Fallback strategy — typed: `CGEvent.keyboardSetUnicodeString` character-by-character. Slower, but preserves pasteboard and works in apps that intercept paste.

## Phase 7 — Preferences window

- Hotkey picker (record a key combo)
- Mode: Toggle / Push-to-talk
- Backend: Local (whisper.cpp) / OpenAI API
- Local model: `tiny.en` · `base.en` · `small.en` · `medium.en` · `large-v3`
- OpenAI API key — migrate from `UserDefaults` (where Phase 4 first stores it) to **Keychain**
- Injection method: paste / typed

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
3. **Phase 3** — hotkey records audio and writes a WAV to `~/Library/Application Support/push-to-dictate/debug/`. Verify in QuickTime.
4. **Phase 4** — `Transcriber` protocol with `WhisperCppTranscriber` + `OpenAITranscriber` implementations. Both compile; neither can be verified yet (needs Phase 5 for whisper-cli, or an API key for OpenAI).
5. **Phase 5** — build whisper.cpp, drop binary + model in place, verify end-to-end local transcription via `WhisperCppTranscriber`.
6. **Phase 6** — inject the transcript into the focused field.
7. **Phase 7** — preferences UI to switch backends, pick models, set API key, change hotkey.
8. **Phase 8** — polish.

---

## Open questions

1. Default hotkey — `⌃⌥Space` acceptable, or preferred alternative?
2. First-run model acquisition — auto-download `small.en`, or require the user to place a model file manually?
3. OpenAI API key — available for testing, or deferred?

---

## Progress

### 2026-11-09 / 2026-11-10 — Phase 0 complete, Phase 1 partial

Repo scaffolded, Xcode project created and cleaned, source stubs for Phases 0–7 in place. Build not yet attempted.

- Repo initialised on branch `main`. One commit: `a4dcdd3 scaffold project layout`. All later edits unstaged.
- Source files written (empty bodies for Phase 2+ components):
  - `App/AppDelegate.swift`, `App/StatusItemController.swift`, `App/Info.plist`
  - `Core/HotkeyMonitor.swift`, `Core/AudioRecorder.swift`, `Core/TextInjector.swift`
  - `Transcribers/Transcriber.swift` (protocol + local `TranscriberResult` enum), `WhisperCppTranscriber.swift`, `OpenAITranscriber.swift`
  - `Prefs/Preferences.swift` (UserDefaults-backed; API key will migrate to Keychain)
- `StatusItemController` is functional: menu bar item appears, Start/Stop toggles the icon glyph, Quit works. All other menu actions are no-ops until Phase 2+.
- Xcode 10.1 project created via the IDE (no XcodeGen — MacPorts has 2.46.0 but it requires Swift 5.5+ and would not build under Xcode 10.1).
- Project nested two levels deep after creation (Xcode behaviour); flattened by moving `push-to-dictate.xcodeproj` to repo root and rewriting group paths in `project.pbxproj` from `../App` → `App`, etc.
- `project.pbxproj` rewritten to remove phantom `push-to-dictateTests` and `push-to-dictateUITests` native targets (deleting the folders in the Project Navigator did not remove the target definitions, causing undeletable xctest refs in Products). Validated with `plutil -lint`.
- Build settings:
  - Code Signing Identity → `Sign to Run Locally` (`-`) for Debug and Release; Code Signing Style → Manual; Development Team cleared; Provisioning Profile cleared.
  - App Sandbox capability disabled (dictation utility cannot run sandboxed).
  - `INFOPLIST_FILE = App/Info.plist`
  - `MACOSX_DEPLOYMENT_TARGET = 10.13`
  - `SWIFT_VERSION = 4.2`
  - Main Interface left empty; `MainMenu.xib` deleted (no app menu for `LSUIElement = YES` menu-bar app at this stage).
- Project opens cleanly on reopen. **First build (⌘B) not yet performed** — pending next session.

### 2026-11-11 — Phases 0 + 1 closed

- First build succeeded. First run showed no menu-bar icon: on macOS, `@NSApplicationMain` relies on `MainMenu.xib`'s File's Owner → delegate outlet to wire the delegate; without the xib, `applicationDidFinishLaunching` never fires. Replaced with explicit `App/main.swift` bootstrap (`NSApplication.shared.delegate = AppDelegate(); app.run()`); `@NSApplicationMain` removed.
- Removed `Info.plist` from the Copy Bundle Resources build phase (Xcode warning; the plist is consumed via `INFOPLIST_FILE` build setting, not via resource copying).
- `StatusItemController` now reflects state: toggle item title flips between "Start Dictation" / "Stop Dictation" with the icon glyph, and the Mode submenu checkmark follows `Preferences.hotkeyMode` (persists across launches via `UserDefaults`).
- Mode selection still has no behavioural effect — that wires in Phase 2 alongside `HotkeyMonitor`.
- Menu bar presence, toggle, mode selection persistence, and Quit all verified by hand.

### 2026-11-11 — Phase 2 closed

- `HotkeyMonitor` implemented on `CGEventTap` (`.cgSessionEventTap`, `.defaultTap`), listening for keyDown + keyUp on the main run loop.
- Events are filtered by keycode and by modifier-flag intersection against a device-independent mask (`Control | Alt | Shift | Command`) to ignore device-specific flag bits.
- Auto-repeat keyDowns are discarded (`.keyboardEventAutorepeat` field) so holding the hotkey in toggle mode doesn't retrigger.
- Matched events are consumed (callback returns `nil`) so the combo doesn't leak into focused apps.
- Tap-disabled recovery: `.tapDisabledByTimeout` / `.tapDisabledByUserInput` are re-enabled in-place.
- Default binding: keycode 49 (Space) + Control + Option. Stored in `Preferences` (`hotkeyKeyCode: Int`, `hotkeyModifierFlags: CGEventFlags`); Phase 7 preferences UI will expose a picker.
- First-launch Accessibility check via `AXIsProcessTrusted()`; if missing, an `NSAlert` explains and deep-links to System Preferences → Security & Privacy → Privacy → Accessibility via `x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility`. Permission granted mid-session doesn't retroactively enable an already-created tap — app must be relaunched.
- `StatusItemController` owns the monitor; mode changes (menu + preferences) update `hotkeyMonitor.mode` live. Recording state is now a single `setRecording(_:)` entry point used by menu, hotkey-toggle, and hotkey-PTT paths.
- When running from Xcode, Accessibility is granted to Xcode (the host process), not to the app bundle. Running the built `.app` from Finder requires granting permission to the app itself.
- Verified: toggle mode flips icon on ⌃⌥Space tap; push-to-talk holds while down and releases on key-up.

### 2026-11-11 — Phase 3 closed

- `AudioRecorder` implemented on `AVAudioEngine` with an input-node tap and `AVAudioConverter` for sample-rate/channel conversion to the whisper-native format (16 kHz, mono, Float32, non-interleaved).
- Tap callback runs on the audio thread; converted sample appends go through a serial `DispatchQueue` to keep the capture buffer thread-safe.
- Per-chunk RMS is computed on the raw input buffer and surfaced via `onLevel`; `StatusItemController` throttle-logs it to Console (every 250 ms) as Phase 3 liveness; Phase 8 will drive an icon pulse from the same signal.
- Debug WAV is written on `stop()` to `~/Library/Application Support/push-to-dictate/debug/recording-YYYYMMDD-HHMMSS.wav` as 16-bit linear PCM, mono, 16 kHz. Path is NSLogged. This writer stays until Phase 4 wires the captured `[Float]` into a `Transcriber`; at that point it either comes out or moves behind a preference.
- `setRecording(_:)` short-circuits on repeat-same-state and does not update visuals if `audioRecorder.start()` throws — so a failed capture doesn't lie about being recording.
- Verified with toggle and push-to-talk: WAVs play back at correct pitch, mono, no gaps or clicks.

### 2026-11-12 — Phase 4 code landed (unverified)

- Plan renumbered: whisper.cpp build/integration moved from old Phase 7 to Phase 5 so it sits adjacent to the code that depends on it; text injection and preferences shifted to Phases 6 and 7.
- `WhisperCppTranscriber` implemented: writes `[Float]` → temp WAV (16-bit PCM, 16 kHz, mono) → `Foundation.Process` invoking `whisper-cli` with `-m <model> -f <wav> -l en -t 4 -nt`; stderr suppressed, stdout trimmed and returned. Pre-checks that the binary is executable and the model file exists; otherwise throws with a readable path.
- `OpenAITranscriber` implemented: same temp-WAV path → multipart POST to `https://api.openai.com/v1/audio/transcriptions` with `model=whisper-1`, `language=en`, `response_format=text`. Boundary is a per-request UUID. Uses `URLSession` on a background queue with 60s request / 120s resource timeout. HTTP non-200 produces an `NSError` with a snippet of the response body for diagnostics.
- Both backends write their temp WAV via the same AVAudioFile dance used in `AudioRecorder`; deliberately duplicated rather than extracted to a helper to avoid introducing a new source file for a one-off concern.
- `Preferences` gained `whisperCliPath` (defaults to `~/Library/Application Support/push-to-dictate/bin/whisper-cli`), computed `whisperModelPath` (derives from `localModelFilename` under `~/Library/Application Support/push-to-dictate/models/`), `openAIAPIKey` (plain `UserDefaults` — flagged in comment, migrates to Keychain in Phase 7), and `openAILanguage`. New `Preferences.defaultSupportDirectory` helper centralises the path root.
- `StatusItemController.setRecording(false)` now forwards the captured samples to `makeTranscriber().transcribe(...)` which routes to the backend named in `Preferences.backend` (default `.whisperCpp`). Results and errors both log to Console with elapsed time.
- `AudioRecorder`'s debug WAV writer is left in place deliberately — it's useful alongside the transcript ("was the audio good?") when diagnosing Phase 5 and will be gated behind a preference once Phase 7 adds the UI.
- **Not verified yet**: whisper backend has no binary/model to run against (Phase 5), and the OpenAI backend has no key configured. At stop, you will see a Console log `transcription failed: whisper-cli not found or not executable at ...` which is the expected failure mode until Phase 5.
