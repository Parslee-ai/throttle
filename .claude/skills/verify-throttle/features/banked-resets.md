# Banked resets by kind

When an account has banked limit resets, its row lists how many of each kind are
left (for example a full reset and a refill for one model) and shows a
`Use reset…` button. Clicking it opens a confirmation inside the window that names
the account, the kind and the windows it will reset; nothing is spent until the
user confirms. After a spend the row shows the provider's fresh numbers; a
refusal, a timeout or a retry window shows a one-line message. Throttle never
spends a reset from a poll, a timer or a launch.

## Sub-features

- `reset-counts` shows one line per kind with its count, greyed with a reason
  when it cannot be spent.
- `reset-button` enables `Use reset…` only when something is spendable.
- `reset-confirm` names the account, the picked kind and each window; Return and
  Escape never confirm.
- `reset-results` shows success with fresh bars, partial success, refusal, rate
  limit, sign-in needed, no answer with a retry window, and an unexpected answer.
- `reset-safety` spends the picked kind only and never twice.

## How to get to it (user POV)

- Click the menu bar item; on an account row with resets, click `Use reset…`
  (also in the row's actions menu), pick a kind, and confirm.

## Driving it with throttle-verify

Preconditions:

- `$S snapshots` can build and run the test target. No live app is needed.

- **Counts and button states (hosted view).** Run `$S snapshots`. Check
  `kinds-row-one-kind-*`, `kinds-row-two-kinds-*`, `kinds-row-three-kinds-*`,
  `kinds-row-all-kinds-*`, `kinds-blocked-reasons-*`, `kinds-none-left-*`,
  `kinds-greyed-stale-*`, `reset-claude-enabled-*`, `reset-greyed-zero-*`,
  `codex-with-count-*`. The `*-help.txt` files beside them record each line's
  tooltip and whether the button is enabled.
- **Confirmation (hosted view).** Check `kinds-confirm-unpicked-*`,
  `kinds-confirm-picked-*`, `kinds-confirm-model-refill-*`,
  `kinds-confirm-kind-gone-*`, `reset-confirm-*`, `panel-reset-confirm-*`.
- **Results (hosted view).** Check `kinds-success-*`, `kinds-refused-*`,
  `kinds-running-*`, `kinds-waiting-fresh-reading-*`, `reset-success-*`,
  `reset-http-error-*`, `reset-rate-limited-*`, `reset-needs-login-*`,
  `reset-cooldown-*`.
- **Behavior (unit tests).** Run `scripts/test.sh` and check
  `ResetConfirmationFlowTests` (`testConfirmSendsNothingUntilConfirmed`,
  `testPickedKindGoneWhileOpenNeverSpendsTheOtherKind`), `ResetKindUITests`
  (`testReturnAndEscapeNeverConfirm`, `testButtonRuleByKinds`) and `ResetUITests`
  (`testARetryAfterNoAnswerReusesTheAttemptAndADefinitiveAnswerEndsIt`).
- **Proof.** The named PNGs and help files, and the passing test names. Report
  this feature as hosted view and unit tests only.

## Gotchas

- Nothing here is live-verifiable. Resets need a signed-in account that holds
  them, and spending one is irreversible. A verification run never clicks
  `Use reset…` or a confirm button on any instance with accounts.
- The PNGs show a view given a state. The tests named above, not the PNGs, prove
  that a click sends nothing until confirmed and spends only the picked kind.
- The fixture accounts are invented `@example.com` addresses. A PNG with a real
  address in it means the fixture changed; stop and report it.
