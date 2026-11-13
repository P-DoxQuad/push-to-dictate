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

1. **`/Volumes/Data-RAID/Users/mdzura/Documents/Projects/Sandbox/whisper.cpp/`** — standalone upstream clone of the whisper.cpp repository. Not tied to push-to-dictate. Reusable across any future project that needs whisper.cpp. Follows the user's existing Sandbox convention (Chromium Source, Firefox source, etc.).
2. **`/Volumes/Data-RAID/Users/mdzura/Documents/Projects/Sandbox/push-to-dictate/vendor/whisper.cpp/`** — project-local copy of the source, created by `rsync` from (1) with the upstream `.git` directory kept intact. This is what we actually build against for push-to-dictate. Pinned at whatever commit we rsynced; independent of upstream updates to (1).
3. **`/Volumes/Data-RAID/Users/mdzura/Documents/Projects/Sandbox/push-to-dictate/vendor/models/ggml-small.en.bin`** — the model file. ~465 MB. Lives inside the project's `vendor/` tree because it's an external artifact bound to this specific project build.

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
