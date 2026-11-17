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

- `NSStatusItem` rendering a 24×24 `NSImage` (replaced an earlier unicode-glyph placeholder).
- Three bundled icon variants at 44 × 44: black, white, colored.
- Auto-mode selection: colored if `Preferences.useColoredMenuBarIcon` is on, otherwise black/white based on menu-bar appearance. Dark menu bar detected via `NSApp.effectiveAppearance` on 10.14+ and `AppleInterfaceStyle` in global `UserDefaults` on 10.13.
- Live update: KVO on `effectiveAppearance` + `AppleInterfaceThemeChangedNotification` distributed observer.
- Four state indicators: `.idle` (plain icon), `.recording` (green dot blinking in corner every 0.5 s), `.processing` (sky-blue dot blinking), `.error` (whole icon tinted red; auto-clears after 5 s or on notification click).
- Menu items: *Start/Stop Dictation*, *Mode ▸ Toggle · Push-to-talk*, *Preferences…*, *Quit*.

## Phase 2 — Global hotkey

- `CGEventTap` on `.cgSessionEventTap`, matched events consumed so the combo doesn't leak into focused apps.
- **Toggle mode** (default): tap hotkey → start recording. Tap again → stop, transcribe, inject.
- **Push-to-talk mode**: keyDown starts, keyUp stops and transcribes.
- Default binding: `⌃⌥Space`. Reconfigurable via Preferences → General → Hotkey.
- Hotkey picker rule: standalone keys are rejected unless they're F1–F20 (keycodes 96–122 + 64/79/80/90/105/106/107/113). Everything else requires at least one of ⌃ ⌥ ⇧ ⌘.
- Accessibility permission checked on launch; if missing, an `NSAlert` explains and deep-links to System Preferences → Security & Privacy → Privacy → Accessibility.
- Hotkey recorder also observes `.systemDefined` events and logs subtype/data for diagnostic purposes (Pause/Break and similar keys that macOS routes through the HID system-event channel).

## Phase 3 — Audio capture

- `AVAudioEngine` tap on `inputNode` with `AVAudioConverter` producing **16 kHz mono Float32 PCM** (whisper's native format — avoids a resample before inference).
- Buffer in memory as `[Float]`; dictation chunks are short enough that no disk spill is needed. Buffer mutation serialized on a private `DispatchQueue` since the tap callback runs on an audio thread.
- Per-chunk RMS computed from the raw input buffer. Surfaced via `onLevel` and used to:
  - Drive the icon pulse (Phase 8).
  - Track peak RMS across the recording; `StatusItemController` skips transcription when peak stays below `0.01` (silent-recording detection — no injection, no notification, icon returns straight to `.idle`).
- Input device selection via CoreAudio (`AudioObjectGetPropertyData` enumeration; `kAudioOutputUnitProperty_CurrentDevice` on the input node's AudioUnit). Stored as `Preferences.inputDeviceUID` (empty = system default).
- Debug WAV writer: every stop dumps the captured samples to `~/Library/Application Support/push-to-dictate/debug/recording-YYYYMMDD-HHMMSS.wav` (16-bit PCM, mono, 16 kHz) for post-hoc comparison against transcripts.

## Phase 4 — Transcriber abstraction

```swift
protocol Transcriber {
    func transcribe(audio: [Float],
                    completion: @escaping (TranscriberResult) -> Void)
}
```

(Swift 4.2 predates `Result<Success, Failure>` in the standard library; a local `TranscriberResult` enum replaces it.)

Two implementations, both run on a background queue:

- `WhisperCppTranscriber` — writes samples to a temp 16-bit WAV, invokes `whisper-cli -m <model> -f <wav> -l en -t 4 -nt` via `Foundation.Process`. Reads stdout, trims, returns. stderr suppressed. Pre-checks binary executability and model file existence before spawning.
- `OpenAITranscriber` — multipart POST to `https://api.openai.com/v1/audio/transcriptions` with `model=whisper-1`, `language=en`, `response_format=text`. Per-request UUID boundary. 60 s request / 120 s resource timeouts.

Both temp WAVs use the same path (`AVAudioFile` with linear-PCM settings) — logic duplicated between the two files intentionally to avoid introducing a shared helper module for a one-off concern.

`makeTranscriber()` in `StatusItemController` reads `Preferences.backend` on every transcription call, so backend switches from the Preferences window take effect on the next recording without needing to recreate anything.

## Phase 5 — whisper.cpp integration (build side)

- **Pinned to v1.7.2.** Upstream commits from 2024-12-08 onward include `#include <filesystem>` in `ggml/src/ggml-backend-reg.cpp`; Xcode 10.1's libc++ has no `<filesystem>` header. v1.7.2 is the last tag that still builds on High Sierra.
- **No-AVX build flags.** Mac Pro 5,1 Westmere Xeons (X5650 class) lack AVX / AVX2 / FMA / F16C. CMake flags: `-DGGML_METAL=OFF -DGGML_AVX=OFF -DGGML_AVX2=OFF -DGGML_FMA=OFF -DGGML_F16C=OFF -DGGML_NATIVE=ON -DCMAKE_BUILD_TYPE=Release`. Accelerate framework auto-detected for BLAS.
- `scripts/setup.sh` (idempotent): clones whisper.cpp at the pinned commit into `vendor/whisper.cpp/`, builds with the above flags via MacPorts `cmake` (or system `cmake`), renames the built `main` binary to `whisper-cli` (v1.7.2 predates the upstream rename), downloads `ggml-small.en.bin` from Hugging Face, verifies SHA256.
- `vendor/` is `.gitignore`'d; the script re-populates it. Setup is the preservation story: no reliance on Hugging Face or upstream whisper.cpp remaining up forever (user will later fork the repo and host the model on their own GitHub Release; two lines in `setup.sh` flip over).
- **Bundled in the `.app`** via an Xcode Copy Files build phase that drops `vendor/whisper.cpp/build/bin/whisper-cli` and `vendor/models/ggml-small.en.bin` into `Contents/Resources/` on every build. End users get a self-contained offline app; dev builds also run against the bundled copy.
- Runtime path resolution (both `whisperCliPath` and `whisperModelPath`): **user override → bundle Resources**. No Application Support fallback. Models and the binary are dependencies, not user data, so they live in the bundle only.
- Optional `Preferences.modelsDirectory` lets a power user point at an external folder — e.g. models on a secondary drive. Empty = use bundle.
- **Performance baseline on the X5650 without AVX**: roughly 15× slower than realtime for the `small.en` model. Example: 1.4 s of audio → 21.3 s processing. Usable for short dictation; slow for anything longer. Deferred tuning: quantized small.en-q5_0, greedy decoding (`-bs 1 -bo 1`), thread count tweaks, direct `libwhisper` linkage via a Swift↔C bridging header.

## Phase 6 — Text injection

`TextInjector.insert(_:)` reads `Preferences.injectionMethod` on each call and dispatches to a private serial queue so neither path blocks main.

**Paste strategy** (default):

1. Snapshot `NSPasteboard.general` contents (per-item, per-type, deep-copied into fresh `NSPasteboardItem`s).
2. Write transcript as `.string`.
3. Post `⌘V` via `CGEvent.post(tap: .cghidEventTap)` (virtual key 9 + `.maskCommand`).
4. Restore the snapshot after a fixed 200 ms delay (heuristic — too short clobbers the paste, too long leaves a visible clipboard gap).

**Typed strategy**: iterates `text.unicodeScalars`, posting one keyDown/keyUp pair per scalar via `CGEvent.keyboardSetUnicodeString`. No inter-character pacing — relies on the target app accepting events at full speed. Near-instant for short dictation, visibly types out multi-sentence output. Preserves pasteboard; works in apps that intercept paste (some terminals, secure fields).

Choice exposed via radio buttons in Preferences → Output.

## Phase 7 — Preferences window

Programmatic AppKit, no XIB. Split-view layout: left `NSTableView` sidebar listing six categories, right content container swapping in the selected category's `NSGridView`. Window is resizable; minimum 640 × 340.

Categories:

- **General** — Hotkey picker (click-to-record, writes `Preferences.hotkeyKeyCode` + `hotkeyModifierFlags`; live-applies to `HotkeyMonitor` via an `onHotkeyChanged` callback). Startup checkbox (Launch at login). Backup Export…/Import… buttons.
- **Transcription** — Backend popup (whisper.cpp / OpenAI). Local model popup (populated from bundle Resources or `modelsDirectory`). Models folder field with Choose…/Clear buttons; empty = use bundle (field pre-populated with the bundle Resources path so you can see where models live by default). OpenAI API key `NSSecureTextField`. The model/models-folder rows hide when backend is OpenAI; the API key row hides when backend is whisper.cpp.
- **Audio** — Input device popup (System default + CoreAudio enumerated inputs). Start-sound and Stop-sound popups (scanning `/System/Library/Sounds/` and `~/Library/Sounds/`; "None" means silent; previewing on change).
- **Output** — Text insertion radio buttons (Paste / Typed).
- **Interface** — Colored menu bar icon checkbox. Changes trigger a live icon refresh via `onColoredIconChanged`.
- **Advanced** — Log everything checkbox.

Mode (Toggle / Push-to-talk) stays in the menu-bar menu — it's a quick-flip setting rather than a preference.

Backup Export/Import writes a plist containing:
- `userDefaults` — every key listed in `Preferences.allUserDefaultsKeys`.
- `openAIAPIKey` — pulled from Keychain, written back to Keychain on import.
- `launchAtLogin` — reflects whether the LaunchAgents plist exists; re-created on import.
- `version` — format version marker.

API key stays in the Keychain (`kSecClassGenericPassword`, service `push-to-dictate`, account `openai-api-key`). Transparent one-shot migration on first read: if Keychain is empty but a legacy `UserDefaults` value exists (from Phase 4 before Keychain landed), it's copied over and removed from UserDefaults. Keychain helpers are private statics on `Preferences` — no new source file.

## Phase 8 — Polish

- **App icon** — `.icns` generated from a 1024 × 1024 colored source via `sips` + `iconutil`; bundled via Xcode Copy Files; `CFBundleIconFile` wired in `Info.plist`.
- **Menu-bar icon states** — see Phase 1.
- **Sounds** — `Preferences.startSound` / `stopSound`, system-sound picker with "None" to disable.
- **Launch at login** — checkbox installs/removes `~/Library/LaunchAgents/com.paradoxicalquad.push-to-dictate.plist` (`Label`, `ProgramArguments = [Bundle.main.executablePath]`, `RunAtLoad = true`). Not using `SMLoginItemSetEnabled` because that requires a signed helper, which Sign-to-Run-Locally builds can't provide.
- **Error surfaces** — `showError(title:detail:)` logs via `Logger.error`, posts an `NSUserNotification`, sets icon state to `.error`. Pre-flight checks in `StatusItemController.setRecording(true)` catch missing whisper-cli, missing model, and missing OpenAI API key before audio capture starts. Runtime failures (mic start, transcription) also route through `showError`. `NSUserNotificationCenterDelegate` forces banners even when the app is frontmost and clears the error tint early if the user clicks the banner.
- **Silent recording detection** — see Phase 3.
- **Logger** (`Core/Logger.swift`) — two levels, both always `NSLog`'d; `.error` always written to file, `.info` written to file only when `Preferences.logEverything` is on. File at `~/Library/Application Support/push-to-dictate/logs/push-to-dictate.log`, one-line append per event, writes serialized on a dedicated queue.
- **Move-to-Applications prompt** — first launch from outside `/Applications/`, `~/Applications/`, or an Xcode DerivedData path shows an `NSAlert` offering to move. "Don't Ask Again" persists via `Preferences.suppressedMoveToApplicationsPrompt`. On "Move", `FileManager` moves the bundle and a detached `/bin/sh` relaunch script `open`s the new copy after a 1 s sleep.
- **Transcription speed tuning** — `Preferences.transcriptionThreads` (stepper + field under Preferences → Advanced, 1 to the host's logical CPU count, default 6; hint reads *Max: N · Recommended: ⅓–½ of max*) and `Preferences.beamSize` (stepper + field, 1–10, default 5, user-facing label "Accuracy" with hint *1 = greedy (fastest) · 5 = default · 10 = thorough (slowest)*). Both get appended to the `whisper-cli` invocation as `-t`, `-bs`, `-bo` (beam-size doubles as best-of). Both read at transcribe time so changes take effect on the next dictation. `PreferencesWindowController` conforms to `NSMenuDelegate` and rescans the models folder in `menuNeedsUpdate(_:)` so newly dropped model files appear on the next click without reopening the window.
- **Debug-recording toggle** — `Preferences.saveDebugRecordings` (default **off**) gates the `AudioRecorder` WAV writer. `~/Library/Application Support/push-to-dictate/debug/` no longer accumulates files during normal use. A **Clear Debug Recordings…** button in Preferences → Advanced empties the folder on demand with a count-and-confirm alert.
- **Log maintenance** — **Clear Log…** button in Preferences → Advanced truncates `push-to-dictate.log` through `Logger.clear()`. `Logger.logFileURL` is exposed statically so the UI can show the path in the confirmation alert.
- **Model management** — `Prefs/ModelCatalog.swift` defines a fixed catalog of five Q8_0 models (tiny.en, base.en, small.en, medium.en, large-v3-turbo). Each `CatalogModel` has filename, display name, size, HuggingFace URL, `isBundled: Bool` (tiny + base), `minTier: HardwareTier`, and `isCustom: Bool`. `Prefs/ModelDownloader.swift` drives a `URLSessionDownloadTask` per download, verifies the `ggml`/`lmgg` magic header before writing to the destination, and reports progress + completion through closures. `Prefs/ManageModelsWindowController.swift` is the UI — opened from a **Manage Models…** button next to the Local model popup via `beginSheet(_:completionHandler:)`. Layout: fixed catalog section (one row per entry), fixed "Custom models" header, scrollable list of any `ggml-*.bin` files in the writable folder that aren't in the catalog, fixed bottom with a custom-URL text field + Download button, **Reveal Models Folder**, and **Close**. Each row has a status slot (colored dot + colored label), a **Use / Active** button (sets `Preferences.localModelFilename`; the current model shows "Active" disabled), and an action button (Download / Delete / — for bundled / Cancel while downloading). The progress bar overlays the status slot so nothing shifts horizontally during a download.
- **Hardware tiering** — `HardwareTier` (very-low / low / mid / high) classified from `sysctl hw.optional.avx2_0`, `hw.optional.fma`, and `activeProcessorCount`. `ModelRecommendation.rate(minTier:host:)` returns `.recommended` / `.slow` / `.notRecommended` with matching `systemGreen` / `systemOrange` / `systemRed` color. Each catalog entry declares the minimum tier it's useful on (tiny/base = very-low, small = low, medium = mid, large-v3-turbo = high). Ratings apply to bundled rows too; the disabled "—" action button is the only "bundled" signal in the row.
- **First-launch auto-pick** — `Preferences.didAutoSelectModel` guards a one-time call in `AppDelegate.applicationDidFinishLaunching` that picks the highest-tier catalog entry which is both present on disk (bundled or downloaded) and rated `.recommended` for the host. Only fires once; after that the user's selection is authoritative. Backed up alongside the rest of the UserDefaults so a restore doesn't re-trigger it.
- **Model-picker coloring** — the Local model popup in Preferences → Transcription colors each `ggml-*.bin` entry's title to match the Manage Models recommendation (green / orange / red for catalog entries, default label color for custom). Applied by setting `attributedTitle` on each `NSMenuItem` (setting it on `NSPopUpButtonCell` doesn't take — the cell draws from the menu item on macOS 10.13).
- **Models-folder resolution rewrite** — bundled models are always discovered; `Preferences.modelsDirectory` (if set) only redirects the *writable* half, where downloads land and extras are read from. `Preferences.writableModelsDirectory` is `modelsDirectory` when set, otherwise `~/Library/Application Support/push-to-dictate/models/`. Picker scans *bundle ∪ writable* on every dropdown open. `whisperModelPath` resolves bundle first, then writable. Default `Preferences.localModelFilename` is `ggml-base.en-q8_0.bin` to match the new default bundled set. The **Clear** button on the Models folder field was renamed **Default** and resets the field to the writable default path.
- **About dialog** — menu-bar menu grew an **About push-to-dictate** item that shows a centered `NSWindowController` with the 128 × 128 app icon (loaded via `NSApp.applicationIconImage`), app name (bold 20 pt), version pulled from `CFBundleShortVersionString`, author line "by Paradoxical Quad", a brief non-technical description, a short credits line for Whisper (OpenAI) and whisper.cpp (CPU adaptation), and the copyright. `Info.plist` version bumped to `1.0`; `NSHumanReadableCopyright` set to "© 2026 Paradoxical Quad".

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

### 2026-11-12 — Phase 5 plan (pre-execution)

Plan of record agreed before any build/download work starts. Captures all decisions that shaped the approach so the choices aren't re-derived later.

#### Goal

Produce a working `whisper-cli` binary and a Whisper model file on this machine, place both inside the `push-to-dictate.app` bundle so the shipped app is fully self-contained, and lay down a repeatable setup path for future fresh clones.

#### Hardware constraint driving the build flags

Target machine CPU is Intel Xeon X5650 (Westmere-EP). Instruction sets present: SSE4.2, AES-NI. Instruction sets **absent**: AVX, AVX2, FMA, F16C. Default whisper.cpp builds assume AVX and die with `illegal instruction` on this hardware. Mandatory CMake flags for the build:

```
-DGGML_METAL=OFF
-DGGML_AVX=OFF
-DGGML_AVX2=OFF
-DGGML_FMA=OFF
-DGGML_F16C=OFF
-DGGML_NATIVE=ON
-DCMAKE_BUILD_TYPE=Release
```

`GGML_NATIVE=ON` lets the build pick up SSE4.2 that the Xeon *does* have.

#### Source layout — three locations, each with a specific reason

1. **Upstream whisper.cpp clone** (outside this repo, in the local workspace): standalone clone of the whisper.cpp repository. Not tied to push-to-dictate. Reusable across any future project that needs whisper.cpp.
2. **`vendor/whisper.cpp/`** (project-relative): project-local copy of the source, created by `rsync` from (1) with the upstream `.git` directory kept intact. This is what we actually build against for push-to-dictate. Pinned at whatever commit we rsynced; independent of upstream updates to (1).
3. **`vendor/models/ggml-small.en.bin`** (project-relative): the model file. ~465 MB. Lives inside the project's `vendor/` tree because it's an external artifact bound to this specific project build.

#### Model acquisition — source URL

**Right now (first-time setup):** downloaded directly from Hugging Face.

```
https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-small.en.bin
```

URL parts: `huggingface.co` → account `ggerganov` (whisper.cpp author) → repository `whisper.cpp` → raw file fetch from the `main` branch → file `ggml-small.en.bin`.

Fetch command:

```
curl -L -o vendor/models/ggml-small.en.bin \
  https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-small.en.bin
```

`-L` follows HTTP redirects (Hugging Face uses a CDN). SHA256 of the downloaded file is captured at download time and used by the setup script for integrity verification on future runs.

**Future (after GitHub preservation is set up):** downloaded from the user's own GitHub Release asset, at a URL of the form:

```
https://github.com/P-DoxQuad/push-to-dictate/releases/download/assets-v1/ggml-small.en.bin
```

Setup script will prefer this URL and fall back to Hugging Face if the Release is unreachable.

#### Version-control decision — `.gitignore` the vendor tree

`vendor/` (and therefore everything under it — whisper.cpp source and models) is added to `.gitignore`. Rationale:

- The 465 MB model exceeds GitHub's 100 MB single-file push limit. Regular git commits can't carry it.
- Git LFS would work but has a 1 GB/month bandwidth cap on the free tier that gets blown by a handful of fresh clones of a 465 MB file.
- GitHub Release assets have **no bandwidth limit** and allow 2 GB per file. That's where the model actually lives for distribution.
- The setup script repopulates `vendor/` on any fresh clone, keeping the repo itself small and the preservation story intact without quota concerns.

Scripts that know how to rebuild the artifacts are more valuable in the repo than the artifacts themselves.

#### Preservation strategy — no third-party criticism path

The project's offline-first promise extends to the toolchain itself: nothing in the critical path should depend on Hugging Face, OpenAI, or ggerganov remaining up.

- **Model**: uploaded to a GitHub Release owned by the user (`P-DoxQuad/push-to-dictate`, tag `assets-v1`). User's copy, free hosting, unlimited download bandwidth.
- **whisper.cpp source**: user forks `ggerganov/whisper.cpp` to their own GitHub account. Setup script clones from the fork at a pinned commit SHA. If upstream disappears, the fork remains.
- **Build recipe (CMake flags, pinned commit, SHA256, filenames)**: committed to `scripts/setup.sh` in this repo. Always reproducible.
- **Finished `.app`**: shipped as a Release asset itself. End users download one file containing binary + model + licenses.

The fork and the Release upload are user-side GitHub actions deferred until after Phase 5 code work is done. Setup script defaults point at upstream Hugging Face / `ggerganov` for now; two config variables change to the user's URLs when the preservation infrastructure is created.

#### Setup script — `scripts/setup.sh`

Committed to the repo. Idempotent (re-running skips completed steps). Config variables at the top:

```
WHISPER_REPO     # default upstream; flip to user fork later
WHISPER_COMMIT   # pinned SHA for reproducibility
MODEL_URL        # default Hugging Face; flip to user Release asset later
MODEL_SHA256     # integrity check on model download
```

Workflow: clone whisper.cpp at pinned SHA into `vendor/whisper.cpp/` if missing → `cmake` configure with the no-AVX flags → `cmake --build build -j 6` → download model to `vendor/models/` if missing → verify SHA256.

#### Bundling — Xcode Copy Files build phase

Adds one new build phase to the `push-to-dictate` target in the Xcode project:

- Destination: Resources (resolves to `push-to-dictate.app/Contents/Resources/` at build time)
- Files to copy on every build:
  - `vendor/whisper.cpp/build/bin/whisper-cli`
  - `vendor/models/ggml-small.en.bin`
  - `Licenses/` directory (see Attribution below)

End-user `.app` becomes self-contained from first launch. No downloads, no setup, no missing-model dialog.

#### Runtime path resolution — bundle-first with override

`Preferences.whisperCliPath` and `Preferences.whisperModelPath` will check, in order:

1. User-set preference value (non-empty string) — honoured as-is.
2. `Bundle.main.url(forResource: "whisper-cli", withExtension: nil)?.path` (or equivalent for the model) — the bundled copy inside `push-to-dictate.app/Contents/Resources/`.
3. `~/Library/Application Support/push-to-dictate/bin/whisper-cli` (or `.../models/<filename>`) — the sidecar fallback.

End users hit (2). Developers running out of Xcode without the Copy Files phase populated hit (3). Power users override via (1).

#### Attribution

- **Repo root** `THIRD_PARTY_NOTICES.md` — lists whisper.cpp and the Whisper model, carries the MIT license text and copyright for each. Committed.
- **App bundle** `Contents/Resources/Licenses/` — a directory containing `whisper.cpp-LICENSE.txt` and `whisper-model-LICENSE.txt`. Included via the Copy Files build phase.
- **About / Credits UI** — deferred to Phase 7 (the preferences/UI phase).

#### Phase 5 execution sequence (what gets done now)

1. `git clone https://github.com/ggerganov/whisper.cpp Sandbox/whisper.cpp`. ~30 s.
2. `rsync -a Sandbox/whisper.cpp/ push-to-dictate/vendor/whisper.cpp/`. Few seconds.
3. Add `vendor/` to `push-to-dictate/.gitignore`.
4. Create `push-to-dictate/vendor/whisper.cpp/build/` and run CMake configure with the flags listed above, then `cmake --build build -j 6`. **3–5 minutes**.
5. Smoke test: run `vendor/whisper.cpp/build/bin/whisper-cli --help`.
6. Create `push-to-dictate/vendor/models/` and `curl` the model from Hugging Face. **1–5 minutes** depending on bandwidth.
7. Record the SHA256 of the downloaded model.
8. Write `push-to-dictate/scripts/setup.sh` with the recipe above.
9. Update `Preferences.swift` to implement the three-tier path resolution.
10. Write `THIRD_PARTY_NOTICES.md` + add `Licenses/` folder with MIT texts.
11. (User action in Xcode) Add Copy Files build phase that bundles `whisper-cli`, `ggml-small.en.bin`, and `Licenses/` into `Contents/Resources/`.
12. Verify end-to-end: hotkey → speak → release → Console logs a real transcript (not "whisper-cli not found").
13. DEVLOG close-out entry + commit under one proposed message, pending approval.

#### Deferred (not Phase 5)

- Creation of the user's fork of `ggerganov/whisper.cpp` on GitHub.
- Creation of the GitHub Release `assets-v1` and model upload.
- Flipping `WHISPER_REPO` and `MODEL_URL` in `scripts/setup.sh` to the user's URLs.
- Larger-model selection UI (medium.en / large-v3) — Phase 7 (preferences window).
- First-run "model missing" UX — unnecessary with bundled small.en; revisit if/when the user adds larger-model downloads in Phase 7.
- About / Credits dialog — Phase 7.
- Replacing the whisper-cli shell-out with direct `libwhisper` linkage via a Swift ↔ C bridging header — Phase 5 later-milestone, after the shell-out path is verified working.

### 2026-11-12 — Phase 5 closed (local transcription verified)

- whisper.cpp **pinned to v1.7.2** (not latest). Reason: on 2024-12-08, upstream introduced `#include <filesystem>` in `ggml/src/ggml-backend-reg.cpp`; Xcode 10.1's bundled libc++ has no `<filesystem>` header (that's a C++17 implementation requiring macOS 10.15 SDK). v1.8.3 is the first tag to contain this dependency; v1.7.2 is the latest tag that still builds against High Sierra's libc++. Cost: ~12 months of upstream changes we're not getting. For CPU small.en inference the path hasn't materially changed in that window, so the practical impact is small.
- Build flags for Mac Pro 5,1 Westmere Xeons (no AVX/AVX2/FMA/F16C): `-DGGML_METAL=OFF -DGGML_AVX=OFF -DGGML_AVX2=OFF -DGGML_FMA=OFF -DGGML_F16C=OFF -DGGML_NATIVE=ON -DCMAKE_BUILD_TYPE=Release`. Accelerate framework auto-detected and linked for BLAS.
- v1.7.2 builds the CLI binary as `main`, not `whisper-cli` (the rename landed later upstream). `scripts/setup.sh` copies `main` → `whisper-cli` after build so the app's path resolution is naming-stable regardless of upstream version.
- Downloaded `ggml-small.en.bin` from `https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-small.en.bin`. SHA256 captured: `c6138d6d58ecc8322097e0f987c32f1be8bb0a18532a3f88f734d1bbf9c41e5d`. Setup script verifies on every re-run.
- `scripts/setup.sh` (committed) is idempotent: clones at pinned tag → CMake configure with the no-AVX flags → build → rename to `whisper-cli` → download model → verify SHA256. Runs through MacPorts `cmake` at `/opt/local/bin/cmake` via a PATH fallback.
- `vendor/` added to `.gitignore`. Model + source tree repopulate via `scripts/setup.sh`.
- `Preferences.whisperCliPath` / `whisperModelPath` resolution is now three-tier: user preference → `Bundle.main` resource → `~/Library/Application Support/push-to-dictate/.../` fallback. End-user builds hit the bundle; dev builds can hit either depending on whether Copy Files has run.
- Xcode **Copy Files** build phase added to the `push-to-dictate` target (destination Resources). Bundles `vendor/whisper.cpp/build/bin/whisper-cli`, `vendor/models/ggml-small.en.bin`, and the `Licenses/` folder (as a blue folder reference) into `push-to-dictate.app/Contents/Resources/` on every build.
- Attribution: `Licenses/whisper.cpp-LICENSE.txt`, `Licenses/whisper-model-LICENSE.txt`, and top-level `THIRD_PARTY_NOTICES.md` added. MIT text + copyrights for whisper.cpp (The ggml authors) and Whisper (OpenAI).
- Cleaned up three `withUnsafeBufferPointer` unused-result warnings in `AudioRecorder`, `WhisperCppTranscriber`, `OpenAITranscriber` — closure returned `memcpy`'s pointer, now explicitly discarded with `_ =`.
- Verified end-to-end: ⌃⌥Space → speak → ⌃⌥Space → Console logs real transcript from the local whisper backend. First transcription also warm-starts the model in memory.
- **Performance baseline on the X5650 without AVX**: roughly 15× slower than realtime for the `small.en` model. Example from a 1.4 s clip: 21.3 s of total processing (833 ms load, 15.3 s encode, dominated by matmul). Usable for short dictation; impractical for anything beyond a sentence or two until Phase 8 looks at quantized models or Accelerate BLAS tuning.
- Phase 5 later-milestone (replace shell-out with direct `libwhisper` linkage via bridging header) deferred — current path is working and the subprocess overhead is dwarfed by the inference cost on this hardware.
- Still pending (user-side, not blocking): fork `ggerganov/whisper.cpp` to own GitHub, create `assets-v1` Release on `P-DoxQuad/push-to-dictate`, upload `ggml-small.en.bin` there, flip `WHISPER_REPO` / `MODEL_URL` defaults in `scripts/setup.sh` to point at those.

### 2026-11-12 — Phase 6 closed

- `TextInjector` fully implemented. Reads `Preferences.injectionMethod` at call time, dispatches work to a private serial `DispatchQueue` so neither path blocks main.
- **Paste path**: snapshots `NSPasteboard.general` contents (per-item, per-type, deep-copied into fresh `NSPasteboardItem`s), writes the transcript as `.string`, posts a synthetic `⌘V` (virtual key 9 + `.maskCommand`) via `CGEvent.post(tap: .cghidEventTap)`, then restores the snapshot after a fixed 200 ms delay. Delay is a heuristic (too short → restore clobbers the paste; too long → user sees a visible clipboard gap).
- **Typed path**: iterates `text.unicodeScalars`, posting one keyDown/keyUp pair per scalar via `CGEvent.keyboardSetUnicodeString`. No inter-character pacing — relies on the target app accepting events at full speed. Measured: near-instant for short dictation phrases, visibly types out multi-sentence output.
- **Menu**: new "Injection" submenu (Paste / Typed) with checkmark follows `Preferences.injectionMethod`. Same pattern as the Mode submenu. Default stays `paste`.
- `StatusItemController.transcribe` success path now routes the transcript to `textInjector.insert(text)` on the main queue (TextInjector itself hops to its own work queue).
- Verified in TextEdit: both strategies inject the transcript correctly. Paste path restored the clipboard contents correctly after the operation.
- Deferred to Phase 8 polish:
  - Per-app override list ("force typed in these bundle IDs") — autocomplete-heavy apps vs paste-hostile apps.
  - `changeCount`-based pasteboard restore instead of the fixed 200 ms heuristic.
  - Transcription speed tuning (quantized model, greedy decoding, thread count, libwhisper direct linkage) — captured as options in-session, not actioned yet. Current ~15× realtime on X5650 without AVX dominates the user-perceived latency; the injection itself is noise.

### 2026-11-12 — Phase 7 closed

- `PreferencesWindowController` (new file, programmatic AppKit UI via `NSGridView`, no XIB). Singleton, window is not released on close, re-shows with `center()` + `makeKeyAndOrderFront`.
- Six rows laid out in a grid:
  1. **Hotkey** — click-to-record button. `NSEvent.addLocalMonitorForEvents` captures `.keyDown` / `.flagsChanged` while recording; writes `Preferences.hotkeyKeyCode` + `hotkeyModifierFlags` and fires `onHotkeyChanged` so `StatusItemController` re-applies to `HotkeyMonitor` live. ESC cancels.
  2. **Backend** — `NSPopUpButton` with whisper.cpp (local) / OpenAI API, writes `Preferences.backend`.
  3. **Local model** — `NSPopUpButton` populated by scanning `Bundle.main` Resources and `~/Library/Application Support/push-to-dictate/models/` for `ggml-*.bin`. Hidden when backend is OpenAI.
  4. **OpenAI API key** — `NSSecureTextField`. Hidden when backend is whisper.cpp. Writes `Preferences.openAIAPIKey` on every keystroke via `controlTextDidChange`.
  5. **Text insertion** — two `.radio`-type `NSButton`s (Paste / Typed) in a horizontal `NSStackView`. Replaces the earlier menu-bar submenu and the earlier `NSPopUpButton` sketch. Writes `Preferences.injectionMethod`.
  6. **Input device** — `NSPopUpButton` with "System default" plus every CoreAudio device that has input streams. Writes `Preferences.inputDeviceUID`.
- Hotkey validation rule: standalone keys are rejected unless they are F1–F20 (keycodes 96–122 + 64/79/80/90/105/106/107/113). Everything else requires at least one of ⌃ ⌥ ⇧ ⌘.
- Hotkey recorder also listens for `.systemDefined` events (NSLogs subtype/data1/data2 to Console) as a diagnostic path for Pause/Break and PC-only keys that macOS routes through the HID system-event channel rather than keyDown. Not consumed, not saved — just a log breadcrumb for future decoding if needed.
- Menu-bar **Mode** submenu stays (quick flip during dictation). **Injection** submenu removed — that preference moved to the Preferences window. **Preferences…** item now actually opens the window.
- `Preferences.openAIAPIKey` migrated from `UserDefaults` to Keychain (`kSecClassGenericPassword`, service `push-to-dictate`, account `openai-api-key`). Transparent one-shot migration on first read: if the Keychain is empty but a legacy UserDefaults value exists, it's written to Keychain and removed from UserDefaults. Keychain helpers are private statics on `Preferences` (no new file).
- `Preferences.inputDeviceUID` added — stores the selected CoreAudio device UID (empty string = system default).
- `AudioRecorder.start()` now calls `applyPreferredInputDevice()` before installing the tap. Translates the stored UID → `AudioDeviceID` via `AudioObjectGetPropertyData(kAudioHardwarePropertyDevices)` and sets `kAudioOutputUnitProperty_CurrentDevice` on `engine.inputNode.audioUnit`. Enumeration helpers (`availableInputDevices()`, `audioDeviceID(forUID:)`) are static on `AudioRecorder` — folded in rather than a new file to avoid another Xcode add step.
- Deferred: backend-switch re-applies the transcriber choice at the next transcription (not live-updating any state the controller holds; works because `makeTranscriber()` reads `Preferences.backend` each time). About / Credits dialog deferred to Phase 8.

### 2026-11-12 / 2026-11-13 — Phase 8 polish, first pass

#### Sounds
- `Preferences.startSound` / `stopSound` added. Default `Tink` / `Pop`. Special value `"None"` (`Preferences.noSoundName`) means silent.
- Preferences window lists sounds found in `/System/Library/Sounds/` and `~/Library/Sounds/` (common macOS convention paths), showing `.aiff` / `.caf` / `.wav`. Changing a popup plays the selected sound as a preview.
- `StatusItemController.setRecording` calls `NSSound(named:).play()` for the configured start/stop sounds. `playSound("None")` is a no-op.

#### Launch at login
- Checkbox in Preferences writes a `~/Library/LaunchAgents/<bundle-id>.plist` (`Label`, `ProgramArguments = [Bundle.main.executablePath]`, `RunAtLoad = true`). Unchecking removes the plist. Takes effect at the next user login.
- Uses `~/Library/LaunchAgents/` rather than `SMLoginItemSetEnabled` because the latter requires a signed helper app bundled inside `Contents/Library/LoginItems/` — unavailable under Sign-to-Run-Locally. Plist approach needs no signing.
- Caveat captured for later: the plist records whatever binary path is currently running, so dev builds under `~/Library/Developer/Xcode/DerivedData/...` won't survive a clean. Only a shipped `.app` at a stable location makes a durable login item.

#### Error surfaces
- `showError(title:detail:)` helper in `StatusItemController`: logs via `Logger.error` + delivers an `NSUserNotification`.
- Pre-flight check `preflightBackend()` runs *before* starting audio capture:
  - whisper.cpp backend: checks that `Preferences.whisperCliPath` is executable and `Preferences.whisperModelPath` exists.
  - OpenAI backend: checks that `Preferences.openAIAPIKey` is non-empty.
  - Returns a human-readable issue string on failure; `setRecording(true)` aborts before `audioRecorder.start()` so a known-bad state never wastes a recording.
- Runtime failures (mic start throws, transcription failure from either backend including URLSession errors) also route through `showError`.
- `NSUserNotificationCenterDelegate.shouldPresent` returns `true` so banners appear even when the app is frontmost. `didActivate` clears the error-state icon tint early when the user clicks the banner.

#### Bundle-only model architecture
- Removed the `~/Library/Application Support/push-to-dictate/bin/` and `models/` fallback tiers from `Preferences.whisperCliPath` and `whisperModelPath`. Models and the whisper-cli binary are bundle-only. The orphan sidecar install from Phase 5 was deleted manually.
- Added `Preferences.modelsDirectory` (string, empty = use bundle). Lets the user point at an external folder.
- `Preferences.whisperModelPath` resolution: user override > `modelsDirectory`-joined path > `Bundle.main` lookup.
- `PreferencesWindowController.discoverModels()` scans a single location — `modelsDirectory` if non-empty, else `Bundle.main.resourceURL`.
- UI: new **Models folder** row (hidden when backend is OpenAI, same visibility rule as **Local model**) with a text field, **Choose…** button opening `NSOpenPanel` for a directory, and **Clear** button. Empty-state placeholder shows `Bundle.main.resourcePath` so the user sees where the default models actually live.
- `~/Library/Application Support/push-to-dictate/` is now only used for `debug/` WAVs and `logs/`. Preferences stay in `~/Library/Preferences/` (UserDefaults, cfprefsd-managed). API key stays in Keychain.

#### Logger
- New `Core/Logger.swift`. Two levels: `error` (always written to file) and `info` (written to file only when `Preferences.logEverything` is true).
- Writes to `~/Library/Application Support/push-to-dictate/logs/push-to-dictate.log`. One-line-per-event append format: `yyyy-MM-dd HH:mm:ss  LEVEL  message`. Append I/O serialized on a dedicated `DispatchQueue`.
- All existing `NSLog("push-to-dictate: …")` call sites rewritten to `Logger.info(...)` / `Logger.error(...)`; `NSLog` is now only invoked from inside `Logger` itself.
- New `Preferences.logEverything` + **Logging: ☐ Log everything (unchecked, errors only)** checkbox in Preferences.

#### App icon and menu bar icons
- `.icns` generated from `icons/Push_to_Dictate_Colour_Icon_1024.png` (downsampled from the user-supplied 1254×1254 to 1024×1024 by `sips`, then a full iconset at 16/32/128/256/512 × @1x and @2x, assembled with `iconutil`).
- Bundled as `push-to-dictate.icns` via the Xcode Copy Files build phase; `Info.plist` gets `CFBundleIconFile = push-to-dictate`. Notification banners, Finder preview, and Cmd-Tab preview now use it.
- Menu bar icon is image-based. Unicode glyphs (`○` / `●`) removed.
- Three 44×44 PNGs bundled: `Push_to_Dictate_Black_Menu_Bar_44`, `_White_Menu_Bar_44`, `_Color_Menu_Bar_44`. Status item renders at 24×24.
- `Preferences.useColoredMenuBarIcon` picks between colored and auto-mono.
- Auto-mono picks black or white based on `isDarkMenuBar()`:
  - macOS 10.14+: `NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua`
  - macOS 10.13: reads `AppleInterfaceStyle` from the global `UserDefaults` domain (`"Dark"` when "Use dark menu bar and Dock" is checked in System Preferences → General).
- Live update: KVO on `NSApp.effectiveAppearance` (10.14+) and `DistributedNotificationCenter` observer for `AppleInterfaceThemeChangedNotification` (both OS versions). Icon flips immediately when the system setting changes.

#### Icon state indicators
- Replaced the earlier red-tint-on-recording approach with a state enum and corner-dot animation.
- `IconState`: `.idle`, `.recording`, `.processing`, `.error`.
- `.recording`: green dot (`NSColor.systemGreen`) in the bottom-right corner, blinking on/off every 0.5 s.
- `.processing`: sky-blue dot (`NSColor(srgbRed: 0.1, green: 0.72, blue: 1.0, alpha: 1.0)`), same blink rate.
- `.error`: the full icon is tinted red via `sourceIn` composite over the base image. Auto-clears after 5 s (matches default macOS banner duration) or immediately when the user clicks the delivered notification.
- State ownership: `setRecording(true)` sets `.recording`; `transcribe()` sets `.processing` on entry and either `.idle` on success or `.error` via `showError` on failure. `setRecording(false)` deliberately does *not* overwrite — it hands off to `transcribe()`.

#### Preferences UI housekeeping
- Checkbox labels reworded from `(otherwise …)` to `(unchecked, …)` — more direct.
- Window grew to accommodate new rows (hotkey, backend, local model, models folder, API key, text insertion, input device, start sound, stop sound, startup, logging, appearance = 12 rows). Hidden rows (`local model` + `models folder` when OpenAI selected, `API key` when whisper.cpp selected) use `grid.row(at:).isHidden = …` to reflow the layout.

#### Deferred (still Phase 8 scope)
- Silent-recording detection — user flagged that recording silence currently still runs the transcriber, which emits placeholder text like `"[blank_audio]"` into the focused field.
- "Move to /Applications" prompt on first launch from a quarantined location.
- Per-app override for injection method (paste vs typed) to work around autocomplete-heavy apps.
- Transcription speed tuning (quantized model, greedy decoding, thread count tweaks, direct `libwhisper` linkage).

### 2026-11-13 — Phase 8 polish, second pass

- **Silent-recording detection** landed. `AudioRecorder` tracks peak RMS across the capture; `StatusItemController.setRecording(false)` short-circuits transcription when peak < 0.01. Icon returns straight to `.idle`; no notification, no injection, no `[blank_audio]` placeholder leaking into the focused field. Threshold is hardcoded for now; if real speech gets filtered we'd expose it as a preference.
- **Move-to-Applications prompt** landed. `AppDelegate.applicationDidFinishLaunching` checks `Bundle.main.bundleURL`, skips if under `/Applications/`, `~/Applications/`, or a DerivedData / Developer-Xcode path. Three-button `NSAlert` — Move, Not Now, Don't Ask Again. Move uses `FileManager.moveItem` + a detached `/bin/sh` relaunch script. Dev builds are exempt so Xcode run cycles aren't interrupted.
- **Backup Export / Import** landed in Preferences. Plist format with `version`, `userDefaults`, `openAIAPIKey` (pulled from Keychain, written back on import), `launchAtLogin` (reflecting LaunchAgents plist presence). `Preferences.allUserDefaultsKeys` exposes the canonical key list for round-trips.
- **Radio-button toggle bug fix.** Paste / Typed radios share an `NSStackView` but have distinct actions, so AppKit's auto-grouping didn't kick in — both could appear selected. Each action now calls `refreshInjectionPopup()` to sync both button states from `Preferences.injectionMethod`.
- **Models folder field display rework.** Field is now always populated: user's `modelsDirectory` if set, else `Bundle.main.resourcePath`. Scrolls natively when the path is long. `controlTextDidChange` treats "text equals bundle resources path" as "no override" (saves `""` to Preferences) so moving the app later doesn't leave a stale absolute path baked in. Clear button resets the field to the bundle path.
- **Preferences window split-view refactor.** Replaced the 13-row single-grid dump with a split view: left `NSTableView` sidebar (source-list style) listing six categories, right content container swapping in the selected category's `NSGridView`. Window is resizable (minimum 640 × 340), sidebar fixed at 170 pt. Conditional row visibility (local model + models folder hidden for OpenAI backend; API key hidden for whisper.cpp backend) scoped to the Transcription grid.
- **Category grouping iteration.** Initial split: General/Transcription/Audio/Output/Interface/Advanced. Backend moved from General to Transcription (sits with the model/API-key rows it affects). Backup Export/Import moved from Advanced to General (user-facing operation, not an advanced one). Advanced now contains just Logging.
- **Preference label cleanup carried over** from the first polish pass: `(otherwise …)` → `(unchecked, …)` on log-everything and colored-icon checkboxes.

### 2026-11-13 — Transcription speed tuning

Chasing the "it's too slow" problem on the X5650 through three independent levers: quantization, thread count, and decoding strategy.

#### Quantization benchmark

Three variants of `small.en` on two clips (`whisper.cpp/samples/jfk.wav` and a ~43 s real debug recording), same flags, `-t 4`:

| Model | Size | JFK (11 s) | Real (43 s) |
|---|---|---|---|
| `small.en` (f16) | 465 MB | 28.1 s | 60.7 s |
| `small.en-q8_0` | 252 MB | 19.6 s (–30%) | 40.7 s (–33%) |
| `small.en-q5_1` | 181 MB | 21.4 s (–24%) | 45.9 s (–24%) |

Transcripts were byte-identical across all three — quantization did not cost measurable accuracy on these samples. q8_0 beat q5_1 on this CPU: q5_1's packed 5-bit format doesn't vectorize as well under SSE4.2-only as q8_0's cleaner byte-aligned blocks. Encode time was essentially constant (~14.7 s) across models — it's bound by audio length and encoder architecture, not weight precision. All speed gains came from the decode / batched-decode phase, where quantized weights reduce memory traffic per matmul step.

Also downloaded `tiny.en`, `base.en`, plus q8_0 and q5_1 for both, giving the full matrix in `vendor/models/` (9 files). User testing then landed on accuracy bands roughly: `small.en` ~95–98%, `base.en` ~90%, `tiny.en` ~75–80%; q8_0 of each sits at the same accuracy as its parent.

#### Thread count

Hardcoded default moved 4 → 6. On the X5650 (dual Xeon, 12 physical / 24 logical) this was a perceptibly big felt-speed improvement — bigger than quantization. Then exposed as `Preferences.transcriptionThreads` (stepper + text field, 1–24) under **Advanced**. Dual-socket NUMA is unmodeled by whisper.cpp, so cross-socket threads hit remote memory over QPI; gains from going past physical-core-of-one-socket are likely to be small or negative, but the preference lets the user explore.

#### Greedy decoding

`-bs 1 -bo 1` appended to the `whisper-cli` invocation — beam size 1, best-of 1, skipping beam search and candidate reranking. Exposed as `Preferences.greedyDecoding` (checkbox under **Advanced**, default **on**). Small accuracy hit on ambiguous audio; imperceptible on clear dictation.

Both prefs are read at transcribe time in `WhisperCppTranscriber.transcribe`, so toggling them takes effect on the next dictation without restart.

#### Model picker live rescan

`PreferencesWindowController` now conforms to `NSMenuDelegate` and refreshes the model popup in `menuNeedsUpdate(_:)`. Dropping new `ggml-*.bin` files into the models folder makes them appear on the next click, no window reopen.

#### Deferred (still Phase 8 scope)

- **Direct `libwhisper` linkage** via a Swift ↔ C bridging header. Would skip the subprocess spawn but, more importantly, would let us keep the model resident between dictations — current shell-out eats ~500 ms of load time per invocation. Biggest remaining non-architectural win.
- **Streaming / chunked transcription** — start transcribing in ~5 s windows while the user is still speaking. Perceived latency drops to near-zero. Needs VAD or fixed-window chunking and partial-update UX.
- **Auto-detect thread default** via `sysctl hw.physicalcpu` at first launch instead of the current hardcoded 6.
- **Bundling model variants** — currently only `ggml-small.en.bin` is in the Copy Files build phase. Need to decide whether to ship the full matrix (adds ~1.6 GB to the `.app`) or a curated subset (e.g. `base.en-q8_0` as the default plus `tiny.en-q8_0` and `small.en-q8_0` as alternates).
- **Per-app override for injection method** (paste vs typed).

### 2026-11-14 — Model management, debug toggles, decoding knob

Three threads of work landed in the same session.

#### Beam-size preference replaced the greedy-decoding checkbox

Yesterday's "Greedy decoding" checkbox was really a 1-vs-5 toggle on whisper-cli's `-bs`/`-bo`. Promoted to a full stepper (1–10, default 5). User-facing label is **Accuracy** (plain-English for what varying beam width actually trades off), hint reads `1 = greedy (fastest) · 5 = default · 10 = thorough (slowest)`. `Preferences.beamSize` (Int) replaces `Preferences.greedyDecoding`. `WhisperCppTranscriber` now always appends `-bs N -bo N` with the configured value; the old conditional is gone.

Threads field grew a hint too: `Max: <logical CPU count> · Recommended: ⅓–½ of max` (computed from `ProcessInfo.processInfo.activeProcessorCount`). Stepper max now equals logical CPU count instead of hardcoded 24.

#### Debug toggles under Advanced

- `Preferences.saveDebugRecordings` (default **off**) gates `AudioRecorder`'s WAV writer. Debug WAVs were never used for transcription — the transcriber writes its own temp file — so skipping them entirely was the clean fix. **Clear Debug Recordings…** button next to the checkbox empties the folder with a count-and-confirm alert.
- **Clear Log…** button next to the "Log everything" checkbox. `Logger` grew a `clear()` method (truncates on the serialized write queue) and exposed `logFileURL` so the UI can show the path.

#### Model management

Single biggest piece of the session. Three new files under `Prefs/`:

- `ModelCatalog.swift` — `CatalogModel` struct (`displayName`, `filename`, `sizeBytes`, `url: URL?`, `isBundled: Bool`) and a fixed four-entry `ModelCatalog.entries`: `tiny.en-q8_0` (bundled), `base.en-q8_0` (bundled), `small.en-q8_0`, `medium.en-q8_0`. `ModelLocator` resolves status (`.bundled` / `.downloaded(URL)` / `.available`) and lists "extra" downloaded filenames (anything in the writable folder that isn't in the catalog).
- `ModelDownloader.swift` — `URLSessionDownloadTask` wrapped in a class with `onProgress` and `onComplete` closures. `DownloadResult` is a local enum (Swift 4.2 predates stdlib `Result`). Verifies the `ggml` / `lmgg` magic header before moving the temp download to its destination.
- `ManageModelsWindowController.swift` — programmatic AppKit window shown via `beginSheet`. Layout: fixed "Available transcription models" header + four catalog rows + separator + fixed "Custom models" header + scrollable list (240 pt tall) of extras + separator + fixed custom-URL field + Download button + Reveal Models Folder / Close footer. `ModelRowView` is a horizontal stack of name / size / status / action-button. The status slot is a container holding both an `NSTextField` and an `NSProgressIndicator` pinned to the same frame, visibility toggled so the progress bar appears *in place of* the status label during a download — nothing shifts horizontally.

Button logic:
- Catalog entry with `isBundled = true` → status "Bundled", action disabled, regardless of filesystem.
- Catalog entry with `isBundled = false` and present in writable folder → status "Downloaded", action "Delete".
- Catalog entry not present → status "Not downloaded", action "Download".
- Custom (non-catalog) filename in writable folder → row rendered under the scrollable "Custom models" section, action "Delete".
- Any row during download → status slot becomes the progress bar, action becomes "Cancel".

Entry point: **Manage Models…** button next to the Local model popup in Preferences → Transcription. `onDidChange` closure refreshes the popup after any catalog change.

#### Models-folder resolution rewrite (behind the UI)

Previously `Preferences.modelsDirectory` was an override that *replaced* the bundle lookup. That was wrong for the model-management flow: the bundle is always present and should always be scanned, regardless of where downloads live. Fixed:

- `Preferences.writableModelsDirectory` static: returns the `modelsDirectory` override if set, else `~/Library/Application Support/push-to-dictate/models/` (`Preferences.userModelsDirectory`). This is where downloads go and where "extras" are read from.
- `whisperModelPath` resolves bundle first, then the writable location.
- `discoverModels()` always scans **bundle ∪ writable**, every dropdown open, even when the user has set an override. The bundle is never skipped — even if conceptually immutable, the picker should reflect the current filesystem so manually added or removed files inside the bundle still show up.
- Models-folder field default visual is now `Preferences.userModelsDirectory.path`, not `Bundle.main.resourcePath`. The **Clear** button next to it was renamed **Default** since that's what it actually does.
- Default `Preferences.localModelFilename` moved from `ggml-small.en.bin` to `ggml-base.en-q8_0.bin` to match the intended bundled set.

#### Pending user action in Xcode

- Add three new Swift files (`ModelCatalog.swift`, `ModelDownloader.swift`, `ManageModelsWindowController.swift`) to the `push-to-dictate` target under the `Prefs` group.
- Update the Copy Files build phase: remove `vendor/models/ggml-small.en.bin`, add `vendor/models/ggml-tiny.en-q8_0.bin` and `vendor/models/ggml-base.en-q8_0.bin`.

#### Deferred (still Phase 8 scope)

- **Direct `libwhisper` linkage** — unchanged from previous entry.
- **Streaming / chunked transcription** — unchanged.
- **Auto-detect thread default** — unchanged.
- **Per-app override for injection method.**
- **About / Credits dialog.**

### 2026-11-14 — About dialog, icon refresh, status-dot polish

- **About dialog** — menu-bar menu gained an "About push-to-dictate" item. New `App/AboutWindowController.swift` draws the 128 × 128 app icon from `NSApp.applicationIconImage`, the app name, version, "by Paradoxical Quad", a non-technical one-line description ("for conventional computers. Works offline."), credits for Whisper + whisper.cpp, and the copyright. Version in `Info.plist` moved from `0.1.0` to `1.0` to match; `NSHumanReadableCopyright` populated.
- **Icon refresh** — all four menu-bar/app icons replaced. New design is a pixel-art keycap with an open mouth and sound waves. Files: `Push_to_Dictate_Keycap_Color_1024.png` (regenerated into `push-to-dictate.icns` via `sips` + `iconutil` at the full iconset sizes), `Push_to_Dictate_Keycap_Color_44.png`, `Push_to_Dictate_Keycap_Black_44_v2.png`, `Push_to_Dictate_Keycap_White_44_v2.png`. `StatusItemController.currentMenuBarImage()` lookups updated. Old icon PNGs removed from disk and the Xcode Copy Files phase.
- **Status-dot colors and size** — recording dot changed from green to `.systemRed`; processing dot changed from the old sky blue to a richer `srgbRed: 0.05, green: 0.25, blue: 0.80`. Dot diameter bumped from 6 pt to 10 pt (≈42 % of the 24 pt menu-bar icon's edge, up from ≈25 %). The error state is unchanged — the whole icon still tints red for 5 s or until the notification is clicked. Red-dot (recording) vs red-icon-tint (error) remain visually distinct because one is a corner mark and the other is a full-icon color shift.

Version bump to `1.0` reflects the app being feature-complete for its intended use (dictation with local + cloud transcription, model management, hardware-aware recommendations, auto-pick, debug and backup prefs, About dialog). No `0.x` prerelease phase in practice — the app was built end-to-end in six days and is now usable daily.

#### Catalog grew by one

Added `large-v3-turbo-q8_0` (874 MB) to `ModelCatalog.entries`. The straight `large-q8_0` and `large-v3-q8_0` 404 on HuggingFace — turbo is the practical "biggest model you'd actually run on CPU" today. No `.en`-only variants exist for large; the model is multilingual.

#### Hardware tiering

`HardwareTier` enum (very-low / low / mid / high) classified from `sysctl hw.optional.avx2_0` + `hw.optional.fma` + `ProcessInfo.processInfo.activeProcessorCount`. AVX2+FMA + ≥8 cores → high; AVX2+FMA + <8 → mid; no AVX2 + ≥8 → low; else very-low. This X5650 lands at low (no AVX2, 24 logical cores).

`ModelRecommendation` has three states (`.recommended` / `.slow` / `.notRecommended`) with matching `systemGreen` / `systemOrange` / `systemRed`. `rate(minTier:host:)`:

- `host > minTier` → `.recommended`
- `host == minTier` → `.slow`
- `host < minTier` → `.notRecommended`

Catalog `minTier` assignments: tiny / base = very-low, small = low, medium = mid, large-v3-turbo = high. On this host that produces: tiny/base Recommended, small Slow, medium / large-turbo Not recommended — matches lived experience.

#### Row UI

Each `ModelRowView` grew two things: a small 8-point `DotView` (custom `NSView`, `NSBezierPath(ovalIn:).fill()`) that sits next to the status label, and a dedicated **Use / Active** button between the status slot and the Download/Delete action button. Row layout is now `[name | size | dot + status | Use | action]`. Button logic:

- **Use** enabled when the row is downloaded or bundled and not already the active model.
- **Active** disabled when `entry.filename == Preferences.shared.localModelFilename`.
- Hidden-but-space-preserved (title "Use", disabled) when the model isn't on disk — so columns never shift as rows change state.

Dot + colored label apply to every catalog entry, bundled or not. The disabled "—" on the action column is the only "this is bundled" signal.

Progress-bar overlay logic unchanged: during a download both the dot and the label hide, the progress bar takes their slot, nothing moves horizontally.

#### First-launch auto-pick

`Preferences.didAutoSelectModel` (Bool). `AppDelegate.applicationDidFinishLaunching` calls `maybeAutoSelectModel()` which, if the flag is false, runs `ModelCatalog.bestRecommendedPresent()` — picks the highest-`minTier` catalog entry that's both already present on disk (bundled or downloaded) and rated `.recommended`. Falls back to the first bundled entry if nothing qualifies. Sets the flag so future launches never auto-pick. Included in `allUserDefaultsKeys` so a backup restore carries over the "already auto-picked" state and doesn't clobber the user's choice.

#### Picker coloring

Preferences → Transcription Local model popup now colors every `ggml-*.bin` entry — both the dropdown list and the currently-selected display — to match the Manage Models recommendation dot (green/orange/red for catalog, `.labelColor` for custom). First attempt set `attributedTitle` on `NSPopUpButtonCell` which doesn't take on 10.13 — the cell draws from the selected `NSMenuItem`. Fixed by setting `attributedTitle` on each `NSMenuItem` directly. Applied in `refreshModelPopup` (after items are added and selection restored) and after `modelChanged`.

### 2026-11-14 — Welcome / hover popover

Menu-bar icon now has a bound `NSPopover` tooltip. Content: title "Push to Dictate" + body "Press <hotkey> to start dictation. Click the icon for more options." Hotkey string pulled dynamically from `Preferences` via the now-internal `PreferencesWindowController.describe(keyCode:flags:)`.

Two triggers:

- **First launch** — fires 1.2 s after `StatusItemController.init` (the delay lets the Accessibility and Move-to-Applications alerts resolve first). Auto-dismisses after 12 s. `Preferences.didShowWelcomeTooltip` flips to true so it never fires again on launch; included in `allUserDefaultsKeys` so a backup restore preserves the "already seen it" state.
- **Hover** — `NSTrackingArea` installed on the status item's button with a tiny `HoverTracker: NSResponder` as owner (forwards `mouseEntered` / `mouseExited` to closures on the controller). Mouse enters → 1.5 s show timer. Exits → 0.3 s hide timer (grace period absorbs flicker when the cursor briefly leaves and comes back). No auto-dismiss on hover; mouse-exit handles it.

Single popover instance reused for both paths. `showInfoPopover(autoDismissAfter:)` guards on `welcomePopover?.isShown` so overlapping triggers can't produce two popovers. `.transient` behavior so clicking anywhere outside dismisses, and clicking the icon itself opens the menu normally (menu takes focus, popover closes).

### 2026-11-14 — El Capitan + Nehalem target (`nehalem-el-capitan` branch)

Backwards-compat branch. Target OS floor dropped from 10.13 to 10.11 El Capitan; whisper.cpp built against Nehalem for binary portability. No functional changes to the app.

#### Build config

- `scripts/setup.sh`: `CMAKE_OSX_DEPLOYMENT_TARGET=10.11`, `GGML_NATIVE=OFF`, `-march=nehalem` for both C and C++. Produces a `whisper-cli` that runs unchanged on any Nehalem-or-newer CPU without AVX. Same SSE4.2 code path as the previous Westmere-native build, so no perf regression on the X5650.
- `App/Info.plist`: `LSMinimumSystemVersion` 10.13 → 10.11. Added `NSMicrophoneUsageDescription` for the TCC prompt on 10.14+.
- `push-to-dictate.xcodeproj/project.pbxproj`: `MACOSX_DEPLOYMENT_TARGET` 10.13 → 10.11 (both configs). Xcode embeds the Swift stdlib automatically.

#### Swift-side API swaps (10.12+/10.13+ → pre-10.12)

Every call that targeted a newer AppKit API was rewritten inline using the pre-10.12 equivalent. No shim layer, no helper file; the setup code sits directly in each stored-property initializer and each pane builder.

- `NSTextField(labelWithString:)`, `NSTextField(wrappingLabelWithString:)` → `NSTextField(frame: .zero)` + `isEditable = false` + `isBordered = false` + `drawsBackground = false` (+ wrap properties for wrapping).
- `NSButton(title:target:action:)`, `NSButton(checkboxWithTitle:...)`, `NSButton(radioButtonWithTitle:...)` → `NSButton(frame: .zero)` + `bezelStyle`/`setButtonType(.switch)`/`setButtonType(.radio)` + `.title`.
- `NSGridView` → plain `NSView` panes with manual Auto Layout; vertical stacking via explicit `topAnchor = previous.bottomAnchor + gap`.
- `NSStackView.setCustomSpacing(_:after:)` → explicit spacer `NSView`s with fixed `heightAnchor` constraints inserted as arranged subviews.
- `Timer.scheduledTimer(withTimeInterval:repeats:block:)` → `Timer.scheduledTimer(timeInterval:target:selector:userInfo:repeats:)` with `@objc` tick methods for each (`dotTick`, `errorClearTick`, `welcomeDismissTick`, `hoverShowTick`, `hoverHideTick`).
- `NSImage.Name(...)` → raw string literals.
- `NSSound.Name(...)` → raw string literals.
- `Process.executableURL` / `Process.run()` → `Process.launchPath` / `Process.launch()`.

#### Notification dual-path for 10.14+

`StatusItemController.showError` branches at runtime via `#available(macOS 10.14, *)`:

- 10.14 and newer: `UNUserNotificationCenter` with a one-shot `requestAuthorization(options:)` at startup. `UNUserNotificationCenterDelegate` conformance lives in a separate `@available(macOS 10.14, *) extension`, since the protocol itself is 10.14+.
- 10.11 through 10.13: `NSUserNotification` + `NSUserNotificationCenter` as before.

Same behavior either way (banner on error, early-dismiss on click). No conditional compilation (`#if`); pure `#available` runtime branching.

#### Preferences window rewritten from scratch

The existing `PreferencesWindowController.swift` was deleted and written again. Multiple iterations of patching `NSStackView` + `NSGridView`-style layout failed to produce the user-requested alignment. The new file uses the pattern that a minimal isolation-test window had proven to work:

- Each pane is a plain `NSView`.
- For each row: one `NSTextField` label (right-aligned text) with `widthAnchor` fixed to the pane's longest-label width, one control pinned `label.trailing + 8`, controls vertically chained via `topAnchor = previousControl.bottomAnchor + 12`.
- Per-pane dynamic label-column width via a static `widestLabelWidth(_:)` that measures each label with the system font. Means each pane's label column is sized to its own longest label and nothing wider — minimum whitespace per pane, controls still aligned in a column.
- The Transcription pane specifically needs conditional hiding (backend-dependent). That pane only is wrapped in an outer vertical `NSStackView` with the individual row views as arranged subviews, so `row.isHidden = true` collapses both the row and its spacing (the other five panes are plain `NSView` with manual constraint chains).

#### Label text trimmed

Several checkbox and button titles got shortened in this pass to stop them pushing adjacent controls off to the right:

- "Save debug recordings (unchecked, discard after transcription)" → "Save debug recordings"
- "Log everything (unchecked, errors only)" → "Log everything"
- "Clear Debug Recordings…" → "Clear Recordings…"
- Accuracy hint: "1 = greedy (fastest) · 5 = default · 10 = thorough (slowest)" → "1 = fastest · 5 = default · 10 = slowest"

#### CLAUDE.md additions

Two new persistent rules, since both patterns caused rework on this branch:

- No shim/wrapper helpers unless strictly necessary (API unavailable on target, or ≥3 duplicated call sites with real divergence risk). Inline setup otherwise.
- No em-dashes anywhere (UI strings, docs, commit messages, chat). Use colon, period, or regular hyphen.
- No human-developer time estimates ("an hour", "half a day", "a week") in any output. Time-to-type numbers calibrated for a human aren't useful. If sizing is needed: qualitative (small/medium/large) or concrete counts (files touched, lines changed).

#### README

Supported-platforms section updated: macOS 10.11 El Capitan through macOS 15 Sequoia. Intel x86_64 targeting Nehalem and newer. Microphone permission described as "prompted on 10.14+ via `NSMicrophoneUsageDescription`, not applicable on 10.11–10.13". Notifications documented as dual-path (`UNUserNotificationCenter` on 10.14+, `NSUserNotificationCenter` on 10.11–10.13).

#### Pending user action

- Delete the `LayoutTestWindow.swift` reference from the Xcode project (the file was removed on-disk mid-session after the isolation test was complete).
- Add `Core/NSTextField+Compat.swift` was created then deleted later in the session as the inline approach replaced it — reference should be removed from the project if still present.

If the El Capitan target holds up on test hardware, merge back to `main` as `1.1.0`.

### 2026-11-14 — In-app Help window and misc polish

Added a menu-bar Help item that opens a scrollable in-app reference. `App/HelpWindowController.swift` holds a non-editable `NSTextView` inside an `NSScrollView` with a Close button. Content is a manually-assembled `NSAttributedString` (no Markdown parsing: `NSAttributedString.init(markdown:)` is 12+ and unusable on this deployment target) built from bold headings + body paragraphs with `NSMutableParagraphStyle` for spacing. Sections, in order: Permissions, Starting and stopping dictation, Changing the hotkey, Audio input, Transcription models, Local or cloud, Text insertion, Launch at login, Backup and restore, Troubleshooting. Permissions is first because the hotkey won't work without Accessibility.

The current hotkey description is pulled live from `Preferences.shared` via `PreferencesWindowController.describe(keyCode:flags:)`, so the Help text reflects whatever binding is active.

Menu item: "Help" with `⌘?` key equivalent, placed above About.

Also in this pass:

- Em-dashes removed from every remaining Swift code comment (CLAUDE.md rule covers all output including comments; this swept the last stragglers in `AppDelegate`, `StatusItemController`, `ModelCatalog`, `PreferencesWindowController`, `ManageModelsWindowController`).
- Preferences → Advanced checkbox labels shortened: "Save debug recordings (unchecked, discard after transcription)" to "Save debug recordings"; "Log everything (unchecked, errors only)" to "Log everything". The parenthetical was pushing the adjacent Clear button too far right.
- Preferences → Advanced "Clear Debug Recordings…" button relabeled "Clear Recordings…" to free the same space.
- Preferences → Advanced Accuracy hint shortened from "1 = greedy (fastest) · 5 = default · 10 = thorough (slowest)" to "1 = fastest · 5 = default · 10 = slowest".
- Preferences → Transcription pane rewrapped in a vertical `NSStackView` of `buildRowView`-produced row containers so hiding `transcriptionModelRow`/`transcriptionModelsFolderRow`/`transcriptionApiKeyRow` when the backend switches to OpenAI collapses the row *and* its inter-row spacing. Previously the API-key row sat where the folder row had been, leaving a visible gap.
- `README.md` picked up a "Menu bar menu" section describing the status-item menu items, including the new Help entry.
- Welcome / hover popover body text updated to point users at Help: "Press <hotkey> to start dictation. Click the icon for Help and more options." The `<hotkey>` placeholder resolves to the user's current binding via `PreferencesWindowController.describe(...)`.

### 2026-11-15 — v1.1 development: auto-stop, injection pacing, transcriber deadlock, validation

#### Silence auto-stop (Toggle mode)

New feature. `AudioRecorder` exposes `autoStopThreshold: Float?`, `autoStopDuration: TimeInterval?`, and `onAutoStopTriggered: (() -> Void)?`. The input-tap callback tracks a `silentSince: Date?` while audio stays below threshold; when the gap reaches the configured duration, the triggered callback fires once (guarded by `autoStopFired`) on the main queue. `StatusItemController.configureAutoStop()` arms these properties only when `hotkeyMode == .toggle` AND the user preference is on, otherwise clears them. Trigger closure calls `setRecording(false)` so the normal stop-sound → transcribe → inject pipeline runs.

Three new preferences: `silenceAutoStopEnabled` (default true), `silenceAutoStopThreshold` (default 0.01 RMS), `silenceAutoStopSeconds` (default 4.0). All three included in `allUserDefaultsKeys` for backup/restore.

#### WhisperCppTranscriber pipe-buffer deadlock

Latent bug: `runWhisperCli` drained `stdoutPipe` and `stderrPipe` only after `waitUntilExit()`. For short audio, the combined output fit in the ~16-64 KB pipe buffer and the call returned fine. For long audio (benchmark paragraph tests), whisper-cli's verbose stderr progress output filled the pipe, blocked on write, and `waitUntilExit()` hung; eventually the process yielded a truncated stdout capture (only the first few tokens landed). Fix: install `readabilityHandler` closures on both pipes before `launch()` to drain concurrently with an `NSLock`-guarded `Data` accumulator. After `waitUntilExit()`, nil out the handlers and read any residual `availableData` to flush. Error-path stderr snippet behavior preserved.

#### TextInjector keystroke pacing

For the `.typed` injection method (CGEvent-based per-character injection), long strings overflowed the HID event dispatch backlog and characters were silently dropped. The transcription log showed the full text but only a fraction of characters landed in the focused app. Added a configurable per-character delay via `usleep`, defaulting to 5 ms (200 chars/sec). New preference `typedKeystrokeDelayMs` (floor 5, ceiling 100), surfaced in Preferences → Output.

#### Numeric field validation (five fields across three panes)

Replaced silent clamping with explicit error indication. Five bounded numeric fields now:

- `transcriptionThreads`: 1 to `ProcessInfo.processInfo.activeProcessorCount`
- `beamSize`: 1 to 10
- `typedKeystrokeDelayMs`: 5 to 100
- `silenceAutoStopThreshold`: ≥ 0.01, no ceiling
- `silenceAutoStopSeconds`: ≥ 1.2, no ceiling

Behavior: on each keystroke, `validateNumericField` parses the typed value. In range, stepper and preference update and the field+label stay default color. Out of range, field text and row label switch to `NSColor.systemRed` and the preference is not written. On field commit (focus loss), `controlTextDidEndEditing` plays `NSSound.beep()` and reverts the field to the last persisted preference value if still invalid.

Required capturing the row labels during layout. New `placeRowWithLabel` helper returns `(bottom: NSLayoutYAxisAnchor, label: NSTextField)`; five rows use it and stash the label in instance properties (`threadsLabel`, `beamLabel`, `typedDelayLabel`, `silenceThresholdLabel`, `silenceSecondsLabel`). Existing `placeRow` is now a thin wrapper that discards the label.

#### Pane reorganization

Silence auto-stop controls moved from Advanced to Audio: they govern recording behavior, not transcription engine configuration. Audio pane now has six rows (Input device, Start sound, Stop sound, Auto-stop, Silence threshold, Silence duration); Advanced is back to its previous four (Transcription threads, Accuracy, Debug recordings, Logging).

#### UI copy guidance in `CLAUDE.md`

New `## UI copy` section codifying industry-standard microcopy practice (Nielsen Norman, Apple HIG, Material Design). Declarative advice is explicitly permitted ("Recommended for X", "Higher = more X"); second-person addressing is forbidden ("you", "your", "if you want"). Covers tone, content, form, and error-state handling.

Three hints adopt the pattern:

- Silence threshold: `RMS level · default 0.01 · lower = more sensitive`
- Silence duration: `seconds · default 4.0 · higher = more tolerant of pauses`
- Typed delay: `ms per character · default 5 · max 100 · higher = fewer dropped keystrokes`

### 2026-11-15 — Update checker and SemVer display version

#### Manual update check against GitHub Releases

New feature. "Check for Updates…" menu item in the status menu, and a matching button in the About window. Both call `UpdateCheckWindowController.present()` which shows a non-modal window with a spinner and status label, kicks off a GitHub API call, and renders the result in-place.

`Core/UpdateChecker.swift` hits `https://api.github.com/repos/P-DoxQuad/push-to-dictate/releases/latest` with a 10 second timeout, parses `tag_name` and `html_url` from the JSON via `JSONSerialization` (10.11 safe, no `Codable`). Compares the fetched tag (stripped of leading `v`) against the installed `CFBundleShortVersionString` using a component-wise integer compare that pads the shorter dot-sequence with zeros so `2026.11.0.1` sorts correctly against `2026.11.0`. Lexicographic string compare would have put `2026.11.10 < 2026.11.2`, which is wrong.

`App/UpdateCheckWindowController.swift` holds a `private static var active` strong reference for the duration of the check. Without this the local controller in `present()` falls out of scope the instant the function returns, the network completion's `self?.render` evaluates to nil, and the spinner spins forever. First smoke test caught this.

Three terminal states, swapped into the same window:
- Up to date: "Up to date." + "Installed version: X" + OK
- Update available: "Update available: Y" + "Installed version: X" + Open Releases Page / Later
- Error: "Couldn't check for updates." + reason + OK

"Open Releases Page" uses `NSWorkspace.shared.open` on the release's `html_url` (e.g. `https://github.com/P-DoxQuad/push-to-dictate/releases/tag/v2026.11.0`). No download, no install, no appcast, no background polling. Entirely user-initiated.

#### Dual version display

Prior state: `CFBundleShortVersionString` was shown in the About window and compared by the update checker. Both uses are now split.

New Info.plist key `PQDisplayVersion` holds the SemVer label (currently `1.1`) shown as "Version X" in the About window. `CFBundleShortVersionString` holds CalVer (`2026.11.1`) and is read only by the update checker to compare against GitHub tags. The two advance on different cadences:

- CalVer bumps immediately on `main` after cutting a release, so in-development builds identify as newer than the last shipped tag. This is what a running dev build reports to the update checker; it will correctly say "up to date" against the GitHub release that was the basis for the bump.
- SemVer is just a label; nothing compares against it. Bumps once per development cycle (1.1 after shipping 1.0, 1.2 after shipping 1.1, etc.).

`CLAUDE.md` release procedure updated to list both keys to confirm when cutting, and to require bumping both on `main` immediately after a release goes out.

### 2026-11-15 — First-launch flow: Move-first, non-modal Accessibility, auto-restart

#### Prompt order reversal

Prior: `AppDelegate.applicationDidFinishLaunching` installed the status controller (which blocked on an `NSAlert` for Accessibility) before offering Move-to-Applications. For an unsigned / ad-hoc-signed build, the Accessibility database records permission against the binary's path on disk. Granting at the Downloads path and *then* moving the bundle invalidated the grant, since the relocated binary isn't the one the user whitelisted.

Fix: run `maybePromptMoveToApplications` before constructing `StatusItemController`. If the user accepts the move, the app relaunches from `/Applications/` and the Accessibility prompt subsequently runs against the final-path binary. If the user declines or skips, status controller comes up and Accessibility is requested from the original location. Added `NSApp.activate(ignoringOtherApps: true)` before the Move alert so it foregrounds reliably from an `LSUIElement` process with no window on screen yet.

#### Non-modal Accessibility request window with live polling

New `App/AccessibilityRequestWindowController.swift`. Replaces the blocking `NSAlert` with a non-modal window that:

1. States the Accessibility requirement in plain copy.
2. Offers an "Open Accessibility Preferences" button that fires the standard `x-apple.systempreferences:` deep link to the Privacy pane.
3. Polls `AXIsProcessTrusted()` on a 1-second repeating `Timer` while shown.
4. On trust flip to true: stops polling, invokes an `onTrustGranted` closure provided by `StatusItemController` that re-runs `hotkeyMonitor.start()`.
5. Inspects `HotkeyMonitor.isActive` (new public property backed by `eventTap != nil`):
   - If true (in-place tap re-init succeeded): swaps window content to "You're all set." with a Done button. No restart needed.
   - If false (`CGEvent.tapCreate` still returning nil despite live-true trust — a known macOS quirk where trust denial is cached per-process below the AX API): swaps content to "Accessibility access granted / Restarting Push to Dictate to finish applying the permission…", hides buttons, and auto-restarts after 1.8 seconds via the same `sh -c "sleep 1; open '<bundle path>'"` + `NSApp.terminate(nil)` pattern `AppDelegate.performMoveToApplications` uses. No user action required.

Window retains itself via `static private(set) var active: AccessibilityRequestWindowController?` so the URLSession-style "local reference falls out of scope and controller dies" bug caught during the update-checker smoke test can't happen here either.

#### Attention-grabbing menu item for skipped Accessibility

New hidden-by-default menu item "Grant Accessibility Access…" with an `attributedTitle` in bold `NSColor.systemRed`. Visible only when `AXIsProcessTrusted() == false` AND `AccessibilityRequestWindowController.active == nil` (i.e. user dismissed the window without granting). `StatusItemController` conforms to `NSMenuDelegate` and implements `menuNeedsUpdate(_:)` to re-evaluate visibility just before the menu opens, so the item accurately reflects live permission state without polling. Clicking the item re-presents the Accessibility window; its dismiss / grant callbacks re-run the visibility check.

#### Welcome popover comment refresh

The 1.2-second deferred show had a comment saying it was timed to avoid overlap with blocking launch-time alerts. With all launch prompts now non-modal or reordered, the delay is only still needed for status-item button layout. Comment updated to reflect this.

### 2026-11-15 — Status menu rework and update attention UI

#### Status rows at the top of the menu

Three disabled `NSMenuItem`s now sit above the Start/Stop row and summarize current config:

- `Model: <stem>` — the local whisper.cpp model filename with `.bin` stripped (e.g. `Model: ggml-base.en-q8_0`). When the backend is OpenAI, this becomes `Model: whisper-1 (OpenAI)` and the Threads row is hidden.
- `Threads: N` — the number passed as `-t` to `whisper-cli`, pulled from `Preferences.transcriptionThreads`. Hidden for the OpenAI backend since the thread count doesn't apply there.
- `Behavior: Toggle · Typed` (or `Push-to-talk · Pasted`, etc.) — combines the activation mode and the injection method on one line. Delimiter is a middot.

Refresh happens in `menuNeedsUpdate(_:)`, so switching backend, model, or mode in Preferences shows up the next time the menu is opened. Initial titles are populated at init time so the strings aren't empty before first open.

#### Hotkey next to Start Dictation

The toggle row now reads `Start Dictation  ⌃⌥Space` / `Stop Dictation  ⌃⌥Space` (hotkey rendered via the existing `PreferencesWindowController.describe(keyCode:flags:)` helper the welcome popover already uses). Refreshed both on recording-state transitions and on hotkey preference changes, so rebinding the hotkey updates the menu row without an app relaunch.

#### Update-pending attention indicator

After "Check for Updates…" returns `.updateAvailable`, two things flip:

1. The menu row becomes `Update available: <latest>` with an `attributedTitle` in bold `NSColor.systemBlue`.
2. The menu-bar icon draws a filled `NSColor.systemOrange` badge in the bottom-left corner with a bold white "1". Badge size 15px, font 11pt bold. Drawn by a new `withUpdateBadge(_:)` helper that composites on top of whatever the icon currently shows (plain / recording dot / processing dot / error tint). Not tied to `IconState`, so it survives across recording transitions.

Both clear automatically if a subsequent manual check returns `.upToDate`. An `.error` result leaves the pending state alone (a transient network failure shouldn't drop a previously-known update).

Position (bottom-left) and size (bigger than the recording/processing dot) were chosen after a quick live-view iteration against a simulate-mode toggle.

#### Skip This Update

The update window gains a third button in the `.updateAvailable` state: `Skip This Update` sits between `Later` (which keeps the badge) and `Open Releases Page` (which deep-links to the release page). Clicking Skip writes the skipped version string to the new `Preferences.skippedUpdateVersion` key and clears the in-session `pendingUpdateVersion`.

Logic on subsequent checks:

- `.updateAvailable(latest)` with `latest == skippedUpdateVersion` → badge stays suppressed. The window still shows the real "Update available" content when the user manually re-checks, so the skip can be reversed by just hitting `Open Releases Page`.
- `.updateAvailable(latest)` with `latest != skippedUpdateVersion` → a newer version appeared; badge shows normally. Skip is version-specific, not a permanent "never nag me" switch.
- `.upToDate` → `skippedUpdateVersion` is cleared (tidy-up; nothing left to skip).

Implemented by extending `UpdateCheckWindowController.present` to take two callbacks: `onResult` (existing behavior) and `onSkip(String)` (the skipped version). `StatusItemController` handles both and pokes `Preferences`.

#### Simulation toggle on `UpdateChecker`

New compile-time flag `UpdateChecker.simulateUpdateAvailable` (default `false`) short-circuits the GitHub API call and returns a synthetic `.updateAvailable(current, "2026.99.0", <releases page URL>)` after a 0.4s delay, so the full Check → badge → Skip → re-check loop can be exercised without waiting on a newer release to actually appear upstream. Used during this cycle's UI iteration; left in place behind the flag for future flow testing.

### 2026-11-15 — Accessibility copy, status-row labels, catalog pruning

#### Accessibility window copy

Under ad-hoc ("Sign to Run Locally") signing, replacing the installed binary with a newer build leaves a stale TCC entry whose stored code-signature requirement no longer matches the new binary. `AXIsProcessTrusted()` returns false even when the user sees the box checked in the Accessibility list. Toggling the box off and on does not recover the grant, because the stored requirement is what the toggle re-evaluates against. The only user-side recovery is to remove the entry via the minus button and re-add the new binary via the plus button. macOS exposes no API that lets the app delete its own TCC entry.

Body text in `AccessibilityRequestWindowController` is now explicit about both paths. Fresh-install paragraph names the action directly: open System Preferences, find Push to Dictate in the Accessibility list, check the box. Stale-entry paragraph (new): if Push to Dictate already appears but access isn't taking effect, select the entry and click the minus button to remove it, followed by the plus button to add it again. Window height 240 → 320 to fit the longer body.

No code paths changed. The v1.1 window continues to poll `AXIsProcessTrusted()` while visible, re-init the event tap on grant, and auto-restart when in-place re-init hits the macOS trust-cached-false quirk. `openAccessibilityPreferences` button still only opens the Prefs URL. No `AXIsProcessTrustedWithOptions` call anywhere; no macOS system sheet is ever summoned by this app, so the custom window cannot overlap a system sheet on any OS.

Close-path bug fixed in the same controller: closing the window via the red traffic-light button used to leave the controller in a half-dismissed state. `dismiss()` was the only code path clearing `active` and calling `onMenuShouldRefresh`, and it was only wired to the Later button. The red X went through AppKit's own close, skipped both, and left `active` non-nil. `refreshAccessibilityMenuItem` gates visibility on `active == nil`, so the "Grant Accessibility Access…" status-menu item stayed hidden even with permission still missing — no path back to the prompt. Controller now adopts `NSWindowDelegate` and runs stop-polling + clear-active + refresh-menu from `windowWillClose`, which fires for every close path. `dismiss()` itself is slimmed to just call `window?.close()`.

#### Status-row label tweaks

Two of the three status rows at the top of the menu got renamed for clarity:

- `Threads: N` → `Thread Usage: N`. The underlying value still comes from `Preferences.transcriptionThreads` (the `-t` passed to `whisper-cli`). The new label reads more like "how many threads the transcribe uses" rather than ambiguously "how many threads exist on the system."
- `Behavior: <mode> · <method>` → `Modes: <mode> · <method>`. "Modes" matches the fact that both halves are selectable modes (activation mode, injection mode), where "Behavior" was vaguer.

`Model:` row unchanged.

#### Model catalog pruning

`medium.en-q8_0` and `large-v3-turbo-q8_0` are commented out in `ModelCatalog.swift` (not deleted, so the entries can come back later without rewriting). Testing on both the Westmere-era Mac Pro 5,1 host and an M2 Pro Mac Mini (running under Rosetta 2) showed them to be too slow to be practically usable for push-to-dictate's short-dictation use case. If they're unusable on both the oldest supported hardware and a recent Apple-silicon machine, keeping them in the download list is just a trap for users on anything in between.

Active downloadable catalog is now `small.en-q8_0` only. Bundled models (`tiny.en-q8_0`, `base.en-q8_0`) are unchanged. The `.mid` and `.high` `CatalogModel.Tier` cases survive because the commented block still references them; keeping the enum intact avoids churn if the models come back. First-launch auto-pick iterates the active catalog so it correctly picks from what's shipping. Users who already have a medium or large model on disk from a prior install still have it resolved via `whisperModelPath`'s writable-directory lookup — pruning the catalog doesn't delete anything from `~/Library/Application Support/push-to-dictate/models/`, it just removes the Manage Models entries that would offer those filenames as downloads.

### 2026-11-16 — Continuous dictation (experimental)

#### Overview

New opt-in mode where a single recording session produces multiple transcripts instead of one. A short pause in speech (default 0.5 s) is treated as a *chunk boundary* rather than an end-of-utterance: the buffer up to that point is handed off to the transcription queue, the per-chunk buffer is cleared, and recording continues. The user sees text appear in the focused field within a chunk-plus-transcription-time of speaking it, rather than waiting until they toggle dictation off.

Mutually exclusive with silence auto-stop: both watch RMS below a threshold, but one chunks and one ends. Turning either on in Preferences flips the other off (enforced in the Preferences setters; the UI mirrors the state). Push-to-talk mode ignores the continuous setting — continuous makes sense only under toggle-mode semantics.

#### `AudioRecorder` chunk-boundary callback

Added `chunkBoundaryThreshold`, `chunkBoundaryDuration`, and `onChunkBoundary` alongside the existing auto-stop plumbing. Different from auto-stop: this can fire multiple times per recording, and the callback receives the samples-since-last-boundary (not the whole recording). State machine uses `chunkHasSpeech` (arm on speech) + `chunkSilentSince` (clock on silence) so empty-chunk fires during sustained silence are impossible. On boundary: pull-and-clear the per-chunk buffer, reset peak RMS, keep the audio engine running.

Threshold reuses `Preferences.silenceAutoStopThreshold`. "What counts as silence" is one concept; no reason to ask twice.

#### `StatusItemController` pipeline

Serial `DispatchQueue continuousQueue` processes chunks FIFO. Each chunk:
1. `handleContinuousChunk` runs the min-length filter (0.4 s at 16 kHz = 6400 samples) and enqueues.
2. `enqueueContinuousChunk` increments a pending counter, constructs a fresh transcriber per chunk, and dispatches a block to the serial queue.
3. Inside the block, a `DispatchSemaphore` blocks the serial queue on the transcriber's async completion handler to serialize call ordering.
4. `handleContinuousResult` runs on main, decrements the pending counter, trims whisper's whitespace, appends a trailing space, and injects via `textInjector.insert`.

Final-tail handling: on `setRecording(false)` with continuous active, the samples returned from `audioRecorder.stop()` are enqueued as the last chunk if they pass the min-length and peak-RMS guards. The icon stays `.recording` during continuous capture; on stop, flips to `.processing` if chunks are still draining, then to `.idle` on drain. Starting a fresh recording clears `drainingAfterContinuous` so lingering old chunks don't flip the new session's icon.

#### Trailing-space separator

Each chunk's whisper output is trimmed of leading/trailing whitespace, then a single trailing space is appended before injection. Trailing-space (rather than leading-space-after-first) handles three cases cleanly: separates consecutive chunks within a session, separates chunks across sessions (previous session already left the separator), and leaves the new line empty after a user-pressed Enter mid-session instead of planting a stray leading space on the new line.

#### Beam-size override per-transcriber

`WhisperCppTranscriber` gains `beamSizeOverride: Int?`. The continuous path sets it to 1 before kicking off each chunk: short chunks don't benefit much from higher beam widths, and per-chunk latency dominates the felt experience. Override is per-instance, so one-shot dictation keeps using the user's saved `beamSize` preference. Threads stays shared — it's about CPU utilization, orthogonal to the use case.

#### Preferences UI

Audio pane gains two rows at the bottom: `Continuous:` checkbox and `Pause:` numeric field with hint `seconds · default 0.5 · pause length that cuts a chunk for transcription`. Pause validates in [0.3, 2.0]. Both the continuous and silence-auto-stop checkboxes sync each other's state on change, reflecting the mutual-exclusion already enforced in `Preferences`'s setters.

#### What's deferred

`whisper-server` for model-residency, parallel transcription with sequence-number ordered injection. Discussed; not worth building yet at the single-user dictation scale.

### 2026-11-16 — Continuous dictation refinements, preference defaults, Reset to Defaults

#### Max chunk length preference

`AudioRecorder.chunkBoundaryMaxDuration` is now driven by the new `continuousDictationMaxChunkSeconds` preference (default 30.0, range [5.0, 30.0], exposed as `Max chunk:` in the Audio pane under the `Pause:` field). Live testing showed the previously-hardcoded 3.0 s cap cut mid-sentence frequently and was the dominant cause of boundary artifacts; 30.0 s matches whisper's native internal window and in practice almost never triggers on natural speech because people breathe. The cap acts as a safety upper bound for monologue-pattern dictation, not as a primary chunking mechanism — pause detection is the primary mechanism.

#### Prompt chaining across chunks

`WhisperCppTranscriber.initialPrompt: String?` added. When set, the whisper-cli invocation gets `--prompt "<text>"` appended, seeding whisper's language-model state with prior context. This is the single biggest quality-of-transcription lever for continuous mode: it eliminates the "each chunk is a fresh conversation" problem that produced mishears (`click note` for `quick note`, `Russia` for `roughly`, `grab it coffee` for `grab a coffee`) and word-at-boundary duplications (`I I`, `the the`).

`StatusItemController.continuousPromptBuffer` is a rolling tail of transcribed text within the session, capped at 600 characters to stay inside whisper's prompt token budget. Reset on each new session. The buffer is read at **dequeue time** (inside the serial queue's task), not enqueue time: by the time a chunk's task runs, all prior serial tasks have completed, and their cleaned text is in the buffer. The result handler uses `DispatchQueue.main.sync` so the next task sees this chunk's output when it reads the prompt.

#### Non-speech token filter

`StatusItemController.cleanContinuousTranscript(_:)` strips whisper's annotation tokens (`[BLANK_AUDIO]`, `[MUSIC]`, `[SILENCE]`, `(soft music)`, `(laughter)`) from chunk transcripts before injection. These tokens are whisper's deliberate output for non-speech audio and show up frequently in continuous mode because the chunk-on-pause flow routinely feeds whisper short low-signal fragments. Regex strips both bracketed and parenthetical annotations, collapses the resulting whitespace, and the result is discarded entirely if it contains no letter or digit (catches pure-ellipsis outputs). Single-shot path left untouched.

#### Beam override

`WhisperCppTranscriber.beamSizeOverride: Int?` added. The continuous path sets it to `2` (down from the initially-tried 1 to add decode robustness without the latency of 3). Single-shot dictation continues to use the user's saved `beamSize` preference.

#### Default changes

- `beamSize` default: `5 → 3` (set earlier in v1.1 default-tuning; hint text just now caught up to say `3 = default`).
- `typedKeystrokeDelayMs` default: `5 → 8`. Test runs showed 5 ms produced the occasional dropped keystroke on busier systems; 8 ms is noticeably more reliable with minimal perceptible delay.
- `transcriptionThreads` default: hardcoded `6` → dynamic. New `Preferences.defaultTranscriptionThreads` formula: `logical ≤ 12 ? logical / 2 : logical / 3`, floor of 1. Matches the "Recommended" range shown in the hint label and avoids the NUMA / HT tax on large-core machines. On dual-socket Westmere (logical 24): 8. On a quad-core laptop (logical 8): 4.
- `continuousDictationPauseSeconds` default: `0.8 → 0.5` (early in this session).
- `continuousDictationMaxChunkSeconds` default: `3.0 → 30.0` (this subsection above).

#### Reset to Defaults

New button in the Advanced pane under a `Preferences:` row label. Calls `Preferences.resetUserPreferences()`, which iterates `allUserDefaultsKeys` and removes each except the set of `internalFlagKeys` (`suppressedMoveToApplicationsPrompt`, `didAutoSelectModel`, `didShowWelcomeTooltip`, `skippedUpdateVersion`). Keychain-stored OpenAI API key is left alone — credentials shouldn't vanish in a preferences reset.

No confirmation dialog: destructive-action convention is to prompt, but the explicit directive here was that it's unnecessary for a preferences-only reset where no data is lost and the user can just re-tune anything they'd changed.

### 2026-11-16 — Post-processing pipeline, prompt-chain fix, prompt-chain controls

#### `postProcessTranscript` pipeline

`cleanContinuousTranscript` renamed to `postProcessTranscript` and extended. New stages, in order:

1. Bracket/paren annotation strip (unchanged: `[BLANK_AUDIO]`, `(music)`, etc.)
2. Whitespace collapse (unchanged)
3. Trim (unchanged)
4. **Trailing ellipsis strip (new)**: `(?:\.{3,}|…+)\s*$`. Whisper emits ellipses when it catches partial speech at a chunk tail; not useful for straight dictation.
5. hasContent check (unchanged)
6. **`normalizeCasing` (new)**
7. **`applyCapitalizationFixups` (new)**
8. **`applyTextSubstitutions` (new)**

Now runs on both continuous and single-shot paths. Previously only continuous.

#### `normalizeCasing`

Lowercases the text, then re-uppercases:

- The first alphabetic character.
- Any letter following `. ! ?`, across intervening whitespace.
- Standalone `i` and its contractions (`I'll`, `I've`, `I'm`, `I'd`) via a `\bi\b` → `I` regex pass. `\b` treats the apostrophe as a word boundary, so the pattern matches the `i` in `i'll` but not the `i` inside `apply` or `is`.

Mid-word punctuation (commas, apostrophes, hyphens) does not trigger capitalization. In continuous mode the first word of every chunk is capitalized, which is acceptable because pause boundaries usually align with sentence breaks.

Motivation: straight-dictation style where the user controls capitalization through what they actually say, rather than inheriting whisper's variable capitalization bias.

#### `applyCapitalizationFixups`

`Preferences.capitalizationFixups: [String]` (computed, backed by static `defaultCapitalizationFixups`) holds canonical forms the lowercase pass folded. Each entry is matched case-insensitively with word boundaries and replaced with the canonical casing.

Content: months, weekdays, common tech acronyms (API, JSON, XML, YAML, HTML, CSS, SQL, HTTP, HTTPS, URL, URI, SSH, FTP, TCP, UDP, DNS, CPU, GPU, RAM, USB, PDF, PNG, JPEG, GIF, SVG, SSD, HDD), tech brands (GitHub, GitLab, macOS, iOS, iPadOS, watchOS, tvOS, iCloud, iPhone, iPad, iMac, MacBook, YouTube, Google, Apple, Microsoft, Linux, Chrome, Firefox, Safari), macOS version names (Monterey, Ventura, Sonoma, Sequoia, Catalina, Mojave, Big Sur, High Sierra, El Capitan), programming languages (Python, JavaScript, TypeScript, Swift, Node.js, npm, Kotlin, Haskell, Lua), frameworks (Django, Kubernetes, TensorFlow, PyTorch), databases (MySQL, PostgreSQL, MongoDB, Redis, SQLite), country acronyms (USA, UK, EU, UAE), global orgs (NASA, FBI, CIA, NATO, OPEC, UNESCO, UNICEF, NGO, GDP), wireless (Wi-Fi, Bluetooth, Ethernet), AI/ML (NLP, LLM, GPT, TPU, CUDA), graphics APIs (OpenGL, OpenCL, Vulkan), OS distros (Ubuntu, Debian, ChromeOS), Apple products (AirPods, HomePod, AirTag), fast food brands (McDonald's, Burger King, Tim Hortons, Wendy's, Harvey's, Starbucks, Chipotle, Taco Bell, KFC, Domino's, Pizza Hut, Papa John's, Little Caesars, Dairy Queen, Arby's, Popeyes, Red Lobster, Boston Pizza, Swiss Chalet, Pizza Pizza, Jimmy John's, Panda Express, Hardee's, Whataburger, Culver's, Panera, Shake Shack).

Deliberately excluded:

- **Honorifics with trailing periods** (Mr., Mrs., Ms., Dr., Prof.). The embedded period would collide with sentence-boundary logic.
- **Short ambiguous words** (WHO, Windows, React, Angular, Rails, Flask, Metal, Mac, Go, Rust, Dart, Elixir, Ruby, Python-as-snake, Subway, Olive Garden, Five Guys, Montana's, In-N-Out). Case-insensitive word-boundary matching would overreach into non-brand occurrences.
- **Storage / frequency units as-abbreviations** (MB, GB, Hz, kHz, MHz, GHz). Whisper spells out "megabytes" / "gigahertz" in prose; the abbreviation form never appears from spoken input.

Structure allows migration to a user-editable file without touching call sites: change the getter body to read from a file path, fall back to the static default when the stored value is empty.

#### `applyTextSubstitutions`

`Preferences.textSubstitutions: [(String, String)]` (computed, backed by static `defaultTextSubstitutions`). Each tuple is `(pattern, replacement)`, applied case-insensitively with word boundaries. Covers cases where match form differs from produced form:

- `mac os` → `macOS`. Whisper tokenizes the brand as two words from some phoneme runs; the single-word capitalization fixup for `macOS` doesn't match.
- Byte unit expansion: `kilobyte(s)` → `KB`, `megabyte(s)` → `MB`, `gigabyte(s)` → `GB`, `terabyte(s)` → `TB`, `petabyte(s)` → `PB`.
- Bit rate expansion: `kilobits per second` → `Kbps`, `megabits per second` → `Mbps`, `gigabits per second` → `Gbps`.
- `a and w` → `A&W`.
- `Chick-fil-A` variants: `chick fil a`, `chick fill a`, `chickfila`, `chick filet`, `chick fillet` → `Chick-fil-A`.

Hertz family (`hertz`, `kilohertz`, `megahertz`, etc.) deliberately excluded: too aggressive; the abbreviated form would appear in casual prose contexts where the written word is more natural.

Same migration path as fixups.

#### Dead prompt chain fix

`appendToContinuousPromptBuffer(_:)` existed with an implementation, and was conceptually part of the prompt-chaining flow (reset on session start, read when building `--prompt`), **but was never actually called** from `handleContinuousResult`. The buffer stayed empty for every chunk of every session. Added the missing call after each successful injection. Whisper now sees previous chunks' cleaned text as `--prompt` context in the subsequent chunk's invocation.

Visible effect: words that previously came through as acoustic approximations (`son` for JSON, `Russia` for `roughly`, `click note` for `quick note`) resolve correctly once a few prior chunks have established the domain context.

#### Beam override reduced from 2 to 1

`StatusItemController` continuous path now sets `WhisperCppTranscriber.beamSizeOverride = 1`. Short chunks derive minimal accuracy benefit from wider beams; savings are small per chunk but free. Single-shot dictation continues to honor `Preferences.beamSize`.

#### Prompt chain toggle and max-chars preference

Two new preferences:

- `continuousDictationPromptChainEnabled: Bool` (default `true`). Gates the call to `appendToContinuousPromptBuffer`. When off, the buffer stays empty and whisper gets no `--prompt`, which eliminates the per-chunk prompt-encode cost. That cost is small on tiny but perceptible on base; the toggle is the A/B knob.
- `continuousDictationPromptChainMaxChars: Int` (default 200, range [100, 900]). Rolling buffer character cap. The previously-hardcoded 600 was 2/3 of whisper's ~224-token prompt budget; testing showed 200 chars is enough context to keep continuity across chunks and noticeably reduces the per-chunk latency delta between base and tiny.

`StatusItemController.continuousPromptMaxChars` (hardcoded 600) removed; `appendToContinuousPromptBuffer` reads the cap from the preference.

UI in the Audio pane, below Max chunk:

- `Prompt chain:` checkbox: "Feed prior transcript to whisper as context".
- `Max chars:` numeric field with hint "characters · default 200 · min 100 · max 900 · higher = more context, slower". Validated inline; red on out-of-range input, reverts to pref on blur if invalid.

Both keys added to `allUserDefaultsKeys` so Reset to Defaults clears them.

After the reset: the button handler also invokes `onHotkeyChanged`/`onColoredIconChanged` callbacks on the controller so the status-bar icon and menu re-pick up the fresh defaults (hotkey binding, colored vs monochrome icon) alongside the Preferences UI re-rendering via `refreshAll`.

### 2026-11-17 — Experimental: strip-punctuation continuous mode with pause-driven sentences

Branch: `experiment/pause-driven-sentences`. All behavior changes are gated behind a new `continuousDictationStripWhisperPunctuation` preference (default `false`), so existing continuous-mode behavior is preserved unless the user opts in.

#### Design

Treat whisper's punctuation and capitalization output on short chunks as unreliable. Strip sentence-ending periods, lowercase everything, drive sentence-break decisions from measured silence gaps between chunks rather than from whisper's internal guesses. Insert `". "` + capitalize at a user-tunable sentence-pause window; plain `" "` otherwise. Each chunk is injected immediately when transcribed (no staging, no cross-chunk delay) so continuous mode stays actually continuous.

#### `postProcessTranscript` strip mode

New `stripPunctuation: Bool` parameter. When true:

- Strip sentence-ending periods matching `\.+(?=\s|$)`. Periods inside words (`whisper.cpp`, `Node.js`, `D.C.` mid-sentence) are preserved; only periods followed by whitespace or end-of-string get replaced with a space.
- `normalizeCasing` is called with `capitalizeAtSentenceStarts: false`. It lowercases everything except the alpha character immediately following `?` or `!`, which keeps whisper's original case. This preserves legitimate sentence-break capitals whisper emits on intonation that the pause-driven policy can't reconstruct.

#### Leading angle-bracket artifact strip

Added `^\s*>+\s*` to the per-chunk strip patterns alongside existing bracket/paren removal. Whisper emits `>> ` prefixes on silent or near-silent chunks (seen alongside `[silence]` tokens).

#### `AudioRecorder` gap telemetry

`onChunkBoundary` signature extended from `([Float]) -> Void` to `([Float], TimeInterval) -> Void`. Two new internal timestamps (`previousChunkLastSpeechAt`, `currentChunkFirstSpeechAt`) record when the previous chunk's last speech-level sample fell and when the current chunk's first speech sample arrived. Their difference is the preceding gap, passed through on each emit. Gap is 0 for the first chunk of a session and for final-tail chunks enqueued via `setRecording(false)`.

#### Session ID for stale-chunk drop

New `currentContinuousSessionId: Int` monotonic counter, incremented on each session start. `enqueueContinuousChunk` captures the ID at enqueue time; `handleContinuousResult` checks it against the current ID. Chunks from a prior session are dropped with a log line rather than injected. Prevents late-arriving chunks from corrupting the new session's first-chunk state when the user stops and immediately restarts continuous mode.

#### Leading-separator policy in `handleContinuousResult`

Strip-mode branch applies a prefix to each chunk's cleaned text based on the measured preceding gap:

- First chunk of session: `""` prefix, capitalize first letter.
- `CursorContext.isCursorAtLineStart()` returns `true`: `""` prefix, capitalize first letter.
- Gap in `[continuousDictationSentencePauseSeconds, continuousDictationSentencePauseMaxSeconds]`: `". "` prefix (or `" "` if the previously injected chunk ended with `?` or `!`), capitalize first letter.
- Otherwise: `" "` prefix, no capitalization change.

Nothing is injected with a trailing separator in strip mode. State tracked across chunks: `isFirstContinuousChunk`, `previousInjectedEndedWithSentencePunct`.

#### `CursorContext` via Accessibility API

New file `Core/CursorContext.swift`. Queries `AXUIElementCreateSystemWide()` → `kAXFocusedUIElementAttribute` → `kAXSelectedTextRangeAttribute` and `kAXValueAttribute` to determine whether the cursor in the focused text control is at a line start (position 0, or immediately after `\n`, `\r`, U+2028, or U+2029). Returns `Bool?`: `true` or `false` when AX answered, `nil` when any step failed (no focused element, element isn't a text container, value isn't a string, cursor range not available).

Used in strip mode to force a fresh-start prefix (`""` + capitalize) when the cursor is on a new line after the user pressed Enter mid-session. Uses the existing Accessibility permission granted for the hotkey event tap. Not every app supports AX text access; the `nil` return falls through to the normal gap-based logic so the feature is additive.

#### New preferences

- `continuousDictationStripWhisperPunctuation: Bool` (default `false`): master switch for the strip-mode behavior. When off, continuous mode uses the existing trailing-space injection path.
- `continuousDictationSentencePauseSeconds: Double` (default `1.0`): lower bound of the sentence-break window. Range gated above `continuousDictationPauseSeconds`, below the max field, capped at `5.0`.
- `continuousDictationSentencePauseMaxSeconds: Double` (default `2.0`): upper bound. Range gated above the min field, capped at `10.0`. Gaps longer than this are treated as think-pauses, not sentence breaks.

All three added to `allUserDefaultsKeys` so `Reset to Defaults` clears them.

UI: three new rows in the Audio pane under the existing Max chars field: `Strip punctuation:` checkbox, `Sentence pause min:` and `Sentence pause max:` numeric fields with inline validation (red text on out-of-range, revert-to-pref on blur).

#### Fixup list expansion

Significant additions to `defaultCapitalizationFixups` for geographic and personal-name coverage:

- Canada: all 10 provinces, all 10 provincial capitals (Edmonton, Victoria, Winnipeg, Fredericton, St. John's, Halifax, Charlottetown, Quebec City, Regina, Toronto), plus Vancouver, Calgary, Ottawa.
- United States: all 50 states, all 50 state capitals (Saint Paul, St. Paul, Jefferson City, Carson City, Oklahoma City, Salt Lake City, etc.), plus America, United States, D.C., D.C, DC.
- Personal names: Michael, Andy, Dylan, Raymond, Johnson, Jonathan, Derek, Emily, Sarah, Bill, Curtis, Curtiss, Billy, Holly, Laura, Andrew, Tyson, Jenny, Jennifer, Maria, Jane, Marie, Sean, Shawn, Ron, Ronald, Esther, Leo, Leonardo, Leon, Nadia, Larry, Michelle, Matt, Matthew.

New `defaultTextSubstitutions` entries for canonical forms whose embedded period strip mode removes: `("st john's", "St. John's")` and `("st paul", "St. Paul")`.

#### Prompt chain feeds non-stripped form (post-commit refinement)

Observed on testing: in strip mode, whisper's acoustic disambiguation on close word pairs like `an`/`and`, `to`/`too`, `their`/`there` was slipping in cases where it had been correct under non-strip mode. Root cause: the prompt buffer was accumulating the injected (stripped, lowercase) form, so whisper's decoder was reading context like `"i'll be going for about 6 days and should be back on the 21st"` instead of `"I'll be going for about 6 days and should be back on the 21st."`. Mid-chunk periods and sentence-start capitals were being removed from the prompt before whisper ever saw them.

Fix: when strip mode is on, compute a second post-process pass of the raw chunk text with `stripPunctuation: false` and feed that fully-punctuated sentence-case form to `appendToContinuousPromptBuffer`. The user's visible injection still uses the stripped form; only the prompt buffer sees the rich form. Non-strip mode is unchanged (prompt and injection are identical there). Doubles the per-chunk post-process cost in strip mode, which is negligible at these string sizes.

#### `AudioRecorder` max-chunk timer and buffer reset on speech-begin

Lowering `continuousDictationMaxChunkSeconds` to small values (10 s or less) caused whisper to hallucinate heavily and mis-transcribe. Root cause: both `chunkSampleCount` and the audio `buffer` were accumulating from the moment a chunk slot opened (session start or previous emit), regardless of whether any speech had occurred yet. The max-chunk emit was correctly gated on `chunkHasSpeech`, but by the time speech actually arrived, the counter was already loaded with however much pre-speech silence had piled up. At max-chunk=10 s, a 20 s pre-speech silence followed by any speech triggered an immediate emit containing mostly silence; whisper then invented words to fit the audio.

Fix in `AudioRecorder.handleInputBuffer`: when the audio level crosses `chunkBoundaryThreshold` on a chunk with `chunkHasSpeech == false` (the speech-begin transition), reset `chunkSampleCount = 0` synchronously and queue a `bufferQueue.async { buffer.removeAll(keepingCapacity: true) }`. The current pcm callback's samples are still appended via the subsequent `bufferQueue.async` further down in the function; because `bufferQueue` is serial, the clear runs before the append, so the first speech samples are preserved and only the preceding silence is discarded. Preceding-gap timestamps (`previousChunkLastSpeechAt`, `currentChunkFirstSpeechAt`) are untouched; gap still measures silence duration between chunks correctly.

Effects:

- `max_chunk` now measures speech-time (plus within-speech micro-pauses up to the boundary threshold), not wall-clock-from-chunk-slot-start.
- Low `max_chunk` values (10 s) are usable without hallucinations.
- Each emitted chunk starts at the first speech sample; whisper no longer sees long leading silence.
