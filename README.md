# Throttle

A macOS menu bar app that shows how much of your Claude and Codex subscription
limits you have left, across every account you own, at a glance.

Both providers meter usage in rolling windows. Claude has a 5-hour session
window, a weekly window, and a separate weekly window per top-tier model. Codex
has a 5-hour window and a weekly window, plus occasional extra lanes. Today the
only way to read any of them is to open a session logged in to that one account.
Throttle reads them all and keeps them in the menu bar.

The bar shows one account at a time: the provider glyph, the account's number,
and each window as a short tag with the percent left, such as
`1: 5h 100% / WK 89% / FB 79%`. A window reads green, turns yellow at 20 % left
or less, and red when nothing is left. The bar rotates to the next account every
ten seconds, counting through the same numbers the window shows. Clicking opens
a window that lists every account, grouped by provider and numbered, with a
column per window: its name, the percent left, a bar, and when it resets. The
window follows the system's light or dark appearance. Double-click an account's
name, or choose **Rename…** from its menu, to give it a name of your own.

Throttle is read-only. It never sends a prompt, spends a token, or changes
anything on your account.

## Install

Download the latest `.pkg` from the
[Releases page](https://github.com/Parslee-ai/throttle/releases) and install it.
Throttle installs to `/Applications` and runs as a menu bar item with no Dock
icon and no main window.

### Notarized release

Double-click the `.pkg` and follow the installer. macOS verifies the signature
and notarization with Apple, and nothing else is needed.

### Unsigned release

Releases that are not signed need the quarantine flag cleared before macOS will
run them. Right-click → Open no longer works for this on macOS 15 and later, so
run these two commands instead:

```bash
xattr -dr com.apple.quarantine ~/Downloads/Throttle-<version>.pkg
sudo installer -pkg ~/Downloads/Throttle-<version>.pkg -target /
xattr -dr com.apple.quarantine /Applications/Throttle.app
```

Release notes say which kind of build a given release is.

## Adding accounts

Click the menu bar item, then **Add account**, and choose **Claude** or
**Codex**. Throttle opens that provider's real login page in your default
browser. Sign in there, approve the request, and the account appears in the
list. There is no embedded web view and no password is ever typed into Throttle.

You log in once per account. Throttle stores the resulting tokens in your
macOS Keychain and refreshes them on its own from then on. If a refresh ever
fails, the account stays in the list and shows a **Log in again** button rather
than disappearing or showing stale numbers as if they were current.

Add as many accounts as you like, from either provider or both. Accounts are
grouped by provider; within a provider the order is yours to set by dragging
rows, and the menu bar rotates in that same order.

## What Throttle reads

Throttle calls exactly two usage endpoints, once per account per poll:

| Provider | Endpoint |
| --- | --- |
| Claude | `https://api.anthropic.com/api/oauth/usage` |
| Codex | `https://chatgpt.com/backend-api/wham/usage` |

**Both endpoints are undocumented.** Neither vendor publishes them, supports
them, or promises they will keep working. They can change shape or disappear
without notice, and if that happens Throttle will show an error on the affected
accounts until it is updated. This is the tradeoff for reading subscription
usage at all: there is no official API for it.

Throttle polls every five minutes per account by default, never faster than
once a minute, and backs off when a provider asks it to. The ten-second menu bar
rotation reads cached data and never triggers a network request.

Nothing leaves your Mac except those two requests and the OAuth token exchanges.
There is no analytics, no crash reporting, and no update check.

## Building from source

Requires Xcode 26 or later and macOS 14 or later.

```bash
scripts/build.sh   # Release build -> build/Throttle.app
scripts/test.sh    # unit tests
```

There are no third-party dependencies. Everything is Apple frameworks.

## License

MIT. See [LICENSE](LICENSE).
