# Settings and quitting

The gear button in the detail window's footer opens Settings inside the window:
`Check usage every` (1 to 30 minutes, default 5), `Rotate menu bar every`
(seconds, default 10), `Launch at login`, `Reveal diagnostics log`, and `Done`. In
a development build `Launch at login` is disabled with the note `Not available in
a development build`, and the footer's update button is disabled with the same
tooltip. `Quit` in the footer ends the app.

## Sub-features

- `settings-open` opens Settings over the window and `Done` closes it.
- `settings-values` shows the current poll and rotation intervals.
- `settings-dev-login` disables Launch at login in a development build and says
  why.
- `settings-dev-update` disables Check for Updates in a development build and
  says why.
- `quit` ends the process from the footer's Quit button.

## How to get to it (user POV)

- Click the menu bar item, then the gear button at the bottom right.
- Click `Quit` at the bottom right, or press Command-Q while the window is open.

## Driving it with throttle-verify

Preconditions:

- Baseline preconditions from `README.md`; doctor exits 0.

- **Open and read Settings (live).** Run `$S settings settings`. `settings.txt`
  lists, under `1 AXGroup`: `name=Settings`, `name=Check usage every`,
  `name=5 min`, an `AXSlider` with `value=5.0`, `name=Rotate menu bar every`,
  `name=10 s`, an `AXSlider` with `value=10.0`, an `AXCheckBox` with
  `enabled=false`, `name=Not available in a development build`, and two buttons.
  It ends `settings open after Done: false` and `windows open at end: 0`. With
  Screen Recording granted, `settings.png` shows the panel.
- **Update button disabled (live).** Run `$S window footer`. `footer.txt` has an
  `AXButton` with `help=Not available in a development build | enabled=false`.
- **Quit (live).** Run `$S quit-ui`. Output is `pid <pid> exited through the Quit
  button`. Then run `$S cleanup`.
- **Hosted view.** `$S snapshots` writes `settings-development-dark.png` and
  `settings-development-light.png`.
- **Proof.** The two records, the PNGs, and the `quit-ui` line. `AppSettingsTests`
  covers the interval limits.

## Gotchas

- Do not move a slider: the value persists in the Debug identity's settings and
  changes every later run's baseline. `AppSettingsTests` covers the limits.
- Do not click `Reveal diagnostics log`; it opens a Finder window on the owner's
  screen.
- Done has no accessible name. It is the last button of
  `group 1 of group 1 of window 1`.
- Settings stays open across closing and reopening the window. The helper closes
  it with Done, and every drive dismisses one left open.
- Launch at login and updates are enabled in a Release build, which this skill
  never runs. Their enabled behavior is not verifiable here.
