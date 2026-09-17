# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

Throttle is a native macOS menu bar app that reads subscription usage limits for
Claude and Codex accounts and shows them at a glance. It is read-only against
both providers: it never sends a prompt and never spends quota to learn quota.

Swift 6 language mode, SwiftUI, `MenuBarExtra`, macOS 14 minimum. Bundle
identifier `ai.parslee.throttle`, `LSUIElement` true, so there is no Dock icon
and no main window. There are no third-party dependencies and none may be added.

## Commands

```bash
scripts/build.sh            # Release build -> build/Throttle.app
scripts/test.sh             # xcodebuild test on platform=macOS
scripts/package.sh          # productbuild -> build/Throttle-<version>.pkg
scripts/release.sh <ver>    # tag, build, sign, notarize, staple, gh release
```

`scripts/release.sh` is the only release entry point. It pulls the Developer ID
identities and notary credentials from Azure Key Vault into a scratch keychain
that is deleted on exit, then publishes the `.pkg` to GitHub Releases. Signing
material never lands in the repo or in GitHub secrets.

All scripts are bash. No other scripting runtime is permitted under `scripts/`
or `.github/`. CI (`.github/workflows/ci.yml`) runs build and test only.

## Layout

```
Sources/Throttle/App/        @main entry point and app-level wiring
Sources/Throttle/Models/     Account, AccountStatus, UsageWindow, Provider, Redactor
Sources/Throttle/Providers/  UsageProvider protocol and one adapter per vendor
Sources/Throttle/Store/      Keychain wrapper and the non-secret account store
Sources/Throttle/Polling/    PollScheduler and backoff policy
Sources/Throttle/UI/         Menu bar label and detail window
Tests/ThrottleTests/         Unit tests
Tests/Fixtures/              Captured provider payloads, secrets redacted
```

Both targets use file-system-synchronized groups, so adding a Swift file to a
directory under `Sources/Throttle` or `Tests/ThrottleTests` puts it in the build
with no change to `Throttle.xcodeproj`. Do not hand-edit the pbxproj to add
sources.

## Provider adapter architecture

Every vendor difference lives behind one protocol, `UsageProvider`. An adapter
owns its endpoint, its headers, its payload shape, its lane naming, and its
token refresh mechanics. It hands back an `AccountStatus`, which is the only
shape the polling engine and the UI ever see.

Rules that hold this seam in place:

- Nothing under `UI/` may name a vendor, an endpoint, or a payload key. The UI
  reads `Account`, `AccountStatus`, `UsageWindow`, and `Provider` only.
- Window labels are derived from the reported window length, never hardcoded.
  Providers have switched individual lanes off with no warning, and a hardcoded
  lane name turns that into a crash or a blank row.
- Model-scoped windows take their label from the payload's own display name.
  Never hardcode a model name.
- Adding a third provider means a new case on `Provider` and a new file under
  `Providers/`. If it needs anything else, the seam has leaked.

## Token handling

Tokens are the part of this app that can hurt a user, so the rules are strict.

- **Keychain only.** Access tokens, refresh tokens, expiry, and the provider
  account id live in the Keychain under service `ai.parslee.throttle`, keyed by
  the account UUID. They never go in a plist, in `accounts.json`, in
  UserDefaults, in a log, or in a crash report. `Account` is the non-secret
  record and a unit test fails the build if a token-shaped key appears in it.
- **One store, never two.** Throttle owns its own login and its own Keychain
  items. It does not read or write another app's credentials outside the
  explicit, user-initiated import, which copies once and never writes back. Two
  stores racing on a token rotation is what bricks accounts.
- **Refresh is serialized per account.** Two concurrent fetches for one account
  must produce exactly one refresh request.
- **A refresh in flight is never cancelled.** The refresh task ignores the poll
  cycle's cancellation. A half-applied rotation invalidates the refresh token
  and locks the user out of an account that was working a second earlier.
- **Write the rotated pair back before anything else uses it.**
- **A failed refresh flips the account to `needsLogin` and keeps the row.** It
  never deletes the account and never shows stale numbers as if they were live.
- **Everything user-visible passes through `Redactor`.** Error strings can echo
  a request, and a request carries a bearer token.

## Polling cadence

Five minutes per account by default, configurable but never under 60 seconds.
Requests to one provider are staggered. A 429 or 5xx arms exponential backoff
that honors `Retry-After`, up to 60 minutes; the Claude usage endpoint has been
seen returning a one-hour `Retry-After` after a single call following a quiet
period, so last-good data is always served with its age rather than refetched
aggressively. Poll cycles are single-flight: a cycle that starts while one is
running is skipped, not queued.

The menu bar rotation timer reads cached data only. It must never trigger a
network request, and a test asserts that.

## Repo hygiene

This repository is public. Nothing operator-specific belongs in it: no account
email, no account id, no token, no personal home path, no screenshot of a real
account. Accounts are added at runtime through the app, always.
