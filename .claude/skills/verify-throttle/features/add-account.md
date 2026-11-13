# Add an account

`Add account` in the detail window's header is a menu with one submenu per
provider, `Claude` and `Codex`. Each offers `Log in with browser`, Claude also
`Paste code instead…`, and, when the matching command-line tool's login exists on
this Mac, `Import from Claude Code…` or `Import from Codex CLI…`. A login opens the
provider's real page in the default browser and shows a card in the window until
the sign-in finishes; nothing is typed into Throttle.

## Sub-features

- `add-menu` lists one submenu per provider.
- `add-items` lists the browser login, the paste-code login (Claude), and an
  import item when its source exists.
- `add-login-card` shows the waiting card while the browser sign-in runs.
- `add-import` copies another tool's login once, only when the user picks it.

## How to get to it (user POV)

- Click the menu bar item, then `Add account`, then a provider.

## Driving it with throttle-verify

Preconditions:

- Baseline preconditions from `README.md`; doctor exits 0.

- **List the choices (live).** Open the menu and read it without choosing. Run
  `$S add-menu add-account`. `add-account.txt` reads
  `Add account: Claude | Codex`, then
  `Claude: Log in with browser | Paste code instead… | missing value | Import from Claude Code…`
  and `Codex: Log in with browser | missing value | Import from Codex CLI…`
  (`missing value` is the divider), then `menu open after cancel: false` and
  `windows open at end: 0`.
- **Login card (hosted view).** Run `$S snapshots`. `panel-login-dark.png` and
  `panel-login-light.png` show the waiting card inside the window.
- **Proof.** The `add-account.txt` record; the login-card PNGs;
  `AnthropicLoginTests` and the other `Tests/ThrottleTests/Auth` tests for the
  sign-in itself.

## Gotchas

- Never choose any item. Each login opens a real provider page in the browser,
  and each import reads another tool's saved login from disk. A verification run
  does neither, so the end of a sign-in and the new row are not verifiable live.
- The import items appear only when that tool's login file exists on the Mac
  running the check. Their absence on another machine is correct, not a failure.
- Clicking the menu button blocks while the menu is open. The helper clicks it
  under `ignoring application responses`, reads the items, then cancels with
  `AXCancel`.
