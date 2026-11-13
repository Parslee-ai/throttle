# Detail window: account rows and usage bars

Clicking the menu bar item opens a 1000-point-wide window headed `Throttle` with
an `Add account` menu. With no accounts it says `No accounts yet` and explains how
to add one. With accounts it lists them grouped by provider and numbered, each row
with a column per window: its name, the percent left, a bar, and when it resets,
plus the plan, an actions menu, and a state when something is wrong (signed out,
rate limited, error, stale). The footer shows when it last updated and holds the
update button, `Refresh all`, Settings and Quit. It follows light and dark mode.

## Sub-features

- `window-open` opens from the menu bar item and closes when Throttle loses focus.
- `window-empty` shows the empty state and `Not updated yet` with no accounts.
- `window-footer` shows the update button (disabled in Debug), Refresh all,
  Settings and Quit.
- `window-rows` groups accounts by provider, numbers them, and draws one column
  per reported window.
- `window-bars` colors each bar and percent by band, and shows the reset time.
- `window-states` shows signed-out, forbidden, rate-limited, error and stale rows.

## How to get to it (user POV)

- Click the Throttle item in the menu bar.

## Driving it with throttle-verify

Preconditions:

- Baseline preconditions from `README.md`; doctor exits 0.

- **Open and record (live).** Click the item. Run `$S window empty-state`.
  `empty-state.txt` lists `AXStaticText | name=Throttle`,
  `AXMenuButton | name=Add account`, `name=No accounts yet`, the sentence that
  starts `Use “Add account”`, `name=Not updated yet`, and four buttons whose help
  is `Not available in a development build` (enabled=false), none (Refresh all),
  `Settings`, `Quit Throttle`. It ends `windows open at end: 0`. With Screen
  Recording granted, `empty-state.png` shows the same window.
- **Rows, bars and states (hosted view).** Run `$S snapshots`. Check:
  `popup-dark.png` / `popup-light.png` (five Claude and three Codex accounts,
  grouped and numbered), `popup-states-*` (stale, signed out, forbidden, rate
  limited, error), `popup-wrap-*` (more windows than fit, lanes),
  `popup-claude-above-codex-*` and `popup-parsed-claude-*` (real parsed payloads
  share the first column), `popup-eight-*` and `popup-scrolling-*` (long lists),
  `panel-development-*` (the Debug footer).
- **Proof.** The live record and PNG for the empty state; the named hosted PNGs
  for rows. `ColorsTests`, `FormattingTests` and `AccountOrderTests` assert the
  bands, labels and order the PNGs show.

## Gotchas

- The window closes as soon as another app becomes active, including between two
  `osascript` calls. Open, act and record in one call, as the helper does.
- Footer buttons have no accessible name. Use `help`; `Refresh all` has none.
- A Settings panel left open stays open the next time the window opens. The
  helper dismisses it first and notes that in the record.
- `Refresh all` with no accounts sends nothing, but with accounts it reads every
  provider. Do not click it on an instance that has accounts.
