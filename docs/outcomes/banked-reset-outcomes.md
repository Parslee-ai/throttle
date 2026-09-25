# Banked reset: outcomes

Using a banked usage-limit reset from Throttle's detail window, for Codex and Claude accounts, through the providers' own first-party channels.

## Who uses this and how each outcome is confirmed

| Who | Surface | Confirmed by |
|---|---|---|
| The account owner | The detail window | The real running app on screen (screenshot, or frame-scrub for motion) for every state a live account can show without spending a credit: the button, its enabled and greyed-out states, the confirmation, nothing-to-reset. States that need a real spend or a rare server answer (success, the animation, already-used, cooldown, no-credit, not-available, provider error, couldn't-reach) are proven on the real SwiftUI views rendered to PNG by the snapshot tests, opened and read; the animation as frames at fixed progress 0, 0.25, 0.5, 0.75, 1. Unit tests and reads of view structure do not close these outcomes. |
| The machine | The provider adapters, the scheduler, the status cache | Named unit tests against a stub HTTP client and captured fixtures, and literal command output. |
| Shipping it | The branch, the build, the first real use | Suite exit code, the built app's version, one real click on a real account. |

Settled wording rule: when an adapter outcome and a window outcome name the same message, the window's wording (group A) is the one shipped.

## A. Using a banked reset from the detail window

Channel: the real running app, screenshot or frame-scrub.

### Where the control is and when it can be used

- A row that shows a "Manual resets" column shows a **Use reset** button on the same line as "N available", inside the same fixed-width column; the row does not get wider, and at rest (no message, no reset running) it is exactly as tall as the same row in v0.2.0.
- The button appears on Codex rows and on Claude rows whenever that account's provider reports a reset count.
- With a count of 0 the column still reads "0 available", and the button is visible, greyed out, and cannot be clicked; hovering it says "No resets available".
- A row whose provider reports no count (a Claude account outside the reset program, or a row waiting for its first update) shows no "Manual resets" column and no button, exactly as today.
- Rows that never had resets keep the same columns, order, spacing, bar widths and colors as today's build: a before/after screenshot of such a row shows no difference.
- When the row is dimmed or stale (needs sign-in, wrong sign-in type, error, or a reading older than the stale threshold) the button is greyed out, and hovering says "Refresh this account first".
- While a reset runs on one row, only that row's button is locked; other rows' buttons still work.
- The row's "…" actions menu and its right-click menu gain a "Use reset…" item, enabled and disabled by the same rules as the button.

### Confirming

- Clicking **Use reset** always opens a confirmation first; nothing is spent before the user confirms.
- The confirmation names the account by its row name and how many resets it holds (for example "Use 1 of 2 resets for work@…?") and says a reset cannot be undone.
- The confirmation lists each window's current "% left", so spending a reset while a window still has room is a visible choice.
- The confirmation has "Use reset" and "Cancel"; Cancel is the default, so Escape or Return alone spends nothing.
- Cancel leaves the row exactly as it was: same count, same bars, no message.

### While it runs

- After confirming, the button gives way to a small spinner reading "Resetting…" on the column's third line (where a window column shows its reset time); the rest of the row stays readable and does not shift sideways. A result message takes the same third line, at most two lines long, with the full text in its tooltip.
- The row's other actions (Refresh, Rename, Move, Sign in again, Remove) still open during the run, and none of them cancels it.
- Closing the detail window during a run does not cancel it; reopening shows the finished result on the row.
- A second click on the locked button during a run does nothing, and no second confirmation appears.

### Success

- On success, every bar the reset cleared ends at the provider's fresh reading, normally 100% left, and the fill **slides** from its old width to the new one: a frame-scrub shows at least three in-between widths, not a single jump.
- As each bar fills, its percentage text reaches the new value and its color moves to the matching band.
- The "N available" count shows the provider's fresh count, which after a normal reset is one lower ("2 available" becomes "1 available"); Throttle never subtracts one itself, so if the provider lags, the row shows exactly what the provider reported.
- The numbers the row settles on are the provider's own reading fetched right after the reset, never a guess; a window the provider reports as only partly cleared stops at that level.
- A window the reset did not clear keeps its bar and percentage (a reset that clears only the 5-hour window leaves the weekly bar where it was).
- Each cleared window's reset-time line shows the provider's new reset time.
- A short note, "Reset used — limits refreshed", appears on that row and fades after a few seconds.
- If the reading right after a successful reset fails, the row still says "Reset used — limits refreshed", and the bars keep their last reading, shown with its age, until the next poll brings fresh numbers. Nothing is invented.
- The footer's "Updated" time moves to the time of the fresh reading.
- When the menu bar rotation next lands on that account, the label shows the refreshed percentages.
- When the count reaches 0, the column reads "0 available" and the button greys out.

### When it does not work

In every case below the bars and the count stay where they were unless the provider's own fresh reading says otherwise.

- **Nothing to reset:** the row shows "Nothing to reset right now — your reset was not used"; the count is unchanged.
- **No credit left:** the row shows "No resets available" and the count shows the provider's fresh number (0).
- **Already used (same attempt already went through):** treated as success; bars move to the fresh reading and the count shows the provider's number; the count never drops twice.
- **Cooldown:** the row shows "Reset on cooldown until <time>" in the app's clock format; the count is unchanged.
- **Ineligible or unavailable:** the row shows "Resets aren't available for this account right now"; the count is unchanged. Provider reason codes are never shown.
- **Rate limited:** the row shows "<Provider> is limiting requests — try again at <time>"; nothing is spent.
- **Needs sign-in:** the row switches to its existing "Sign in again" state with the "Log in again" button; it is not deleted and shows its last good numbers dimmed.
- **Network failure or timeout:** the row shows "Couldn't reach <Provider> — check your connection and try again"; clicking **Use reset** again while the app stays open retries the same attempt, so a reset that did go through is never spent twice.
- **Provider error:** a 5xx may arrive after the provider already spent, so it shows "<Provider> had a problem (HTTP N). Try again — a retry never spends a second reset." and re-reads that account; any other non-2xx shows "<Provider> couldn't use the reset (HTTP N). Nothing was changed."
- **Unknown answer:** the row shows "Unexpected answer from <Provider>" and never claims success; the count shows the provider's fresh number.
- No message on screen ever contains a token, a bearer header, an account id, or a raw response body.
- Each message can be closed with a close control, or is replaced by using the button again; closing it leaves the row as it was.
- A failure on one row never changes another row's bars, count or messages.

### Many accounts

- With two Codex rows and one Claude row holding resets, using a reset on one row changes only that row's bars and count.
- Two resets started back to back on two different rows both finish, each showing its own result.

### Keyboard and VoiceOver

- **Use reset** is reachable with Tab and pressable with Space; the confirmation can be answered from the keyboard alone, and Cancel has focus when it opens.
- VoiceOver reads the button as "Use reset for <row name>, N available", reads the greyed-out button as dimmed with its reason, and announces each result.

## B. Codex reset: the machine side

Channel: named unit tests against a stub HTTP client and captured fixtures.

### B1. The request

- Spending a reset sends exactly one `POST` to `https://chatgpt.com/backend-api/wham/rate-limit-reset-credits/consume`.
- The request carries `Authorization: Bearer <access token>`, `chatgpt-account-id` when the credential has one, `Content-Type: application/json`, `Accept: application/json`, and the same `User-Agent` as the usage read.
- The body is JSON with a `redeem_request_id` that is a fresh UUID string, and no `credit_id` key, so the provider picks the credit.
- Each new user attempt uses a new `redeem_request_id`; a retry of the same attempt (a transport error, or a token refresh followed by a resend) reuses it. A test forcing 401 then 200 sees the same id in both bodies.
- A full poll cycle against the stub records no request to `/consume`: polling never spends.
- The comments in `OpenAIEndpoints` and `OpenAIProvider` that say nothing spends credits are rewritten to say the one spending URL exists and is used only on an explicit user action.

### B2. Tokens

- The reset gets its credential from the same per-account `TokenRefresher` the poller uses; an expired token is refreshed first (recorded order: token endpoint, then consume).
- A poll and a reset for one account that both need a refresh at the same moment produce exactly one token request.
- Cancelling the reset caller after a refresh has started does not cancel the refresh; the rotated credential is still written back to the Keychain.
- A 401 on consume triggers one refresh and one resend with the same `redeem_request_id`; a second 401 ends the attempt as sign-in-again and flips the account to `needsLogin`. Consume is never sent a third time.
- A refresh that fails during a reset flips the account to `needsLogin` and keeps the row.

### B3. What each answer becomes

- 200 `reset` becomes success and triggers exactly one immediate usage read, for that account only.
- After success, the cached status holds the numbers from that fresh read: a fixture with 0% used and `available_count` 0 yields 100% remaining and count 0.
- If the fresh read fails (429, 5xx, transport), the result is still success and the cache keeps its last good reading; nothing is invented.
- 200 `nothing_to_reset` becomes the nothing-to-reset result; no forced read; count left alone.
- 200 `no_credit` becomes the no-credit result and triggers one usage read so the count corrects itself.
- 200 `already_redeemed` is treated as success, then one usage read; never an error.
- 200 with an unknown `code`, or a body that will not parse, becomes the unexpected-answer result, never success, and triggers one usage read.
- `windows_reset` is parsed when present, defaults to 0 when missing, and is never used to invent bar values.
- 429 becomes the rate-limited result using `Retry-After` when present, and the poller's backoff for the account is not moved.
- 403 with a permission-type JSON error becomes the redacted provider message; any other 403 becomes sign-in-again.
- 5xx and any other non-2xx become the provider-error result naming the status (tested with 500 and 503).
- A 3xx becomes the redirect/sign-in result, never success.
- A body over the size cap is dropped unread and becomes the unexpected-answer result.
- A transport failure becomes the couldn't-reach result.

### B4. The available count

- The count comes only from `rate_limit_reset_credits.available_count`; `applicable_available_count` never decides whether the button is enabled (fixture `1 / 0` yields 1).
- A missing, null or negative `available_count` yields no count.

### B5. Nothing leaks

- Every user-visible reset message passes through `Redactor`: a 500 whose body echoes `Bearer eyJ…` and `sk-…` shows `[redacted]` and none of the token text.
- Every non-200 consume response writes exactly one diagnostics line of a new kind `reset`, with provider, account id, status and redacted body prefix, and no Authorization header.
- The `redeem_request_id` and the response body are never written to `accounts.json`, UserDefaults, or the status cache.

## D. What must stay as it is

Channel: named tests, greps over the repository, literal command output.

Settled between slices: the usage read after a reset reads **that one account only** (never a whole-cycle refresh) and **honors the provider's current backoff horizon**. When the provider is backed off, no read is sent; the row keeps its last good reading with its age until the horizon passes.

### D1. Polling stays read-only; spending a reset is its own path

- No poll cycle, timer tick, wake, or Refresh ever sends a reset request; a test running several cycles against a stub client finds zero reset requests.
- A reset request is sent only after a person clicks the button and confirms; the cancel path sends nothing (a test counts requests on both paths).
- The forbidden-endpoint test is narrowed on purpose, not deleted: the reset paths may appear only in each provider's endpoints file and its reset call, and `/v1/messages`, `/complete`, `/responses` stay forbidden everywhere. `grep -rn "rate-limit-reset-credits\|reset_rate_limits" Sources/` lists only those files.
- The rotation timer still triggers zero network requests, including while a reset is in flight (100 ticks during a reset, zero requests).
- The eight-accounts-over-an-hour request budget test passes unchanged; the feature adds no background requests.
- Poll cadence, stagger, 60-second floor, single-flight and backoff are unchanged: every existing polling test passes with no assertion edits.
- With the provider under backoff, a completed reset sends no usage read before the horizon.

### D2. The seam holds

- `grep -rniE "openai|anthropic|chatgpt|wham|cedar|consume|reset_rate_limits|grant_id" Sources/Throttle/UI/` returns nothing.
- The reset capability is a `UsageProvider` requirement with a default meaning "not supported"; a test double that does not implement it still builds.
- The UI decides whether to show the button from provider-neutral fields on `AccountStatus` only; `grep -n "\.anthropic\|\.openai" Sources/Throttle/UI/` gains no new matches.
- No third-party import or package manifest is added; `grep -rh "^import " Sources | sort -u` lists only Apple frameworks.
- Nothing new under `scripts/` or `.github/` is anything but bash.

### D3. Tokens and secrets

- A reset and a poll fired together on an expiring token produce exactly one refresh request.
- A 401 on the reset flips the account to sign-in-again and keeps the row in the store.
- No reset request id, grant id, credit id or organization id is written to `accounts.json`, UserDefaults, or the status cache file; the token-key test on `Account` still passes.
- Every reset error message passes through `Redactor`; the no-token-logging tests still pass.
- The diagnostics line for a failed reset drops the Authorization header like every other line.

### D4. Nothing else changes by accident

- Resetting one account leaves every other account's cached entry byte-identical (two-account test).
- A reset never removes an account row, for any answer: no credit, ineligible, error.
- A status cache file written by today's release, with and without the reset count, still decodes; any new field has its own old-file decode test.
- `scripts/test.sh` ends with `** TEST SUCCEEDED **` with at least 482 tests plus the new ones and zero failures.
- `scripts/build.sh` produces `build/Throttle.app`.
- New fixtures contain no real email, account id, org UUID, grant id, token, or home path.

### D5. The docs tell the truth

- CLAUDE.md no longer says Throttle never spends quota without qualification: polling is read-only, and a reset is spent only on an explicit, confirmed click.
- README's read-only paragraph says the same and names the one exception.
- Comments in `UsageProvider.swift` and both providers' adapter and endpoints files that say "never spends" are reworded to say the usage read never spends, and each names the one reset call; `grep -rn "never.*spend" Sources/` shows only accurate lines.
- The forbidden-endpoint test's doc comment explains why the reset paths are allowed, and where.

## C. Claude reset: the machine side

Channel: named unit tests against a stub HTTP client and captured fixtures, and greps.

Settled between slices: a usage body with **no** reset block, or a block with `eligible: false`, yields **no count** (no column, no button). An eligible account with no usable resets left yields **0**. Every result the Claude adapter returns uses group A's on-screen wording; `not_limited` shows the same "Nothing to reset right now — your reset was not used" as Codex's `nothing_to_reset`.

### C1. Reading the count

- The Claude usage read adds `cedar_ember=1` and still carries `at_wall=1` and `skip_spend=1` (a stub test asserts the exact query items).
- Each Claude account still sends exactly one usage request per poll; the count adds no request.
- A usage body with no reset block parses exactly as today (same windows, same plan, no count); every existing Anthropic fixture test still passes.
- An eligible block's count is the sum of `resets_left` across valid grants (new fixture with grants of 1 and 2 yields 3).
- `eligible: false` yields no count; `eligible: true` with no grants, or grants all at 0, yields 0.
- A malformed block (the block as a string, grants that are not objects, `resets_left` negative or fractional, a grant id failing `^[a-z0-9_-]{1,40}$`) never breaks the usage reading: the windows equal the clean fixture's, malformed grants are skipped, and no valid grant left yields no count.
- The grant to spend is `next_grant_id` when it matches the id rule and names a grant present in the list; otherwise the usable grant (`usable_now` true, `resets_left` > 0) with the soonest `ends_at`. Three named cases: valid, naming a missing grant, null.
- No codename (`cedar_ember`, `juniper_tide`), grant id, or reason code appears in an encoded `AccountStatus`, the status cache, the UI, or a user-visible message; `grep -rn "cedar\|juniper" Sources/Throttle/UI Sources/Throttle/Models` prints nothing.
- A status cache written before this change still decodes.

### C2. Spending a reset

- The trigger is `POST https://api.anthropic.com/api/organizations/<org uuid>/reset_rate_limits` with `Content-Type: application/json` and the same `Authorization`, `anthropic-beta`, `anthropic-version`, `Accept` and `User-Agent` headers as the usage read.
- The body is exactly `{"program":"cedar_ember","grant_id":"<selected grant>","request_id":"<uuid>"}`, no other keys.
- The organization UUID comes from `organization.uuid` in the profile read. It is held in memory for the launch (learned from the profile read the plan badge already makes), or with the secret credential in the Keychain, and never written to `accounts.json`, UserDefaults, or the status cache; the token-shaped-key test on `Account` still passes.
- When the organization UUID is not yet known, the reset makes at most one profile read to learn it; if that read is refused or on hold, no POST is sent, the row shows "Claude is limiting requests — try again at <hold end>" with the time taken from the profile hold, and the hold is honored, never bypassed.
- A grant id failing `^[a-z0-9_-]{1,40}$` or a request id failing `^[A-Za-z0-9_-]{1,64}$` stops the POST before it is sent.
- A retry of the same click reuses the same `request_id`; a new click gets a new one.
- Results map to group A's outcomes: `reset` and `already_used` are success followed by one usage read; `not_limited` is nothing-to-reset; `cooldown` uses `cooldown_until`; `ineligible`, and `unavailable` with a stale-grant reason, are not-available; a bare `unavailable` (which Claude Code treats as possibly spent) and any unknown value are unexpected, keep the attempt, and re-read.
- After success, the window numbers come from the follow-up usage read; the reset response's own `resets_left` and `cleared` never overwrite window percentages.
- A 429 on the follow-up read is not retried in a loop: one read, the backoff and `Retry-After` honored, the reset still reported as used.
- A 401 on the POST refreshes once through the serialized refresh path and resends the same body; a second 401 flips the account to `needsLogin`, keeps the row, and sends nothing more.
- A 403 permission error on the POST shows the redacted provider message and does not sign the account out.
- A 429 on the POST shows the rate-limited message from `Retry-After`, does not retry on its own, and does not move the usage poll's backoff.
- A 5xx or transport failure on the POST shows the couldn't-reach or provider-error message and does not retry on its own.
- Every error string passes through `Redactor`; a 500 body containing a fake bearer shows no token.
- A non-200 POST writes one diagnostics line of kind `reset` with no Authorization value.
- The adapter never sends a body with `program` other than `cedar_ember` or without a `grant_id`, and never reads the weekly session-trial block; `grep -rn "juniper" Sources/` prints nothing.
- Two resets fired at once for one account send one POST.

## F. Added by the completeness check

### Landmines

- Adding `cedar_ember=1` to the Claude usage read causes no new 429 or 403: after one full live cycle on the new build, the diagnostics log shows no new 4xx on any Claude usage read, and every Claude row still shows its windows.
- If the live read with `cedar_ember=1` is refused where the old query was not, the Claude usage read returns to the old query: rows keep their windows, lose the resets column, and the fallback is written in the ISA Decisions. Losing the count is acceptable; losing the windows is not.
- The Claude usage request carries exactly the query items `at_wall=1`, `skip_spend=1`, `cedar_ember=1`, and still sends Throttle's own User-Agent, never Claude Code's (named test on the recorded request).
- A reset that must learn the organization UUID shares the plan read's profile cache and hold: a plan read then a reset in one launch sends at most one profile request per account.
- A sign-in forgets the stored organization UUID along with the plan, so signing into a different organization sends the reset to the new one.
- `URLAllowlistTests` passes with its host list unedited: both reset URLs sit on hosts already allowed.
- The menu bar label and its image tests are unchanged: the label never shows the reset count, a spinner, or a result, and keeps its rotation cadence during a reset, showing the account's last cached numbers.
- The Check for Updates flow and all its tests are untouched.

### States and races

- A reset started before its row is removed never brings the row back and never writes a cache entry for the removed account (machine outcome: a model test).
- Renaming or moving a row during a reset does not lose the result: it lands on the same account, found by id.
- A row with a count above 0 whose state is sign-in-again or wrong-sign-in-type shows the count dimmed and the button greyed; after "Log in again" and a successful poll, the button is enabled again.
- When the grant chosen at read time has since expired or been used and the provider answers not-available or already-used, the app forces one usage read so the count corrects itself, and sends no second reset on its own.
- A cooldown time in the past or unreadable shows the generic not-available message, never "until" a past time.
- A provider result, code, or error message that is huge, has control characters, or has newlines is capped at 300 characters and redacted before display.
- Quitting during a reset leaves `accounts.json`, the Keychain item and the status cache valid; the next launch shows the account normally and its first poll shows whether the reset landed.
- The status cache keeps the reset count across a save and load by the new build, and an old cache without it loads with no count.
- If the count changes to 0 while the confirmation is open (a poll lands), confirming sends nothing and shows "No resets available".
- A reset request has a bounded timeout; the spinner never runs forever, and after the timeout the row shows the couldn't-reach message and the button is enabled again.
- A failure message stays until closed or replaced by the next use of the button; it does not fade like the success note, and it does not survive a relaunch.
- The popup snapshot tests render, in light and dark: button enabled, button greyed at 0, resetting, success note, and a failure message; existing snapshots of rows without resets render unchanged.
- The shipped app has no fake-provider path: `grep -rn "THROTTLE_FAKE\|StubProvider" Sources/` prints nothing.

## E. Shipping it

- The work lives on `feat/use-banked-reset`, with this outcomes file committed before the first build commit.
- `scripts/test.sh` ends with `** TEST SUCCEEDED **`, at least 482 plus the new tests, zero failures; the count is quoted from the log.
- `scripts/build.sh` produces `build/Throttle.app`, and the running Throttle process is proven to be that build (its executable path and binary modification time match the build under test).
- Before the new build first runs, the account ids and count in `accounts.json` and the Keychain item count for service `ai.parslee.throttle` are captured with a screenshot of the detail window; after one full poll cycle they are identical and every existing row shows windows as before.
- On every live Codex account that holds resets, the "Manual resets" column shows an enabled **Use reset** button (screenshot, opened and read).
- Clicking it opens the confirmation (screenshot). Pressing Cancel leaves the row unchanged.
- First real use, only with the owner's explicit go-ahead and on the account the owner picks: whatever the provider answers is shown with group A's wording, the count shown afterwards equals the provider's fresh reading, and the diagnostics log shows no error line. A confirm may spend a real reset; no live click is assumed to be free.
- Any live Claude row whose provider reports a count shows the column; if none does, that is recorded as "no Claude account in the reset program yet", neither pass nor fail.
- A real successful reset that spends a credit is only ever the owner's own click. When it happens, a frame-scrub of the row shows the bars sliding and the provider's fresh count one lower. Until then, that outcome is recorded as awaiting his use.
- CLAUDE.md, README and the adapter comments read truthfully (D5).

## Not in this version

- Choosing which credit or grant to spend, or listing individual credits. The provider picks for Codex; for Claude the adapter uses `next_grant_id`, else the soonest-expiring usable grant.
- Showing a credit's or grant's title, expiry, which limits it clears, or how many windows it reset.
- Automatic or scheduled resets; resets from the poll cycle, the timer, a wake or a launch.
- Resets from the menu bar label or a notification. The detail window only.
- One click that resets several accounts.
- A "try a reset" mode for accounts with no count: both providers report a count, and without a grant there is no valid Claude request to send.
- Claude Code's own headroom warning. The confirmation's "% left" list covers the same need.
- The Claude weekly session-reset trial, in any form.
- Claude grant fields beyond skipping unusable grants (`paused`, `blocking`, `exhausted`, `percent_used`), and ineligibility reason codes on screen.
- The `/api/codex/...` path style and FedRAMP accounts: Throttle cannot tell a FedRAMP account today, and such an account gets the provider's own error.
- Retrying the same attempt across an app relaunch.
- Undoing a reset.
- A reset-history log in the UI.
