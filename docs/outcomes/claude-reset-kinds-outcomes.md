# Claude reset kinds: outcomes

A Claude account can hold more than one kind of banked reset: a full reset, and a model refill (today, the Fable reset). Throttle shows how many of each kind an account has left and lets the owner spend the kind they pick, from the detail window. This extends `banked-reset-outcomes.md`; everything there still holds unless a bullet here says it replaces one.

Reference for the provider's payload and answers: the `claudeResetGrants` service and its tests in `router-for-me/Cli-Proxy-API-Management-Center`, the management UI of CLIProxyAPI. It is third-party evidence, not a specification.

The provider reports banked resets only to a client that identifies itself as a current Claude Code CLI; any other client name is answered as not eligible. The owner's decision for this version is to do what the reference does: Throttle's Claude account requests carry the Claude Code CLI's client name. This replaces the earlier rule that Throttle always sends its own name to Claude.

## Who uses this and how each outcome is confirmed

| Who | Surface | Confirmed by |
|---|---|---|
| The account owner | The detail window | The real running app on screen (screenshot, opened and read) wherever a live Claude account reports resets and the state needs no spend. Every other state is proven on the real SwiftUI views rendered to PNG by the snapshot tests, in light and dark, opened and read. Unit tests and reads of view structure do not close these outcomes. |
| The machine | The Claude adapter, the scheduler, the status cache | Named unit tests against a stub HTTP client and fixtures, greps over the repository, and literal command output. |
| Shipping it | The branch, the release, the first real use | Suite exit code, the released package's signature and version, the installed app on the owner's accounts. |

Kind names used below: **Full reset**, **7-day reset**, **5-hour reset**, **<model name> reset** for a model refill (the model's name exactly as the provider's payload spells it), and plain **Reset** for a grant whose kind the app does not recognize.

## A. Claude resets by kind, in the detail window

Channel: the real running app, or snapshot PNGs opened and read.

### What the row shows

- A Claude row whose provider reports resets lists them by kind inside the "Manual resets" column, one line per kind, count first and then the kind's name: "2  Full reset", "1  Fable reset". On Claude rows with kinds this replaces the single "N available" line.
- Several grants of one kind show as one line with their counts added together.
- Kinds are listed in one fixed order (full, 7-day, 5-hour, model refill, then plain "Reset"), the same in the row, the confirmation and VoiceOver.
- A Claude row with exactly one kind is exactly as tall at rest as the same row in 0.5.1 with a count. Each further kind adds one text line of height to that row only. The row never gets wider, the column keeps its fixed width, and the usage bars to its left do not move.
- A kind that cannot be spent right now still shows its count, greyed, and hovering it gives one plain reason: "Usable once you reach a limit", "No <model name> usage to give back", "Paused", "Starts <date>", "On cooldown until <time>", or "Not usable right now". No provider reason code appears anywhere.
- A kind the provider still lists with none left reads "0  <kind>", greyed, with the reason "None left".
- An eligible Claude account that holds no grant at all reads "0 available" with the button greyed, exactly as today.
- One **Use reset** button sits on the column's first kind line. It is enabled when at least one kind can be spent or a retry is pending, and greyed otherwise. Its tooltip is the single kind's reason when there is one kind, "No reset can be used right now" when several kinds are all blocked, and "No resets available" when every count is 0.
- A dimmed or stale Claude row dims every kind line and greys the button with "Refresh this account first", as today.
- The "…" menu and the right-click menu's "Use reset…" follow the same rule as the button.
- A very long kind name shows on one line, cut with an ellipsis inside the column, with the full name in its tooltip. A name carrying control characters, line breaks or token-like text shows cleaned and redacted, and a name that is empty after cleaning reads "Reset".

### Confirming

- With one kind on the row, the confirmation names it: "Use 1 of 2 Full resets for <row name>?". The count is that kind's count. This replaces the "Use 1 of N resets for …" title on Claude rows with kinds.
- With two or more kinds on the row, the confirmation lists every kind with its count. Spendable kinds can be picked; blocked kinds are greyed with their reason beside them. Nothing is picked in advance, and "Use reset" stays greyed until the owner picks one.
- When the chosen kind is a model refill, the confirmation says what it does, using the row's own window names: "Refills 7-day <model name> and returns its share to the 7-day limit. Other weekly usage stays as it is."
- The "Left right now" list of each window's "% left" stays, so spending while a window has room is still a visible choice.
- Cancel is still the default and has focus when the card opens. Return or Escape alone spends nothing, before or after a kind is picked.
- If the chosen kind drops to 0, disappears, or becomes blocked while the card is open, confirming sends nothing and the row shows that kind's reason ("No resets available" at 0). The app never spends a different kind in its place. This extends the existing "count changes to 0 while the confirmation is open" outcome.

### Running, success and refusals

- While a reset runs, "Resetting…" with its spinner sits under the last kind line, the button is gone, and no kind on that row can be started. Other rows are unaffected.
- On success the note reads "<kind> used — limits refreshed" ("Reset used — limits refreshed" for a plain "Reset"). This replaces the success note on Claude rows with kinds.
- After success the chosen kind's line shows the provider's fresh count, and every other kind shows whatever the provider now reports for it. The app subtracts nothing itself.
- After a model refill only the bars the provider's fresh reading changed move; every other bar keeps its place.
- When the last reset of the last kind is used, the lines read 0 and the button greys with "No resets available".
- Every refusal keeps today's wording (nothing to reset, cooldown, not available, limiting requests, couldn't reach, provider problem, unexpected answer) and leaves every kind's count where the provider's reading puts it.
- After a result that leaves it unknown whether a reset was spent (couldn't reach, provider problem, unexpected answer), the row offers only a retry of that same kind: the confirmation is titled "Retry <kind> for <row name>?", the other kinds are greyed with the reason "Finish the earlier reset first", and the retry stays available even when the latest reading shows that kind at 0, paused or gone. The retry is offered for 10 minutes from the first send.
- When a retry is refused, or 10 minutes pass with no definite answer, the row reads "Unexpected answer from Claude" and offers no reset of any kind, with the reason "Waiting for a fresh reading", until that account's next successful reading arrives. A new click is therefore always made against the provider's fresh counts. A retry confirmation left open past that point sends nothing when confirmed and never starts a new attempt in its place: the owner opens a new confirmation.
- A click on a row that this launch has not yet read (it is showing saved numbers) spends nothing: the row reads "Getting the latest reset counts — try again in a moment", the account is read once, and the row then lists its kinds.
- A row showing three kinds, a row with a reset running and a row with a failure message render together with no clipped or overlapping text, in light and dark.

### Keyboard and VoiceOver

- The kind list in the confirmation is reachable with Tab, the arrow keys move between spendable kinds, Space picks one, and a blocked kind cannot be picked from the keyboard.
- VoiceOver reads the column as "Manual resets: 2 Full reset, 1 Fable reset", reads a greyed kind with its reason, reads the picked kind in the confirmation, and announces the result with the kind's name.

### What stays as it is on screen

- A Codex row is unchanged from 0.5.1: one unlabeled "N available", the same button, confirmation title, messages and height. A before/after render of a Codex row with a count shows no difference.
- A Claude row whose provider reports no resets shows no "Manual resets" column and no button, and renders pixel-identical to 0.5.1.
- The menu bar label never shows a kind, a count, a spinner or a result.
- No screen, tooltip or message shows a grant id, an organization id, a token or a provider reason code.

## B. Claude reset kinds: reading them

Channel: named unit tests against fixtures, and greps.

- The Claude usage read, the profile read and the reset request each send `User-Agent: claude-cli/<version> (external, cli)`, where the version is one constant in the Claude endpoints file naming a real, current Claude Code release. This replaces "Throttle's own User-Agent, never Claude Code's".
- No other header is added or changed on those three requests, and the usage read's query items stay exactly `at_wall=1`, `skip_spend=1`, `cedar_ember=1`.
- The token exchange and token refresh requests are unchanged: same URLs, bodies and headers as 0.5.1.
- The client name appears in exactly one place under `Sources/`, the Claude endpoints file; a grep for `claude-cli` lists that file only.
- Each valid grant is read with its kind, resets left, total when sent, start, expiry, and its paused, usable-now and requires-a-limit flags (new fixture `anthropic-resets-kinds.json`).
- Kind is decided by one rule, tested as a table: `gives_back_weekly: true` is the model refill whatever `type` says; otherwise a `type` of `weekly`, `session` or `full`; any other, missing or non-text `type` is the unknown kind, which is still counted and can still be spent.
- The account's status reports one entry per kind present, each with resets left summed over that kind's valid, unexpired grants. A fixture with full 2, full 1 and model refill 1 yields full 3 and model refill 1. This replaces "the count is the sum of `resets_left` across valid grants".
- The single total still equals the sum over all kinds, so that fixture totals 4 and every existing count test passes. Existing assertions are unedited, except in the five tests this work replaces: the ones asserting Throttle's own client name, that a non-usable grant is sent, that a reset before any poll reads usage inside the spend, that a rate-limited usage read inside a spend sends nothing more, and that a sign-in to another organization carries the same attempt over.
- A kind's count includes grants that are held but not spendable now (paused, not started, needing a limit). Whether the kind can be spent is reported separately, so "how many are left" never reads 0 for any reason other than having none.
- A grant whose expiry is at or before the clock is left out of both the count and the choice. Tested one second either side.
- A kind is spendable when at least one of its grants passes every condition: the account is eligible, the grant is not paused, `usable_now` is true, it has a reset left, it has started, it has not expired, no account cooldown is in force, the account is at its limit when the grant requires one, and a model refill is not known to have nothing to give back. A table test has one row per condition, each flipping spendable to no.
- Missing flags fall on the refusing side: `usable_now` absent is not usable, `use_requires_limit` absent requires a limit, `at_limit` absent is not at the limit. An unstated permission is not a permission.
- A model refill is blocked only when every usage figure the grant reports is exactly 0. An empty, missing or partly unreadable usage map is unknown and does not block. Six cases.
- A non-spendable kind reports exactly one plain reason, the first that applies in a fixed order: cooldown (with its end time), none left, not started (with its start time), paused or not usable now, usable only at the limit, nothing to give back. The reason is a provider-neutral value, never a provider string.
- Start, expiry and cooldown are judged against the clock at the click, not at the read. A grant read as valid at 12:00 that expires at 12:03 is refused at 12:04 with no request sent.
- The model refill's display name comes from the usage payload: the display name of the account's model-scoped weekly window when there is exactly one, and "Model reset" when there are none or several. A test swaps the fixture's model name for an invented one and sees the label follow; no string literal under `Sources/` names a model.
- That display name is cut to one line, stripped of control characters and capped at 40 characters before it leaves the adapter (test with a 5,000-character name containing newlines).

### Malformed and hostile blocks

- One malformed grant is skipped and the rest are kept. One bad grant must not hide a real reset, and a skipped grant can only under-count.
- A grant is malformed when: its id fails `^[a-z0-9_-]{1,40}$`; `resets_left` is negative, fractional, text or a boolean; `resets_total` is present and is not a whole number at least as large as `resets_left`; any of `paused`, `usable_now`, `use_requires_limit`, `gives_back_weekly` is present and not a boolean; `starts_at` or `ends_at` is present, non-null and unreadable. One case per shape.
- `resets_total` may be absent: the count shown is what is left, and a missing total must not hide a spendable reset.
- A grant id that appears more than once drops every copy. The copies may disagree, and counting either risks showing a reset that is not there.
- A grant's label and its list of windows cleared, of any size or content, change nothing that is parsed.
- An unreadable account-level cooldown, or a non-boolean `at_limit`, leaves the counts shown and makes every kind non-spendable. The count is still true; spending is what must fail closed.
- Every shape above, and every shape in the existing malformed fixture, leaves the parsed windows equal to the clean fixture's.
- `eligible: false` still yields no kinds and no count. Eligible with no grants yields no kinds and a count of 0. Existing assertions are unedited, except in the five tests this work replaces: the ones asserting Throttle's own client name, that a non-usable grant is sent, that a reset before any poll reads usage inside the spend, that a rate-limited usage read inside a spend sends nothing more, and that a sign-in to another organization carries the same attempt over.
- When a reset block is present and eligible but yields no count, one diagnostics line says which rule failed, with no grant id or label, at most once per account per launch.
- When a reset block says the account is not eligible, one diagnostics line records why, at most once per account per launch and again only when the reason changes. The reason written is one of a fixed list (`config_off`, `tier`, `seat`, `mobile`, `surface`, `cli_version`, `no_grant`, `tenure`, `other_experiment`, `unavailable`); anything else is written as `unknown`, so provider text never reaches the log. Together these two lines make a live row with no column diagnosable, including the day the pinned client version goes out of date.
- The not-eligible reason goes to the diagnostics log only: never to the screen, the status cache or a message.
- An encoded status and the status cache carry each kind's label, count, spendable flag, reason and times only: no grant id, grant label, codename or provider reason string. `grep -rn "cedar\|juniper\|gives_back" Sources/Throttle/UI Sources/Throttle/Models` prints nothing.

## C. Claude reset kinds: spending the chosen one

Channel: named unit tests against a stub HTTP client.

- A reset names the kind the owner chose, and the POST carries a grant of that kind and no other. With a fixture whose `next_grant_id` names a 7-day grant, choosing the model refill sends the model refill's grant and choosing 7-day sends the 7-day one.
- Within the chosen kind the grant is `next_grant_id` when it is of that kind and spendable, otherwise the spendable grant of that kind ending soonest. This replaces the earlier grant-selection outcome.
- For a new attempt, a grant that is not spendable is never sent. This replaces today's fallback, which sends a non-usable grant and lets the provider answer. A retry of an unanswered attempt is exempt: it resends its pinned grant whatever the latest reading says.
- For a new attempt, when the chosen kind has nothing spendable at the click, no POST is sent and the answer carries that kind's reason. One case per reason.
- The body is still exactly `program`, `grant_id`, `request_id`; the kind never goes on the wire.
- The adapter never makes a usage read of its own to prepare a spend. A spend when this launch holds no reading of the account sends no request at all and answers that a fresh reading is needed; the scheduler then reads that one account through its normal path, under its single-flight and backoff rules, so an overlapping poll adds no second usage request. This replaces the earlier behavior of reading usage inside the spend, and the test that asserted it.
- A resend of an attempt reuses the same request id and the same grant when a later read no longer lists that grant, lists it as paused, or would now pick another grant of the kind. Three cases.
- A resend carrying the same attempt id but a different kind sends nothing. The request id is only an idempotency key together with its grant.
- After a send that got no terminal answer (transport failure, timeout, 5xx, unknown result), a refusal on the resend (`not_limited`, `cooldown`, `ineligible`, `unavailable`) is reported as "Unexpected answer from Claude", never as "your reset was not used": a refusal on a retry cannot prove the first send did not spend. It triggers the one re-read, and no new attempt for that account is accepted until a usage read made after the refusal has succeeded. A resend after a 401 counts as a first send only when no earlier send of that attempt went unanswered; once any send of an attempt has gone unanswered, a later refusal is reported as unexpected even if a 401 and a token refresh came in between.
- 401 and 403 on the POST keep today's behavior: one serialized refresh and one resend of the same id and grant; a permission 403 is shown redacted.
- The organization id keeps its path-safe rule.
- Result mapping is unchanged for every kind: the existing result table passes unedited for a full grant and again for a model refill.
- A full poll cycle over the kinds fixture records zero POSTs.
- A retry is sent only within 10 minutes of the attempt's first send, the lifetime the provider's own client relies on for its request id. After that the attempt is closed without sending anything, one usage read is triggered, and no new attempt is accepted until a usage read has succeeded. The 10 minutes are checked immediately before every POST, including the resend after a token refresh: a refresh that crosses the deadline sends nothing.
- A sign-in on the account forgets its pending attempt, its choice and its pinned grant along with the organization id, so the next click is a new attempt for the newly signed-in account. A retry is never sent to a different organization than its first send. A usage or profile response that was requested before the sign-in does not put the earlier sign-in's grants or organization id back, and does not publish its counts on the row.
- A failed reset request leaves no organization id, grant id or request id on disk: the id in the diagnostics line's URL is replaced, and those three values are removed from the body excerpt the line keeps. Tested through the real adapter with marker values, a 500 whose body echoes all three, and a 429.

## D. The seam, the scheduler and the cache

Channel: named unit tests against a stub provider and a stub HTTP client, greps, literal command output.

### The shape that crosses the seam

- `AccountStatus` carries an optional list of reset kinds. Each has only a display label, a count, whether it can be spent now, a plain reason when it cannot, and a provider-neutral choice key. No list means one unnamed kind, which is what Codex reports.
- `resetCreditsAvailable` stays the total across kinds: for every status with a list, the kind counts sum to it (a test over every Claude reset fixture).
- Reading the same payload twice gives two equal statuses apart from the read time, so an unchanged account causes no redraw and no extra cache write.
- A kind label is cleaned at the one place every adapter's label passes, the model's own initializer: a 2,000-character label with newlines, control characters and a fake bearer token comes out as one line, capped and redacted.
- The choice key never contains the provider's grant id. With a fixture grant id of `grant-sentinel-1`, that text is absent from the encoded status, the key's printed description, every reset message and the diagnostics log.
- `UsageProvider.useReset` gains one choice parameter and stays a single requirement whose default means "not supported". No conformer or test double still declares the old three-argument form, which would compile and silently never be called (a grep of `Sources` and `Tests` for the old signature prints nothing).
- A test double that does not implement `useReset` still builds and answers unsupported.

### Spending a chosen kind

- The scheduler passes the owner's choice through to the adapter untouched, with the attempt id. A stub with kinds A and B, asked for B, records B.
- A retry of an uncertain attempt reuses its attempt id and its original choice, even after a poll has replaced the kinds list.
- While an account has an unresolved attempt for one kind, a click on a different kind sends nothing and leaves the pending id and choice unchanged.
- If a poll lands while the confirmation is open and still reports the chosen kind as spendable, confirming spends that kind. It is never redirected to another kind and never cancelled.
- A choice the adapter can no longer resolve (the kind vanished mid-flight, or the choice predates a sign-in) sends no reset request, never substitutes another kind, ends as not-available and triggers the one usage read.
- Two kinds started at once on one account send exactly one reset request; the second ends as already-running.
- A spend with no choice never spends on an account whose provider reports kinds, including when the kinds are first learnt after the click (a row restored from a 0.5.1 cache shows a count and no kinds): nothing is sent, the account is read once, and the owner picks and confirms again.
- After any kind is spent, the per-kind counts shown are the follow-up read's. Nothing subtracts one locally from a kind or from the total.
- Removing the row during a kind spend forgets its pending attempt and choice, writes no cache entry and shows no message. A rename or move lands the result on the same account.
- Each send keeps the existing 20-second bound; a timed-out kind spend is couldn't-reach and keeps its id and choice.
- The owner's pick reaches the wire unchanged through the real path: a test hosts the real confirmation with the real model, scheduler and Claude adapter over a stub HTTP client, picks the second of two kinds and confirms, and the one POST carries that kind's grant.
- Opening the confirmation, picking a kind, changing the pick, cancelling, and pressing Return or Escape before or after a pick send no request of any kind: the stub HTTP client's recorded request count is unchanged.

### The status cache

- The cache file keeps kind labels, counts, reasons and choice keys across a save and load.
- A cache file written by 0.5.1, checked in as a fixture generated from tag `v0.5.1` with fake accounts, decodes in the new build with the same windows, plan and total, and no kinds.
- A cache file written by the new build loads in 0.5.1: the test decodes it with a frozen copy of 0.5.1's own status and cache types, taken from tag `v0.5.1`, and every entry, window, state and total survives. The file's format version stays 1. A downgrade never blanks the rows.
- A Codex entry encodes to the same bytes 0.5.1 produced for the same input (comparison file generated at tag `v0.5.1`).
- Kinds survive a failed attempt, a backoff skip and a state change, at every place the cache rebuilds a status.
- After a spend by kind with marker values for the grant id, organization id and request id, none of them appears in `accounts.json`, `status-cache.json`, the backoff file, UserDefaults or `diagnostics.log`.
- The diagnostics line for an ended reset attempt keeps its shape and carries no grant id, organization id, codename or reason code.
- Quitting during a kind spend leaves `accounts.json`, the Keychain item and the cache valid. The next launch carries no pending attempt.

## E. What must stay as it is

Channel: named tests, greps, literal command output.

- Codex: the consume body is still exactly one key, `redeem_request_id`, whatever choice is passed. Every existing Codex reset and usage-parser assertion passes unedited.
- No poll cycle, Refresh, wake or rotation tick sends a reset request for an account whose status has kinds: the never-from-polling test is rerun with a kinds fixture.
- Polling adds no request: the eight-accounts-over-an-hour budget test is unchanged and passes.
- `git diff main -- Tests/ThrottleTests/Polling` removes or changes no `XCTAssert` line in the cadence, stagger, single-flight, backoff or existing reset tests. Call sites may change only to pass no choice.
- A 429 on a kind spend leaves the poll backoff unmoved.
- A grep for `cedar`, `juniper`, `grant_id`, `gives_back`, `reset_rate_limits` or `wham` under `Polling/`, `App/`, `UI/`, `Models/` and `Store/` prints nothing, as it does today.
- A grep for `.anthropic` or `.openai` under `UI/` gains no match.
- `URLAllowlistTests.swift` is unedited. `ForbiddenEndpointTests` keeps every forbidden fragment, and any file added to its allowed set sits under `Providers/`.
- `MenuBarImageTests` is unedited and passes.
- `git diff main --stat` is empty for `Sources/Throttle/Update` and `Tests/ThrottleTests/Update`. Imports are Apple frameworks only, there is no `Package.swift`, and nothing new under `scripts/` or `.github/` is anything but bash.
- `scripts/build.sh` ends with zero warnings. `scripts/test.sh` ends `** TEST SUCCEEDED **` with at least 670 tests plus the new ones and zero failures.
- Nothing operator-specific is committed. New fixtures carry no real email, account id, organization id, grant id, token or home path, and no screenshot, log, cache copy or verifier report from a live check is added to the repository: `git diff main --name-only` lists only files under `Sources/`, `Tests/` and `docs/outcomes/`, plus `README.md`, `CLAUDE.md` and the project's version setting.
- Changing the client name causes no new refusal: after one full live cycle on the released build, the diagnostics log shows no new 4xx on any Claude usage or profile read, and every Claude row still shows its windows.
- If the live reads with the new client name are refused where 0.5.1's were not, the next release returns to Throttle's own client name: rows keep their windows and lose the resets column, and the fallback is recorded. Losing the resets is acceptable; losing the windows is not.
- README and CLAUDE.md say plainly that Throttle's Claude account requests identify as the Claude Code CLI, why (the provider reports banked resets to that client only), and that this is undocumented and may stop working. No doc or comment still says Throttle sends its own name to Claude.
- CLAUDE.md's banked-reset section says the user picks a kind, the choice crosses the seam as a provider-neutral key, and the adapter resolves it to a grant. README's read-only paragraph says an account may hold more than one kind of reset and that Throttle spends the one clicked. The doc comments on `useReset` and `resetCreditsAvailable` describe the choice and the total truthfully.

## F. Shipping it

- The work lives on `feat/claude-reset-kinds`, with this outcomes file committed before the first build commit.
- `scripts/test.sh` ends `** TEST SUCCEEDED **` with zero failures, the count quoted from the log, and `scripts/build.sh` produces `build/Throttle.app` with zero warnings.
- Every outcome above was graded by a fresh-context verifier that did not write the code, and then by one whole pass on the final commit.
- The pull request's CI is green and it is merged to `main`.
- Released as 0.6.0: tag `v0.6.0` on origin `main`, and the `.pkg` downloaded from GitHub is Developer ID signed, notarized, stapled, accepted by `spctl`, and its app reports 0.6.0.
- A dev build is never run beside the installed app: two instances share one account store and Keychain. Live outcomes are checked on the released build.
- On the installed 0.6.0, the account ids and count in `accounts.json` and the Keychain item count are the same as before the update, and every existing row shows its windows as before.
- On the installed 0.6.0, every Codex row reads as it did on 0.5.1.
- On the installed 0.6.0, every Claude row whose provider reports resets lists them by kind with counts. If no Claude row shows the column, the diagnostics log is read and its reason recorded per account: `cli_version` or `surface` means the client name was not accepted, and a line naming a parsing rule means the payload differs from the reference; both are defects that go back to the build. `no_grant` means the account holds no resets. Any other reason is recorded by name as resets not offered to that account, which is neither a pass nor a defect.
- A real Claude reset is only ever the owner's own click. When it happens, the confirmation names the kind, the provider's answer shows with the wording above, and the kind counts on screen afterwards equal the ones the follow-up reading stored in the status cache. Until then this outcome is recorded as awaiting the owner's use.

## Not in this version

- Choosing between two grants of the same kind, or seeing a grant's label, total ("2 of 3") or expiry date. The row shows one count per kind.
- Listing which windows a kind clears, beyond the model refill's one-line explanation.
- A total across kinds on a Claude row.
- Kinds on Codex rows, or sending `credit_id` to pick a Codex credit.
- Spending more than one reset, or more than one kind, in one confirmation.
- A hint recommending which kind to use.
- Keeping an unresolved attempt across a relaunch. After a relaunch the row shows the provider's fresh counts and a new click is a new attempt.
- A fresh usage read before every spend. The Claude usage read has answered a single extra call with a one-hour hold, so the last poll's reading plus the click-time clock decides.
- Showing the provider's ineligibility reason, or any reason code, on screen.
- Copying anything of the Claude Code client beyond its client name: no extra headers, header order, TLS fingerprint or SDK version strings.
- Updating the pinned client version without a Throttle release, or telling the user on screen that it has gone out of date.
- Changing the client name sent to Codex.
- Rejecting the whole reset block on one bad grant.
- Any reset program other than the banked one, and the weekly session-reset trial.
- A per-kind history or log of spends.
- A cache format version bump or a migration step.
- Any change to poll cadence, backoff, the reset timeout or the settle before the follow-up read.
