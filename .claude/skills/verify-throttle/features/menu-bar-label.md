# Menu bar label and rotation

The menu bar item shows one account at a time as the provider glyph, the
account's number, and a short tag with the percent left for each window, such as
`1: WK 89% / FB 79%`. Each window reads green, yellow at 20 % left or less, and
red at 0 %. Every ten seconds (configurable) it moves to the next account in the
detail window's order and wraps; hovering pauses it. With no accounts it reads
`Throttle · add account`. Rotation reads cached data only and never fetches.

## Sub-features

- `label-empty` shows `Throttle · add account` when there are no accounts.
- `label-format` draws glyph, number and one tag per window, with band colors.
- `label-rotate` advances one account per interval in display order and wraps.
- `label-pause` holds the current account while the pointer is over the item.
- `label-no-fetch` never makes a network request from a rotation tick.

## How to get to it (user POV)

- Look at the menu bar after launching Throttle.
- Hover the item to pause the rotation.
- Settings › Rotate menu bar every changes the interval.

## Driving it with throttle-verify

Preconditions:

- Baseline preconditions from `README.md`; doctor exits 0.

- **Empty label (live).** Read the item. Run `$S label`. Output is exactly
  `Throttle · add account`.
- **Label format and colors (hosted view).** Render the labels. Run
  `$S snapshots`. `menubar-dark.png` and `menubar-light.png` show labels for
  fixture accounts with green, yellow and red tags, dimmed stale labels, and
  state markers. `MenuBarImageTests` asserts the colors and that 0 % is red.
- **Rotation order, wrap and pause (unit tests).** Run `scripts/test.sh` and
  check `RotationControllerTests` passes: `testAdvancesInOrderAndWraps`,
  `testPauseHoldsTheCurrentAccountAndResumesOnNextTick`,
  `testTimerTicksOnTheConfiguredInterval`, `testOneHundredTicksIssueNoFetch`.
  `AccountOrderTests.testBarNumberMatchesPopupNumberThroughARotation` proves the
  bar's number matches the window's.
- **Proof.** Keep the `label` output in the run notes, plus the two menubar PNGs
  and the test result lines.

## Gotchas

- The live route cannot show rotation or a populated label: that needs at least
  two accounts, and accounts need a real browser sign-in. Report these as hosted
  view and unit tests, never live.
- On a crowded menu bar the item can sit under the active app's menus. It still
  answers and clicks through Accessibility, but a screen region at its position
  shows another app's menu titles, so the helper never screenshots the menu bar.
- The label is drawn as one image; its text for Accessibility is the item's
  `title`. Colors are only visible in the hosted-view PNGs.
