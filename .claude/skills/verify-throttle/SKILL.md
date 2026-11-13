---
name: verify-throttle
description: Drive Throttle, the macOS menu bar app in this repo, the way a user does and capture proof. Launches a Debug build from this checkout, clicks its menu bar item and detail window through macOS Accessibility, and renders account states from fixtures through the hosted-view snapshot tests. Use to prove a UI change works, to check the empty state, Add account, Settings or Quit on the live app, or to look at rows, usage bars, rotation and banked resets that need accounts.
---

# Verify Throttle

Throttle has no window of its own until its menu bar item is clicked, no Dock
icon, and no test hooks in the shipped app. There are two ways to see it, and a
proof must say which one it used:

| Route | What it is | Proves |
| --- | --- | --- |
| **Live** | A Debug build from this checkout, launched and clicked through Accessibility by `scripts/throttle-verify.sh`. | What the real app does with **no accounts**: launch, menu bar label, empty state, detail window, Add account choices up to the browser, Settings and its development-build restrictions, Quit. |
| **Hosted view** | `PopupSnapshotTests` and its extensions render the real SwiftUI views from fixture accounts to PNG. | How the views draw **with accounts**: rows, usage bars and colors, menu bar labels, reset counts by kind, the reset confirmation and its results. |

A hosted-view PNG is never a live proof. It shows the view given a state; it does
not show that the app reaches that state. Adding a real account needs a provider
sign-in in a browser, which a verification run never does, and the app has no
fake-provider path by design.

All commands below run from the repository root. The helper is
`.claude/skills/verify-throttle/scripts/throttle-verify.sh`; with no arguments it
prints its usage.

## Launch

**One-time permissions**, granted to the app that hosts your shell (Terminal,
iTerm, an editor, or an agent host), not to Throttle:

1. **Accessibility**: System Settings › Privacy & Security › Accessibility, turn
   the host app on. Required. Without it nothing can be clicked or read.
2. **Automation › System Events**: macOS asks once, the first time the host app
   runs `osascript` against System Events. Answer Allow. If it was denied, turn
   it on under System Settings › Privacy & Security › Automation.
3. **Screen Recording** (optional): System Settings › Privacy & Security ›
   Screen & System Audio Recording. Only needed for PNGs of the live window.
   Without it the drives still run and the element records are the evidence.

These are the owner's decisions. An agent never opens these panes to change them
and never runs anything meant to trigger the prompts; it reports what Doctor says
is missing.

**Build and start:**

```bash
.claude/skills/verify-throttle/scripts/throttle-verify.sh build    # ~1 min cold, Debug, build/verify/DerivedData
.claude/skills/verify-throttle/scripts/throttle-verify.sh launch
```

`launch` refuses unless the built bundle's identifier is `ai.parslee.throttle.dev`,
refuses if an instance from this checkout is already running, records the pid in
`build/verify/run/pid`, and returns once the menu bar item answers through
Accessibility (ready). Output: `launched pid <pid>; evidence in <folder>`.

Why only a Debug build: it is a separate app to macOS, with its own data folder
(`~/Library/Application Support/Throttle Dev`), its own Keychain service and its
own settings, starts with no accounts, never launches at login and never updates
itself. A Release build shares the installed app's real accounts and tokens. The
helper never launches, drives, quits or relaunches `/Applications/Throttle.app`,
which is usually running on a developer's Mac, and nothing here reads the
Keychain or the release's data folder.

Teardown is **Cleanup** below.

## Doctor

Run before the first drive and whenever anything looks off. Read-only.

```bash
.claude/skills/verify-throttle/scripts/throttle-verify.sh doctor
```

It exits 0 only when every `ok` line holds:

- the recorded pid is alive and its executable is this checkout's
  `build/verify/DerivedData/Build/Products/Debug/Throttle.app/Contents/MacOS/Throttle`;
- the bundle on disk is `ai.parslee.throttle.dev`;
- Accessibility is granted to the host app (`AXIsProcessTrusted`, no prompt);
- System Events reports that pid's bundle identifier as `ai.parslee.throttle.dev`;
- the menu bar item answers and prints its text.

It also prints `note` lines: whether Screen Recording is granted, and the pids of
any other Throttle (the installed app), which the helper never touches.
`FAIL Accessibility …` means permission 1 above is missing; a hang or an error
naming System Events means permission 2.

## Drive

Each command opens the detail window, acts, records, and closes the window
inside one `osascript` call, because the window closes the moment Throttle stops
being the active app, which happens between calls.

```bash
S=.claude/skills/verify-throttle/scripts/throttle-verify.sh
$S label                 # menu bar item text, e.g. "Throttle · add account"
$S window   empty-state  # every element of the detail window -> empty-state.txt (+ .png)
$S add-menu add-account  # Add account's providers and their items; cancels the menu
$S settings settings     # opens Settings, records it, presses Done
$S quit-ui               # clicks Quit, confirms the pid exited
$S ax 'get title of menu bar item 1 of menu bar 2'   # one raw AppleScript statement
```

Stable handles, from `Sources/Throttle/UI/`:

- Menu bar item: `menu bar item 1 of menu bar 2` of the process; its `title` is
  the label text (`Throttle · add account` with no accounts).
- Detail window: `group 1 of window 1`. Header text `Throttle`, menu button
  `Add account`, empty state `No accounts yet`, footer `Not updated yet`.
- Footer buttons have no accessible name; address them by `help`: `Settings`,
  `Quit Throttle`, and the update button's `Not available in a development
  build` (disabled in Debug). `Refresh all` has neither and sits between them.
- Settings opens inside the window as `group 1 of group 1 of window 1`: text
  `Settings`, two sliders (`Check usage every`, `Rotate menu bar every`), a
  `Launch at login` checkbox (disabled in Debug, with the text `Not available in a
  development build`), `Reveal diagnostics log` (help text), and Done as the
  last button.

Feature recipes are in [features/README.md](features/README.md).

**Hosted-view route** (no live app, no permissions):

```bash
.claude/skills/verify-throttle/scripts/throttle-verify.sh snapshots            # -> <evidence>/snapshots/
.claude/skills/verify-throttle/scripts/throttle-verify.sh snapshots <folder>
```

This runs `xcodebuild test -only-testing:ThrottleTests/PopupSnapshotTests` (which
includes its reset-kinds and development-build extensions) with
`TEST_RUNNER_THROTTLE_SNAPSHOT_DIR` set, so every render is also written as a PNG,
dark and light. About two minutes with a warm build. It fails if the test host is
left running. The PNG names map to features in each feature file.

## Evidence

Evidence goes to `$THROTTLE_VERIFY_OUT` when set, otherwise to
`build/verify/evidence/<launch time>/` (git-ignored). `launch` fixes the folder for
the run; later commands reuse it. Set `THROTTLE_VERIFY_OUT` to a folder outside
the checkout when the checkout is temporary.

| File | From | Contents |
| --- | --- | --- |
| `<name>.txt` | `window`, `add-menu`, `settings` | One line per element: role, name, value, help, enabled; ends with `windows open at end: 0`. |
| `<name>.png` | same, when Screen Recording is granted | The app's own window only (`screencapture -l <window id>`), never the screen around it. |
| `app-stdout.log` | `launch` | The app's standard output and error. |
| `snapshots/*.png`, `snapshots/*-help.txt` | `snapshots` | Hosted-view renders and the tooltips a PNG cannot show. |
| `snapshots/xcodebuild-test.log` | `snapshots` | The test run. |

Proof standards:

- Drive the real user path: the menu bar item, the window's own controls. No
  internal setters, no test-only entry points in the live route (there are none).
- Record the action and the resulting state: each record ends with the state
  after the action (`menu open after cancel: false`, `settings open after Done:
  false`, `windows open at end: 0`), and `quit-ui` checks the process exited.
- Name the route in every claim. A row, a bar, a reset count or a rotation is
  proven only by the hosted-view route plus the unit tests named in its feature
  file, and is reported that way.
- Never capture the full screen, and never commit evidence. A real account's
  email or numbers must never appear in a screenshot: the live route has no
  accounts, and the hosted route uses invented `@example.com` accounts.

## Cleanup

```bash
.claude/skills/verify-throttle/scripts/throttle-verify.sh cleanup
```

Stops the pid recorded by `launch` (only after checking its executable is this
checkout's Debug build), removes `build/verify/run/`, and confirms no Debug
Throttle from this checkout is running. It never stops anything by name and never
touches the installed app. It keeps the evidence folder. Run it after every run,
including failed ones. If it reports a Debug instance it did not start, stop that
pid yourself after checking `ps -o comm= -p <pid>`.

After `scripts/test.sh` or `snapshots`, also check no test host is left:
`pgrep -x Throttle`, then `ps -o comm= -p <pid>` for each; a path ending
`build/DerivedData/Build/Products/Debug/Throttle.app/Contents/MacOS/Throttle` is a
leftover test host.

## Helpers

`.claude/skills/verify-throttle/scripts/throttle-verify.sh` is bash plus tools
that ship with macOS (`osascript`, `screencapture`, `perl`, `PlistBuddy`,
`xcodebuild`); nothing is installed. Commands: `build`, `launch`, `doctor`,
`label`, `window <name>`, `add-menu <name>`, `settings <name>`, `quit-ui`,
`snapshots [dir]`, `cleanup`, `ax '<applescript>'`. Every Accessibility call is
bounded by `THROTTLE_VERIFY_AX_TIMEOUT` seconds (default 20).

Rules the helper follows, which any new drive must keep:

- **Address the pid, never the name.** Every call is `tell (first process whose
  unix id is <pid>)`. The installed app is also a process named `Throttle`, and
  `pgrep -f Throttle` also matches unrelated apps whose arguments contain the
  word.
- **Never store a UI element in an AppleScript variable.** System Events turns a
  stored reference into `application process "Throttle"`, which can resolve to
  the installed app. Write each specifier out from `window 1` or `menu bar 2`
  every time, as `DUMP` in the script does.
- **Never choose an Add account item.** Every leaf opens a real sign-in in the
  browser or reads another tool's login from disk.
- **Open menus without waiting.** A click on a menu button blocks while the
  menu tracks; wrap it in `ignoring application responses`. Do not wrap a
  `whose` lookup that way: it needs the reply (this is why `quit-ui` uses
  `try` instead).
