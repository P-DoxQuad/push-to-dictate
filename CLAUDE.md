# push-to-dictate

Directives for working on this repo. Scope, and work history, are in `DEVLOG.md`, and `README.md`. `claude.local.md` has secrets only you need to know

## Writing style

Applies to all project docs (CLAUDE.md, README.md, DEVLOG.md, THIRD_PARTY_NOTICES.md, in-repo notes, commit messages). Applies to any new documentation added later.

- Directives and declarative statements. Not narrative.
- Formal documentation register. Describe and explain. Never narrate.
- No addressing the reader ("you", "your", "let me"). No meta-speech ("this document covers", "in this section we"). No TV-host or tour-guide voice.
- No mission statements, reinforcement loops, or journal entries.
- No marketing copy, inspirational framing, "designed to", or "built for people who".
- Short imperatives. One rule per bullet.
- Concrete and verifiable. Name the command, the file, or the flag.
- Lists over paragraphs where the content is enumerable.
- Technical terms as-is. Do not soften.
- No em-dashes anywhere (docs, UI strings, commit messages, chat output). Use a colon, period, or regular hyphen instead. Em-dash use is an AI tell.
- Multi-step reference procedures go in `.claude/rules/*.md` or as skills. Not in CLAUDE.md.

## Build

- Xcode 10.1. Swift 4.2. Deployment target 10.11 (El Capitan).
- AppKit, menu-bar only. `LSUIElement = YES` in `Info.plist`.
- Source layout: `App/`, `Core/`, `Transcribers/`, `Prefs/`, `icons/`.
- whisper.cpp: pinned to v1.7.2. Build `whisper-cli` for x86_64 via `scripts/setup.sh`. Models bundled in `.app/Contents/Resources/`; writable fallback is `~/Library/Application Support/push-to-dictate/models/`.

## Swift 4.2 ceiling

CRITICAL. The compiler is Swift 4.2 on Xcode 10.1. Swift 5 APIs do not exist here. Before writing any Swift expression that looks natural in modern Swift, verify it's not a Swift 5 addition. Common Swift 5-only APIs that have bitten this codebase:

- `Character.isNumber`, `Character.isLetter`, `Character.isWhitespace`, `Character.isASCII`, `Character.isUppercase`, `Character.isLowercase`, `Character.isHexDigit`, `Character.isNewline`, `Character.isPunctuation`, `Character.isSymbol`, `Character.isCurrencySymbol`, `Character.isMathSymbol`, `Character.isWholeNumber`, `Character.hexDigitValue`, `Character.properties`. Use range comparisons (`$0 >= "0" && $0 <= "9"`) or `CharacterSet` instead.
- `Result<Success, Failure>` (standard library). Define a local enum.
- Raw string literals `#"..."#`.
- `@propertyWrapper`, `@dynamicCallable`, `@dynamicMemberLookup` with keypaths.
- `Dictionary.compactMapValues`.
- `Sequence.count(where:)`.
- `String.contains(_ c: Character)` (Swift 5 added this specifically; use `contains(where:)` or `String.firstIndex(of:)`).
- Custom string-interpolation via `ExpressibleByStringInterpolation` (SE-0228).

The compiler message for these is usually "unable to infer closure type in the current context" or "value of type 'Character' has no member 'X'". Both are tell-tale signs of a Swift 5 API slipping into 4.2 code.

Also unavailable at the deployment target (10.11) even when the compiler would allow it: `async/await` (Swift 5.5), `actor` (5.5), `@MainActor` (5.5), `Combine` (10.15+), `SwiftUI` (10.15+), `OSLog` 10.14+ APIs, `UNUserNotificationCenter` (10.14+), `effectiveAppearance` dark-mode detection (10.14+), `NSApp.appearance` modern dark-mode (10.14+). 10.14+ features that are actually needed must be wrapped in `#available(macOS 10.14, *)` with a 10.11-compatible fallback path (see `StatusItemController.showError` and dark-mode icon selection as the pattern).

## UI copy

Applies to all user-facing strings: labels, hints, placeholders, button titles, tooltips, menu items, dialog messages, status text, error messages. Based on Nielsen Norman Group, Apple HIG, and Material Design practice.

**Tone**

- Declarative, third-person or imperative. Not conversational.
- No second-person addressing: "you", "your", "if you want", "so that your", "to make sure".
- Declarative advice is allowed and standard practice: "Recommended for X", "Best for Y", "Higher = more X", "Lower = more Y". These are directional facts, not conversation.
- Plain language. No jargon unless the domain requires it.

**Content**

- Each string informs, influences behavior, or supports the interaction. Nothing decorative.
- Facts are encouraged: units, defaults, ranges, min/max, scale explanations ("1 = fastest · 5 = default · 10 = slowest").
- Hint text is warranted when the input format is unusual, a domain rule applies, or the user might reasonably wonder how the value affects the system.
- Do not restate facts the control already shows by its current state (current value, enabled/disabled, selected option).
- Placeholder shows format. Label names the field. Never substitute placeholder for label.

**Form**

- One line when possible. Scannable over paragraphed.
- No marketing language, no inspirational framing, no "designed to", no "built for".

**Errors**

- Error text replaces helper text in the same slot, not appended. Prevents layout shift.
- Errors appear next to the offending field, not at the top of the form.
- No early validation that interrupts typing.

## Code

- Comments minimum. Only on non-trivial code, non-obvious arguments, non-obvious member semantics. Never narrate what the code does.
- Do not remove existing comments unrelated to the change.
- No emoji in code.
- Do not create shim functions, wrapper helpers, extension methods, or compatibility layers unless strictly necessary. Necessary means: an API is unavailable on the deployment target and needs a drop-in replacement, OR the same inline setup is being duplicated in three or more places with real risk of divergence. Everything else is inlined. "I thought it would be cleaner" is not a reason. Wrappers that encapsulate three lines of property assignment are noise. If one exists and it's not necessary, inline it when touching surrounding code.

## Workflow

- No commits without explicit per-commit instruction. Prior yes does not carry forward.
- No destructive git or filesystem commands without confirmation.
- Announce every long-running action before starting it: build, rebuild, clobber, rsync, push, release upload, mozconfig edit that invalidates cache, any `./mach` taking more than a minute, any filesystem rename. State what, why, and duration; wait for confirmation. "Doing X now" is not announcing.
- Preserve cwd. Stage symlink fallbacks before any rename / move / unmount of an ancestor directory.
- Commit messages name project changes (source, mozconfig, branding, patches). Docs (`README.md`, `DEVLOG.md`, `CLAUDE.md`) ride along in the diff silently and are never narrated in the message.
- After 2–3 failed attempts on the same error: stop and reconsider the approach.
- Preempt predictable failures in a single patch pass. Catalog known instances before building, not after reproducing each.
- Repo work follows standard conventions without being asked: no personal paths, no build artefacts committed, no files above GitHub's 100 MB limit, user-facing README written for end users, MPL-compliant attribution.

## Release

Dual versioning:

- Public (shipped, git tags, release assets, `CFBundleShortVersionString`, update checker compare): CalVer `YYYY.MM.PATCH`. Year.Month.PatchWithinMonth. First release of the month uses `PATCH = 0`; subsequent same-month releases increment. New month resets `PATCH` to `0`. Same-version bugfix respin appends a fourth digit: `YYYY.MM.PATCH.N`. On `main`, this version always reflects "newer than the last shipped release", so it bumps immediately after cutting a release, not when the next one cuts.
- Internal (mental model, local folder names, branch names, user-facing About window via `PQDisplayVersion` Info.plist key): SemVer-style `MAJOR.MINOR[.PATCH]`. `MAJOR` on rewrites or breaking changes. `MINOR` on new features. `PATCH` on bugfixes with no new features.

Branching model:

- `main`: active development. Always ahead of the latest shipped version.
- `release/vN.M`: frozen at a shipped version's state. One per shipped `MAJOR.MINOR`. Only touched for backports.
- Tags: immutable once external consumers have depended on them. Same-day force-moves are allowed to correct an objectively wrong tagged commit (stale docs, bad metadata, wrong SHA) before third parties have pulled it. One per shipped release, named with the CalVer version prefixed with `v` and no suffix (e.g. `v2026.11.1`). The `-Full` suffix is reserved for asset filenames only; never append it to tag names. When creating a release on GitHub, type the plain `v<CalVer>` into the Tag field so GitHub does not mint a new suffixed tag.

Release cutting:

- Confirm `CFBundleShortVersionString` and `PQDisplayVersion` in `App/Info.plist` match the release being cut (CalVer and SemVer respectively).
- Sweep `README.md` for stale version references: the `## Version` line, the zip filename in `## Installation`, and anywhere else the previous CalVer appears. Update in the same commit before tagging.
- Tag the release commit with the CalVer version prefixed with `v`.
- Branch `release/vN.M` from that tag.
- Push the tag and the branch to `origin`.
- Build the Release archive from the tagged commit, zip as `Push-to-Dictate-v<CalVer>-Full.zip` (asset filename carries `-Full` to mark it as the complete bundle, reserving naming space for possible partial-asset variants like `-Patch`), attach to the existing `v<CalVer>` tag's new GitHub release.
- On `main`, immediately bump `CFBundleShortVersionString` to the next anticipated CalVer and `PQDisplayVersion` to the next SemVer so in-development builds identify as newer than the shipped release.

Backport flow:

- Check out the relevant `release/vN.M` branch.
- Commit the fix on that branch.
- Bump `CFBundleShortVersionString` to a four-digit CalVer (`YYYY.MM.PATCH.N`). Bump `PQDisplayVersion` to a SemVer patch (`N.M.P`).
- Tag the branch commit with the same four-digit CalVer prefixed with `v`.
- Build and attach a new release asset.
- Cherry-pick the fix into `main` when applicable.

Local workspace:

- Frozen per-version folder snapshots live as siblings of the active working folder, suffixed with the local SemVer-style version (e.g. `-vN.M`). Active working folder keeps the unqualified project name.
- Snapshot folders are maintainer-managed. Do not create, rename, or delete them automatically.

## Style: assistant output

- Give the plan. No warnings about time, effort, or difficulty.
- One position per answer. Pivot explicitly when needed.
- Match length to the question. No preamble, no trailing summary.
- State decisions directly. Do not narrate deliberation.
- Omit unrequested caveats, warnings, and negatives.
- Ask when hardware or environment matters. Do not guess.
- No human-developer time estimates ("an hour", "half a day", "a week"). Those numbers are calibrated to a human typing, not actual throughput. If an estimate is genuinely needed, give it in realistic terms (small / medium / large change) or in concrete units (number of files touched, lines changed). Prefer no estimate at all.

## Environment

- Host: Mac Pro 5,1. macOS 10.13.6. Xcode 10.1 primary, 9.4.1 available.
- Swift 4.2 ceiling. No async/await, no Swift 5 runtime.
- whisper.cpp Swift package targets modern SPM. Unusable at this Swift ceiling. Use C API via bridging header, or shell out to `whisper-cli`.
- Mic permission dialog does not exist on 10.11-10.13. Input Monitoring permission does not exist on 10.11-10.13. Accessibility permission does: required for `CGEventTap` and synthetic keystrokes.