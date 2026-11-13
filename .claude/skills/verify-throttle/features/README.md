# Throttle verification map

This folder is the maintained source for verifying what a Throttle user sees and
does. Read this index, run the launch and doctor steps in `../SKILL.md`, then use
the matching feature file as the recipe.

## Baseline preconditions

- A Debug build from this checkout is running, started by
  `.claude/skills/verify-throttle/scripts/throttle-verify.sh launch`.
- `throttle-verify.sh doctor` exits 0 and names that pid and
  `ai.parslee.throttle.dev`.
- The Debug build has no accounts. A fresh checkout's Debug build starts empty;
  if `label` shows anything other than `Throttle · add account`, someone added an
  account to this Debug identity by hand, and the live recipes below no longer
  describe it. Report that rather than removing the account.
- Never drive an instance this run did not start, and never the installed app.

## Driving conventions

- Write `S=.claude/skills/verify-throttle/scripts/throttle-verify.sh` and run
  every command from the repository root.
- Live drives go through `$S window|add-menu|settings|quit-ui|label` or a raw
  `$S ax '<statement>'`. Each opens the detail window, acts and closes it in one
  call.
- Address controls by their visible text or `help`, never by screen position.
- Never choose an item under Add account. Never change a Settings slider: the
  values persist in the Debug identity's settings.
- Hosted-view proofs come from `$S snapshots`, which writes PNGs named in each
  feature file.

## Proof and skip reporting

- Every claim names its route: **live** or **hosted view**.
- Live proof is the element record (`<name>.txt`) and, when Screen Recording is
  granted, the window PNG of the same name.
- Hosted-view proof is the named PNGs (dark and light) plus the unit tests named
  in the feature file, which assert the behavior the PNG only shows.
- A state that needs accounts is never reported as live-verified. Report it as
  "hosted view only" and say why.
- Report an entry point that could not be reached with the command and the unmet
  precondition. Do not report it as verified through another path.

## Feature entry contract

Each feature file starts with an H1 title and one paragraph describing the
user-visible behavior, then exactly four H2 sections in this order:
`Sub-features`, `How to get to it (user POV)`, `Driving it with throttle-verify`,
and `Gotchas`. The driving section starts with `Preconditions:` and pairs each
user action with an exact command and the observable result.

## Features

- [Menu bar label and rotation](./menu-bar-label.md): the label, its colors, and the ten-second rotation through accounts.
- [Detail window: account rows and usage bars](./detail-window.md): the empty state live; rows, bars and states in the hosted view.
- [Add an account](./add-account.md): the provider choices up to the point a browser would open.
- [Banked resets by kind](./banked-resets.md): counts per kind, the Use reset button, the confirmation and its results.
- [Settings and quitting](./settings.md): intervals, the development-build restrictions, Done, and Quit.
