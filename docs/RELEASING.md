# Releasing Throttle

Releases are cut **locally**, from a Mac, by one command:

```bash
scripts/release.sh 1.0.0
```

GitHub Actions builds and tests every push and pull request, but it never signs
and never publishes. No signing material is in the repository, in GitHub
Secrets, or in any workflow. The certificates and notarization credentials live
in an Azure Key Vault that only a logged-in operator can read.

## What the command does

1. **Preflight.** Checks for the tools it needs, a clean git working tree, a
   free `v<version>` tag, `gh auth status` and `az account show`.
2. **Version sync.** Sets `MARKETING_VERSION` in the Xcode project to the
   requested version and commits that change if it differed.
3. **Build.** Runs `scripts/build.sh`, then refuses to continue unless the
   built app's `CFBundleShortVersionString` equals the version being released.
4. **Signing material.** Fetches the Developer ID Application and Developer ID
   Installer certificates from the vault into a **scratch keychain** created for
   this run, and proves both work by signing a throwaway binary and a throwaway
   package before the real signing starts.
5. **Sign the app.** `codesign` with the hardened runtime, a secure timestamp
   and `Throttle.entitlements`, then verifies the Developer ID authority, the
   runtime flag, the timestamp, and the absence of `get-task-allow`.
6. **Package.** Runs `scripts/package.sh`, which stages the bundle, forces the
   payload non-relocatable, builds the component and distribution packages, and
   signs the result with `productsign`.
7. **Notarize.** `xcrun notarytool submit --wait`, then pulls the notarization
   log to `build/notary-log.json` **even on success**, then staples the ticket
   and requires `spctl -a -vv -t install` to print `accepted` and
   `source=Notarized Developer ID`.
8. **Publish.** Tags `v<version>`, pushes `main` and tags, and creates the
   GitHub Release with the `.pkg` attached and generated install notes.

The scratch keychain, its search-list entry and the temporary certificate files
are removed on every exit path, including failures and interrupts.

## Prerequisites

Run once per release machine:

- **Xcode** with the command line tools, on macOS.
- **`az login`**, with the `Key Vault Secrets User` role (or Administrator) on
  the vault.
- **Apple Developer team membership.** The certificates alone are not enough.
  If the operator's Apple ID is not on the team that issued them, `codesign` and
  `productsign` treat the identities as untrusted and refuse to sign.
- **`gh auth login`**, with push access to the repository.
- A **clean git working tree** on `main`.

## Options

| Flag | Effect |
|---|---|
| `--dry-run` | Runs the preflight and prints the plan. Reads no vault, builds nothing, writes no git or GitHub state. Preflight problems are reported as `WOULD BLOCK` instead of aborting, so you see all of them at once. |
| `--unsigned` | Ad-hoc signs the app, leaves the package unsigned, never touches the vault, and prints `UNSIGNED BUILD` once. Refuses to publish a GitHub Release unless `--allow-unsigned` is also given. |
| `--allow-unsigned` | Permits publishing a build that is not a notarized Developer ID package. Also lets a signed run fall back to an ad-hoc build when the vault is unreachable, instead of failing. |
| `--skip-notarize` | Signs and packages but does not submit to Apple. The result is signed but Gatekeeper still blocks it, so publishing is refused unless `--allow-unsigned` is also given. For debugging the pipeline only. |

`scripts/package.sh` can also be run on its own against any built app:

```bash
scripts/package.sh 1.0.0                             # unsigned .pkg
scripts/package.sh 1.0.0 --identity "Developer ID Installer: ..." \
                         --keychain /path/to.keychain-db
scripts/package.sh 1.0.0 --app /path/Throttle.app --out /tmp/out.pkg
```

## Environment overrides

| Variable | Default | Meaning |
|---|---|---|
| `THROTTLE_RELEASE_VAULT` | `car-releases-kv` | Key Vault name. |
| `THROTTLE_RELEASE_SECRET_PREFIX` | `car-codesign` | Prefix for the certificate secrets. |
| `THROTTLE_RELEASE_NOTARY_SECRET_PREFIX` | `car-notary` | Prefix for the notarization secrets. |
| `THROTTLE_RELEASE_AZURE_SUBSCRIPTION` | unset | Pins every vault call to one subscription. |

The defaults carry a `car-` prefix because the certificates belong to Parslee
and are shared with the `car` project; they are not Throttle-specific.

## What the vault holds

Names only. Nothing below is ever printed, logged, committed, or written
anywhere outside the per-run scratch keychain and a `0700` temporary directory
that is deleted on exit.

**Developer ID Application** (signs `Throttle.app`)

- `car-codesign-app-identity-cn`
- `car-codesign-app-password`
- `car-codesign-app-p12-chunks`, `car-codesign-app-p12-<i>`

**Developer ID Installer** (signs `Throttle-<version>.pkg`)

- `car-codesign-installer-identity-cn`
- `car-codesign-installer-password`
- `car-codesign-installer-p12-chunks`, `car-codesign-installer-p12-<i>`
- `car-codesign-installer-g2-ca`

**Notarization**

- `car-notary-apple-id`
- `car-notary-team-id`
- `car-notary-password` (an app-specific password from appleid.apple.com, not
  an iCloud password)

The `.p12` bundles are base64-encoded and split across numbered secrets because
a single Key Vault secret cannot hold one whole. The `-chunks` secret holds the
count.

## Failure modes

Each of these cost the `car` project a real release. The scripts defend against
all of them; this section is here so a new symptom is recognized rather than
re-diagnosed.

### `trustd` cache poisoning

**Symptom.** A perfectly valid certificate is rejected with
`CSSMERR_TP_NOT_TRUSTED`, and a release that failed once keeps failing while a
manual `killall trustd` makes it work exactly once.

**Cause.** Trust evaluations are cached per user, and a poisoned entry survives
keychain deletion and the creation of new scratch keychains. The condition is
self-poisoning: every failed run dirties the cache for the next one. `car`
measured 7/7 successful signings with a clean cache against 1/5 with a poisoned
one.

**Defense.** `scripts/lib/vault.sh` runs `killall trustd` before creating the
scratch keychain. It is a per-user daemon, needs no `sudo`, and respawns on
demand.

### Incomplete Installer certificate chain (the G2 intermediate)

**Symptom.** `security find-identity` lists the Developer ID Installer identity
and looks healthy, then `productsign` fails an hour later with "Could not find
appropriate signing identity", or notarization returns an `unable to build
chain to self-signed root` entry in its log.

**Cause.** Developer ID Installer certificates chain through the **Developer ID
Certification Authority - G2** intermediate, which is not in the macOS System
Roots. Without it in the scratch keychain the chain cannot be built. This is
load-bearing: `car` shipped without a `.pkg` from v0.34.0 to v0.53.0 because of
it.

**Defense.** The bootstrap imports the G2 intermediate from Apple's public CA
endpoint and, as a fallback, from the vault copy. It then proves the chain by
actually signing a probe package with `productsign`, because
`security find-identity -v` advertises "valid identities only" while still
listing chain-failed identities with an inline `(CSSMERR_TP_NOT_TRUSTED)`
annotation. A name match alone is a false positive that let a `car` release
build for 55 minutes before dying at the packaging step. The release also greps
`build/notary-log.json` for `unable to build chain` and fails even when Apple
returned `Accepted`.

### Scratch keychain locked mid-release

**Symptom.** `codesign` fails with `errSecInternalComponent` partway through a
long release, naming nothing.

**Cause.** `security set-keychain-settings -t <n>` is an **inactivity** timeout,
and a long build phase with no keychain traffic is exactly the window that trips
it. A `car` release measured 85 minutes between keychain creation and the
signing step.

**Defense.** The scratch keychain is created with no timeout
(`set-keychain-settings -u`). That is safe only because it is ephemeral: a
random `openssl rand` password, created per run, deleted by the cleanup trap on
every exit path. Never do this to a login keychain.

### Signing identity invisible despite `--keychain`

**Symptom.** `find-identity` lists the leaf cleanly, then `codesign` reports no
identity found.

**Cause.** `codesign` and `productsign` resolve identities through the **user
keychain search list**. An explicit `--keychain` selects where key material is
read from but does not make an isolated identity discoverable.

**Defense.** The bootstrap joins the populated scratch keychain to the search
list after every import completes, then still passes `--keychain` explicitly so
key use is pinned to that file rather than to whichever matching identity
appears first. It also calls `security set-key-partition-list` with
`apple-tool:,apple:,codesign:` — `codesign:` must be in that list, or the first
real use of the key dies with `errSecInternalComponent`.

### Orphaned keychain in the search list

**Symptom.** `security show-keychain-info` on the login keychain reports
"Unable to obtain authorization for this operation" on a machine where no
release is running.

**Cause.** A release that died to a `SIGKILL` left a search-list entry no trap
ever removed, or the trap ran after macOS had already purged `/var/folders`, so
a file-existence guard skipped the cleanup. One `car` operator carried an entry
for a month.

**Defense.** Pruning is scoped to the owned `throttle-release-` basename, runs
at **startup** as well as on exit, and removes matching entries whether or not
their file still exists. It also de-duplicates the search list without
reordering it.

### Relocatable payload

**Symptom.** A signed install silently merges into a stale development copy of
the app somewhere else on disk, and once that copy is renamed away, a later
install places the app nowhere at all while Installer.app reports "Install
Succeeded".

**Cause.** `pkgbuild --analyze` emits the Installer defaults, and
`BundleIsRelocatable` defaults to **true**, which lets `installd` redirect the
payload onto any on-disk bundle with the same `CFBundleIdentifier`.

**Defense.** `scripts/package.sh` rewrites every entry of the analyzed component
plist to `BundleIsRelocatable=false`, then verifies the built package rather
than trusting the input: it expands the `.pkg` and requires the `PackageInfo` to
carry an empty `<relocate/>` element. It also reads the payload's bill of
materials and requires it to own exactly `./Throttle.app` and never
`./Applications`, so installation cannot alter the real `/Applications`
directory's ownership or permissions.

### Installer OS floor drifting from the app's

**Symptom.** The installer admits a user whose macOS is too old for the app, or
refuses a user the app supports.

**Cause.** Two hand-maintained constants: the app's `LSMinimumSystemVersion` and
the Distribution's `<os-version min>`.

**Defense.** `scripts/package.sh` reads the floor from the built bundle's own
`Info.plist` and writes that one value into the Distribution. A malformed value
is fatal rather than replaced with a guess.

## What the in-app updater expects

Throttle's **Check for Updates** button reads
`GET /repos/Parslee-ai/throttle/releases/latest` and installs only what this
script publishes, exactly as it publishes it. A release the updater should offer
needs all of the following, and `scripts/release.sh` produces every one:

- A published release (not a draft, not a pre-release). GitHub's `latest`
  endpoint never returns pre-releases, so `-rc.N` builds are never offered.
- Tag `v<version>`, where `<version>` matches
  `^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?$`.
- An asset named exactly `Throttle-<version>.pkg`, served from
  `https://github.com/Parslee-ai/throttle/releases/download/v<version>/Throttle-<version>.pkg`,
  whose downloaded size matches the size GitHub lists, and whose SHA-256
  matches the asset's `digest` (`sha256:<64 lowercase hex>`) when GitHub lists
  one. GitHub computes the digest itself on upload.
- A package signed with a **Developer ID Installer** certificate from the **same
  team** as the running app's Developer ID Application signature, notarized and
  stapled, so `pkgutil --check-signature` and `spctl --assess --type install`
  both pass.
- A `Distribution` whose every `pkg-ref` has `id="ai.parslee.throttle"` and
  whose one versioned `pkg-ref` has `version="<version>"`, exactly as
  `scripts/package.sh` writes it. This is what stops the same team's other
  products, and older Throttle packages, from being installed as an update.
- No `Scripts` entry anywhere in the archive (`xar -tf`). Throttle's packages
  have no install scripts; adding one breaks updates.

The app checks all of this before it asks for a password. The root step then
checks it again on its own copy: it refuses a source that is not a regular
file, copies at most one byte more than the verified size into a fresh
root-owned directory (so a file that grew is caught rather than silently cut to
size), requires that copy's exact size and SHA-256 to match what the app
verified, and repeats the signature, team, notarization, `Distribution` and
no-`Scripts` checks before `installer` reads it. It runs under `env -i` with
only `PATH` set. A refusal there exits 65, and the app reports it as a failed
verification and deletes the download.

Keep `pkgutil` in both places. `spctl --assess` alone reported a package whose
payload was modified after signing as `accepted` and `Notarized Developer ID`;
only `pkgutil --check-signature` rejected it (`package is invalid`).

Anything else is reported to the user as "no installable update" or as a failed
verification, and nothing is installed. Renaming the asset, changing the
package identifier, moving the repository, or changing the signing team breaks
updates for every copy already installed, so treat those as breaking changes.

Ad-hoc and unsigned builds (an `--unsigned` release, or a local
`scripts/build.sh` product that was never signed) have no team to compare
against and refuse to install updates.

### Testing an update end to end

The environment variable `THROTTLE_UPDATE_CURRENT_VERSION` makes Throttle
believe it is running that version, so a real published release looks newer. It
is ignored unless it holds a valid version (no leading `v`). To exercise the
whole path against the live release:

```bash
# Quit the running Throttle first, then, with the signed release installed:
THROTTLE_UPDATE_CURRENT_VERSION=0.0.1 /Applications/Throttle.app/Contents/MacOS/Throttle
```

Click **Check for Updates**, then **Install**, and approve the administrator
prompt. Throttle downloads the latest release, verifies it, reinstalls it over
`/Applications/Throttle.app`, and relaunches. The relaunched copy starts
through `open`, without the variable, so it reports its real version and shows
it is up to date. Cancelling the prompt should show "Install cancelled" and
change nothing.

## Unsigned builds

`scripts/release.sh 1.0.0 --unsigned` produces an ad-hoc signed app and an
unsigned `.pkg`, and prints `UNSIGNED BUILD` once.

Ad-hoc signing is not optional on modern macOS: fully unsigned code does not run
under any setting, while ad-hoc signed code runs once the quarantine attribute
is removed. Right-click to Open was removed in macOS Sequoia, so the generated
release notes give the only working path:

```bash
xattr -dr com.apple.quarantine ~/Downloads/Throttle-1.0.0.pkg
sudo installer -pkg ~/Downloads/Throttle-1.0.0.pkg -target /
xattr -dr com.apple.quarantine /Applications/Throttle.app
```

Publishing such a build to GitHub Releases requires `--allow-unsigned` on top of
`--unsigned`. Without it the script builds the artifacts, prints where they are,
and stops.

## Recovering from a partial release

Every step before the tag is safe to repeat: re-run the same command. Once
`git tag` and `git push --tags` have run, the tag exists and the preflight will
refuse to start again. Delete the tag locally and on the remote, then re-run:

```bash
git tag -d v1.0.0
git push origin :refs/tags/v1.0.0
```

If a GitHub Release was already created, delete it with
`gh release delete v1.0.0` first.
