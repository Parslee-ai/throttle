#!/usr/bin/env bash
set -euo pipefail

# scripts/release.sh — the single entry point for cutting a Throttle release.
#
# Usage:
#   scripts/release.sh <version> [--unsigned] [--allow-unsigned]
#                                [--dry-run] [--skip-notarize]
#
#   <version>          marketing version without the leading v, e.g. 1.0.0
#   --unsigned         ad-hoc sign the app and leave the .pkg unsigned; never
#                      touches the vault. Refuses to publish a GitHub Release
#                      unless --allow-unsigned is also given.
#   --allow-unsigned   permit publishing an unsigned build, and fall back to an
#                      unsigned build when the vault cannot be reached.
#   --dry-run          print the plan and run the read-only preflight. Touches
#                      no vault, builds nothing, writes no git or GitHub state.
#   --skip-notarize    sign and package, but do not submit to Apple. The result
#                      is a signed but un-notarized .pkg that Gatekeeper will
#                      still block on a first launch; for pipeline debugging.
#
# What a full signed run does:
#   preflight -> version sync -> scripts/build.sh -> vault -> scratch keychain
#   -> codesign (hardened runtime, timestamped) -> scripts/package.sh (productsign)
#   -> notarytool submit --wait -> stapler -> spctl -> git tag + push
#   -> gh release create
#
# Prerequisites: Xcode, `az login`, `gh auth login`, a clean git tree on main.
# See docs/RELEASING.md.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="$ROOT_DIR/build"
APP_NAME="Throttle.app"
APP_PATH="$BUILD_DIR/$APP_NAME"
ENTITLEMENTS="$ROOT_DIR/Throttle.entitlements"
BUNDLE_ID="ai.parslee.throttle"

red()  { printf '\033[31m%s\033[0m\n' "$*" >&2; }
ok()   { printf '\033[32m%s\033[0m\n' "$*"; }
info() { printf '\033[36m%s\033[0m\n' "$*"; }
step() { printf '\n\033[1m==> %s\033[0m\n' "$*"; }

usage() {
    sed -n '4,20p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' >&2
    exit 2
}

# ---------------------------------------------------------------------------
# Arguments
# ---------------------------------------------------------------------------

VERSION=""
UNSIGNED=0
ALLOW_UNSIGNED=0
DRY_RUN=0
SKIP_NOTARIZE=0

while [ $# -gt 0 ]; do
    case "$1" in
        --unsigned)       UNSIGNED=1; shift ;;
        --allow-unsigned) ALLOW_UNSIGNED=1; shift ;;
        --dry-run)        DRY_RUN=1; shift ;;
        --skip-notarize)  SKIP_NOTARIZE=1; shift ;;
        -h|--help)        usage ;;
        -*)               red "unknown option: $1"; usage ;;
        *)
            if [ -z "$VERSION" ]; then VERSION="$1"; shift
            else red "unexpected argument: $1"; usage; fi
            ;;
    esac
done

[ -n "$VERSION" ] || { red "a version is required"; usage; }
if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+([-+][0-9A-Za-z.-]+)?$ ]]; then
    red "version must look like X.Y.Z without a leading v (got '$VERSION')"
    exit 2
fi

TAG="v$VERSION"
PKG_PATH="$BUILD_DIR/Throttle-$VERSION.pkg"
NOTES_PATH="$BUILD_DIR/release-notes-$TAG.md"
NOTARY_LOG="$BUILD_DIR/notary-log.json"

# ---------------------------------------------------------------------------
# Cleanup trap
# ---------------------------------------------------------------------------

# shellcheck source=scripts/lib/vault.sh
. "$ROOT_DIR/scripts/lib/vault.sh"

cleanup() {
    local rc=$?
    # Always tear down the scratch keychain, its search-list entry and the temp
    # root that briefly held the private keys, on every exit path including a
    # failure halfway through signing.
    throttle_keychain_cleanup
    if [ "$rc" -ne 0 ]; then
        red "release failed (rc=$rc); see the output above"
    fi
    exit "$rc"
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------

PREFLIGHT_BLOCKERS=0

# preflight_check <label> <ok:0|1> <detail>
# In a real run a failed check is fatal. In a dry run it is reported and
# counted, so the operator sees everything wrong at once instead of one thing
# per re-run.
preflight_check() {
    local label="$1" passed="$2" detail="${3:-}"
    if [ "$passed" -eq 0 ]; then
        ok "  [ok]   $label${detail:+ — $detail}"
        return 0
    fi
    PREFLIGHT_BLOCKERS=$((PREFLIGHT_BLOCKERS + 1))
    if [ "$DRY_RUN" -eq 1 ]; then
        red "  [WOULD BLOCK] $label${detail:+ — $detail}"
        return 0
    fi
    red "  [FAIL] $label${detail:+ — $detail}"
    return 1
}

have() { command -v "$1" >/dev/null 2>&1; }

step "Preflight"

for tool in git xcrun codesign pkgbuild productbuild pkgutil security openssl base64; do
    have "$tool" && s=0 || s=1
    preflight_check "tool: $tool" "$s"
done
have gh && s=0 || s=1
preflight_check "tool: gh" "$s"
if [ "$UNSIGNED" -eq 0 ]; then
    have az && s=0 || s=1
    preflight_check "tool: az" "$s"
fi

if [ -x "$ROOT_DIR/scripts/build.sh" ]; then
    preflight_check "scripts/build.sh is executable" 0
else
    preflight_check "scripts/build.sh is executable" 1 "expected at $ROOT_DIR/scripts/build.sh"
fi

# Clean tree. A release must describe a commit that exists, so anything
# uncommitted would ship under a tag that does not contain it.
if [ -z "$(git -C "$ROOT_DIR" status --porcelain)" ]; then
    preflight_check "git working tree is clean" 0
else
    preflight_check "git working tree is clean" 1 \
        "$(git -C "$ROOT_DIR" status --porcelain | wc -l | tr -d ' ') uncommitted path(s)"
fi

if git -C "$ROOT_DIR" rev-parse -q --verify "refs/tags/$TAG" >/dev/null 2>&1; then
    preflight_check "tag $TAG is free" 1 "already exists locally"
else
    preflight_check "tag $TAG is free" 0
fi

if have gh && gh auth status >/dev/null 2>&1; then
    preflight_check "gh is authenticated" 0
else
    preflight_check "gh is authenticated" 1 "run 'gh auth login'"
fi

if [ "$UNSIGNED" -eq 0 ]; then
    if have az && az account show >/dev/null 2>&1; then
        preflight_check "az is logged in" 0 \
            "subscription $(az account show --query name -o tsv 2>/dev/null)"
    else
        preflight_check "az is logged in" 1 "run 'az login'"
    fi
fi

# ---------------------------------------------------------------------------
# Version sync
# ---------------------------------------------------------------------------

PBXPROJ="$(find "$ROOT_DIR" -maxdepth 2 -name project.pbxproj -not -path '*/build/*' 2>/dev/null | head -1)"

current_marketing_version() {
    [ -n "$PBXPROJ" ] && [ -f "$PBXPROJ" ] || return 1
    sed -n 's/.*MARKETING_VERSION = \([^;]*\);.*/\1/p' "$PBXPROJ" \
        | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | sort -u | head -1
}

sync_version() {
    local current
    if [ -z "$PBXPROJ" ] || [ ! -f "$PBXPROJ" ]; then
        red "no project.pbxproj found; cannot check MARKETING_VERSION."
        red "The built app's CFBundleShortVersionString is verified after the build."
        return 0
    fi
    current="$(current_marketing_version || true)"
    if [ "$current" = "$VERSION" ]; then
        ok "  MARKETING_VERSION is already $VERSION"
        return 0
    fi
    info "  MARKETING_VERSION ${current:-<unset>} -> $VERSION"
    sed -i '' "s/MARKETING_VERSION = [^;]*;/MARKETING_VERSION = $VERSION;/g" "$PBXPROJ"
    current="$(current_marketing_version || true)"
    if [ "$current" != "$VERSION" ]; then
        red "failed to set MARKETING_VERSION to $VERSION in $PBXPROJ"
        return 1
    fi
    git -C "$ROOT_DIR" add "$PBXPROJ"
    git -C "$ROOT_DIR" commit -m "Release $VERSION: set MARKETING_VERSION" >/dev/null
    ok "  committed the version bump"
}

# ---------------------------------------------------------------------------
# Entitlements
# ---------------------------------------------------------------------------

# Hardened Runtime with exactly one entitlement. get-task-allow must never be
# present: it lets a debugger attach to the shipped app, and notarization
# rejects a Developer ID build that carries it.
ensure_entitlements() {
    if [ ! -f "$ENTITLEMENTS" ]; then
        info "  writing $ENTITLEMENTS (network client only)"
        cat > "$ENTITLEMENTS" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>com.apple.security.network.client</key>
	<true/>
</dict>
</plist>
PLIST
    fi
    if grep -q 'get-task-allow' "$ENTITLEMENTS"; then
        red "$ENTITLEMENTS contains get-task-allow; notarization would reject this build."
        return 1
    fi
    ok "  entitlements: com.apple.security.network.client only"
}

# ---------------------------------------------------------------------------
# Release notes
# ---------------------------------------------------------------------------

write_release_notes() {
    local notarized="$1"
    mkdir -p "$BUILD_DIR"
    {
        printf '## Install\n\n'
        if [ "$notarized" -eq 1 ]; then
            printf '1. Download `Throttle-%s.pkg` below.\n' "$VERSION"
            printf '2. Double-click it and follow the installer. Throttle installs to `/Applications`.\n'
            printf '3. Launch Throttle. It lives in the menu bar and has no Dock icon.\n\n'
            printf 'The package is signed with a Developer ID Installer certificate and notarized by Apple, so it installs without any Gatekeeper workaround.\n\n'
        else
            printf 'This build is **not signed with a Developer ID certificate and not notarized**, so macOS quarantines it on download. Remove the quarantine attribute before installing:\n\n'
            printf '```bash\n'
            printf 'xattr -dr com.apple.quarantine ~/Downloads/Throttle-%s.pkg\n' "$VERSION"
            printf 'sudo installer -pkg ~/Downloads/Throttle-%s.pkg -target /\n' "$VERSION"
            printf 'xattr -dr com.apple.quarantine /Applications/Throttle.app\n'
            printf '```\n\n'
            printf 'Then launch Throttle from `/Applications`. Right-click -> Open no longer works on macOS 15+; the quarantine commands above are the only path for an unsigned build.\n\n'
        fi
        printf 'Requires macOS 14 (Sonoma) or later.\n\n'
        printf '## Adding accounts\n\n'
        printf 'Click the menu bar item, choose **Add account**, pick Claude or Codex, and complete the login in your browser. Accounts persist across relaunches.\n'
    } > "$NOTES_PATH"
    ok "  release notes: $NOTES_PATH"
}

# ---------------------------------------------------------------------------
# Plan
# ---------------------------------------------------------------------------

print_plan() {
    local mode="signed"
    [ "$UNSIGNED" -eq 1 ] && mode="unsigned (ad-hoc)"
    printf '  version            %s (tag %s)\n' "$VERSION" "$TAG"
    printf '  mode               %s\n' "$mode"
    printf '  app                %s\n' "$APP_PATH"
    printf '  package            %s\n' "$PKG_PATH"
    if [ "$UNSIGNED" -eq 0 ]; then
        printf '  vault              %s (prefix %s / %s)\n' \
            "$THROTTLE_RELEASE_VAULT" "$THROTTLE_RELEASE_SECRET_PREFIX" \
            "$THROTTLE_RELEASE_NOTARY_SECRET_PREFIX"
        if [ "$SKIP_NOTARIZE" -eq 1 ]; then
            printf '  notarization       SKIPPED (--skip-notarize)\n'
        else
            printf '  notarization       xcrun notarytool submit --wait, then staple\n'
        fi
    else
        printf '  vault              not used\n'
    fi
    if [ "$ALLOW_UNSIGNED" -eq 0 ] && { [ "$UNSIGNED" -eq 1 ] || [ "$SKIP_NOTARIZE" -eq 1 ]; }; then
        printf '  github release     REFUSED (not notarized, and no --allow-unsigned)\n'
    else
        printf '  github release     gh release create %s with the .pkg attached\n' "$TAG"
    fi
    local n=1
    printf '\n  steps:\n'
    printf '    %d. sync MARKETING_VERSION to %s and commit if it differs\n' "$n" "$VERSION"; n=$((n + 1))
    printf '    %d. scripts/build.sh\n' "$n"; n=$((n + 1))
    if [ "$UNSIGNED" -eq 1 ]; then
        printf '    %d. codesign -s - --force --deep (ad-hoc)\n' "$n"; n=$((n + 1))
        printf '    %d. scripts/package.sh %s (unsigned)\n' "$n" "$VERSION"; n=$((n + 1))
    else
        printf '    %d. fetch identities into a scratch keychain, codesign with hardened runtime\n' "$n"; n=$((n + 1))
        printf '    %d. scripts/package.sh %s --identity "<Developer ID Installer>"\n' "$n" "$VERSION"; n=$((n + 1))
        if [ "$SKIP_NOTARIZE" -eq 1 ]; then
            printf '    %d. notarization skipped\n' "$n"; n=$((n + 1))
        else
            printf '    %d. notarize, staple, spctl -a -vv -t install\n' "$n"; n=$((n + 1))
        fi
    fi
    printf '    %d. write %s\n' "$n" "$NOTES_PATH"; n=$((n + 1))
    if [ "$ALLOW_UNSIGNED" -eq 0 ] && { [ "$UNSIGNED" -eq 1 ] || [ "$SKIP_NOTARIZE" -eq 1 ]; }; then
        printf '    %d. STOP: no tag, no push, no GitHub Release (not a notarized build,\n' "$n"
        printf '       and --allow-unsigned was not given)\n'
    else
        printf '    %d. git tag %s && git push origin main --tags\n' "$n" "$TAG"; n=$((n + 1))
        printf '    %d. gh release create %s %s\n' "$n" "$TAG" "$PKG_PATH"
    fi
}

if [ "$DRY_RUN" -eq 1 ]; then
    step "Plan (DRY RUN)"
    print_plan
    printf '\n'
    if [ "$PREFLIGHT_BLOCKERS" -gt 0 ]; then
        red "DRY RUN complete: $PREFLIGHT_BLOCKERS preflight item(s) would block a real release."
    else
        ok "DRY RUN complete: preflight is clean."
    fi
    info "Nothing was built, no vault was read, and no git or GitHub state changed."
    exit 0
fi

step "Plan"
print_plan

# ---------------------------------------------------------------------------
# Build
# ---------------------------------------------------------------------------

step "Syncing version"
sync_version

step "Building"
"$ROOT_DIR/scripts/build.sh"
[ -d "$APP_PATH" ] || { red "scripts/build.sh did not produce $APP_PATH"; exit 3; }

BUILT_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' \
    "$APP_PATH/Contents/Info.plist" 2>/dev/null || true)"
if [ "$BUILT_VERSION" != "$VERSION" ]; then
    red "the built app reports CFBundleShortVersionString '$BUILT_VERSION', expected '$VERSION'."
    red "The release tag and the shipped app version must agree (ISC-22)."
    exit 3
fi
ok "  $APP_NAME $BUILT_VERSION"

step "Entitlements"
ensure_entitlements

# ---------------------------------------------------------------------------
# Sign
# ---------------------------------------------------------------------------

SIGNED=0

if [ "$UNSIGNED" -eq 0 ]; then
    step "Signing material"
    if ! throttle_vault_preflight; then
        if [ "$ALLOW_UNSIGNED" -eq 1 ]; then
            red "vault unreachable; --allow-unsigned given, falling back to an ad-hoc build."
            UNSIGNED=1
        else
            red "pass --unsigned --allow-unsigned to cut a release without the vault."
            exit 1
        fi
    elif ! throttle_keychain_bootstrap; then
        if [ "$ALLOW_UNSIGNED" -eq 1 ]; then
            red "could not stand up the signing identities; --allow-unsigned given,"
            red "falling back to an ad-hoc build."
            throttle_keychain_cleanup
            UNSIGNED=1
        else
            exit 1
        fi
    fi
fi

if [ "$UNSIGNED" -eq 1 ]; then
    step "Ad-hoc signing"
    # macOS 26 refuses to run fully unsigned code under any setting, so even the
    # fallback path signs — ad-hoc, which carries no identity and satisfies the
    # loader while Gatekeeper still requires the quarantine removal documented in
    # the release notes.
    codesign -s - --force --deep "$APP_PATH"
    codesign --verify --deep --strict "$APP_PATH"
    printf '\n\033[1;33m%s\033[0m\n' "UNSIGNED BUILD"
    printf 'Ad-hoc signed, not notarized. Users must remove the quarantine attribute.\n'
else
    step "Signing $APP_NAME"
    codesign --force --options runtime --timestamp \
        --sign "$THROTTLE_APP_IDENTITY" \
        --keychain "$THROTTLE_KEYCHAIN" \
        --entitlements "$ENTITLEMENTS" \
        "$APP_PATH"
    codesign --verify --deep --strict "$APP_PATH"

    # Prove the three things ISC-32 asserts rather than assuming codesign did
    # what it was told: the Developer ID authority, the hardened runtime flag,
    # and a secure timestamp. A missing timestamp only surfaces at notarization.
    SIGINFO="$(codesign -dv --verbose=2 "$APP_PATH" 2>&1)"
    printf '%s\n' "$SIGINFO" | grep -q 'Authority=Developer ID Application' \
        || { red "signature is not anchored to a Developer ID Application authority"; exit 3; }
    printf '%s\n' "$SIGINFO" | grep -q 'flags=.*runtime' \
        || { red "hardened runtime flag is missing from the signature"; exit 3; }
    printf '%s\n' "$SIGINFO" | grep -q '^Timestamp=' \
        || { red "signature carries no secure timestamp"; exit 3; }
    ENTS="$(codesign -d --entitlements :- "$APP_PATH" 2>/dev/null || true)"
    if printf '%s\n' "$ENTS" | grep -q 'get-task-allow'; then
        red "the signed app carries get-task-allow"
        exit 3
    fi
    ok "  Developer ID Application, hardened runtime, timestamped, no get-task-allow"
    SIGNED=1
fi

# ---------------------------------------------------------------------------
# Package
# ---------------------------------------------------------------------------

step "Packaging"
if [ "$SIGNED" -eq 1 ] && [ -n "${THROTTLE_INSTALLER_IDENTITY:-}" ]; then
    "$ROOT_DIR/scripts/package.sh" "$VERSION" \
        --identity "$THROTTLE_INSTALLER_IDENTITY" \
        --keychain "$THROTTLE_KEYCHAIN"
else
    "$ROOT_DIR/scripts/package.sh" "$VERSION"
fi
[ -f "$PKG_PATH" ] || { red "scripts/package.sh did not produce $PKG_PATH"; exit 3; }

# ---------------------------------------------------------------------------
# Notarize
# ---------------------------------------------------------------------------

NOTARIZED=0

if [ "$SIGNED" -eq 1 ] && [ -n "${THROTTLE_INSTALLER_IDENTITY:-}" ] && [ "$SKIP_NOTARIZE" -eq 0 ]; then
    step "Notarizing"
    # --wait blocks until Apple returns a verdict (usually under two minutes),
    # which is required because stapling cannot run before acceptance.
    SUBMIT_JSON="$(xcrun notarytool submit "$PKG_PATH" \
        --apple-id "$NOTARY_APPLE_ID" \
        --team-id "$NOTARY_TEAM_ID" \
        --password "$NOTARY_PASSWORD" \
        --output-format json --wait 2>&1 || true)"
    SUBMISSION_ID="$(printf '%s\n' "$SUBMIT_JSON" \
        | sed -n 's/.*"id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)"
    SUBMIT_STATUS="$(printf '%s\n' "$SUBMIT_JSON" \
        | sed -n 's/.*"status"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)"

    if [ -z "$SUBMISSION_ID" ]; then
        red "notarytool returned no submission id:"
        printf '%s\n' "$SUBMIT_JSON" | sed 's/^/  /' >&2
        exit 3
    fi

    # Pull the log even on success. Apple returns Accepted while still recording
    # warnings there, and the one that matters — "unable to build chain to
    # self-signed root" — means the Installer intermediate was missing and the
    # package will be rejected on a user's machine despite this run looking green.
    xcrun notarytool log "$SUBMISSION_ID" \
        --apple-id "$NOTARY_APPLE_ID" \
        --team-id "$NOTARY_TEAM_ID" \
        --password "$NOTARY_PASSWORD" \
        "$NOTARY_LOG" >/dev/null 2>&1 || true
    if [ -f "$NOTARY_LOG" ]; then
        ok "  log: $NOTARY_LOG"
    else
        red "  could not retrieve the notarization log for $SUBMISSION_ID"
    fi

    if [ "$SUBMIT_STATUS" != "Accepted" ]; then
        red "notarization status: ${SUBMIT_STATUS:-unknown} (submission $SUBMISSION_ID)"
        [ -f "$NOTARY_LOG" ] && sed 's/^/  /' "$NOTARY_LOG" >&2
        exit 3
    fi
    if [ -f "$NOTARY_LOG" ] && grep -q 'unable to build chain' "$NOTARY_LOG"; then
        red "notarization accepted the submission but reported an incomplete"
        red "certificate chain. The Developer ID G2 intermediate did not make it"
        red "into the scratch keychain; the package would be refused on install."
        grep -n 'unable to build chain' "$NOTARY_LOG" | sed 's/^/  /' >&2
        exit 3
    fi
    ok "  Accepted (submission $SUBMISSION_ID)"

    step "Stapling"
    # Staple so a first launch works offline; without a stapled ticket Gatekeeper
    # falls back to an online check that fails on a fresh download with no network.
    xcrun stapler staple "$PKG_PATH"
    xcrun stapler validate "$PKG_PATH"

    SPCTL="$(spctl -a -vv -t install "$PKG_PATH" 2>&1 || true)"
    printf '%s\n' "$SPCTL" | sed 's/^/  /'
    printf '%s\n' "$SPCTL" | grep -q 'accepted' \
        || { red "spctl did not accept the package"; exit 3; }
    printf '%s\n' "$SPCTL" | grep -q 'source=Notarized Developer ID' \
        || { red "spctl did not report source=Notarized Developer ID"; exit 3; }
    ok "  accepted, source=Notarized Developer ID"
    NOTARIZED=1
elif [ "$SKIP_NOTARIZE" -eq 1 ]; then
    info "Skipping notarization (--skip-notarize). The .pkg is signed but Gatekeeper will block it."
fi

# ---------------------------------------------------------------------------
# Publish
# ---------------------------------------------------------------------------

step "Release notes"
write_release_notes "$NOTARIZED"

if [ "$NOTARIZED" -eq 0 ] && [ "$ALLOW_UNSIGNED" -eq 0 ]; then
    printf '\n'
    red "NOT PUBLISHED"
    red "This build is not a notarized Developer ID package, so the GitHub Release"
    red "step is refused. The artifacts are here:"
    red "  $PKG_PATH"
    red "  $NOTES_PATH"
    red "Re-run with --allow-unsigned to publish it anyway."
    exit 0
fi

step "Tagging"
git -C "$ROOT_DIR" tag "$TAG"
git -C "$ROOT_DIR" push origin main --tags
ok "  pushed $TAG"

step "Publishing"
gh release create "$TAG" "$PKG_PATH" \
    --title "Throttle $VERSION" \
    --notes-file "$NOTES_PATH"

ASSETS="$(gh release view "$TAG" --json assets --jq '.assets[].name' 2>/dev/null || true)"
printf '  assets: %s\n' "$(printf '%s' "$ASSETS" | tr '\n' ' ')"

printf '\n'
ok "Released Throttle $VERSION"
ok "  $PKG_PATH"
