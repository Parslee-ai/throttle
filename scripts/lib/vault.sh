#!/usr/bin/env bash
# scripts/lib/vault.sh — Azure Key Vault -> scratch keychain helpers for Throttle releases.
#
# Sourced by scripts/release.sh; it is not a standalone entry point. Every hard-won
# safety measure in here was paid for by a failed release of the `car` project
# (Parslee-ai/car); the comments name the incident so nobody "simplifies" one away.
#
# Contract for the caller:
#   throttle_vault_preflight                 -> vault is reachable from this az login
#   throttle_keychain_bootstrap              -> scratch keychain exists and holds the
#                                               Developer ID Application + Installer
#                                               identities, joined to the search list
#   throttle_keychain_cleanup                -> idempotent teardown, safe in a trap
#
# After bootstrap these globals are set:
#   THROTTLE_APP_IDENTITY        Developer ID Application CN
#   THROTTLE_INSTALLER_IDENTITY  Developer ID Installer CN (empty if not in the vault)
#   THROTTLE_KEYCHAIN            path to the scratch keychain
#   NOTARY_APPLE_ID / NOTARY_TEAM_ID / NOTARY_PASSWORD  notarytool credentials
#
# Nothing in here ever prints a secret. Values arrive on stdout of `az` and go
# straight into shell variables or files under a 0700 temp root.

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

# Vault holding the Apple Developer release material. Shared with `car`; the
# certificates are Parslee's, not this project's, which is why the default names
# carry the `car-` prefix. Both are overridable so a fork can point at its own.
THROTTLE_RELEASE_VAULT="${THROTTLE_RELEASE_VAULT:-car-releases-kv}"
# Prefix for the code-signing secrets: <prefix>-app-identity-cn, <prefix>-app-password,
# <prefix>-app-p12-chunks, <prefix>-app-p12-<i>, and the -installer- equivalents.
THROTTLE_RELEASE_SECRET_PREFIX="${THROTTLE_RELEASE_SECRET_PREFIX:-car-codesign}"
# Prefix for the notarization secrets: <prefix>-apple-id, <prefix>-team-id, <prefix>-password.
THROTTLE_RELEASE_NOTARY_SECRET_PREFIX="${THROTTLE_RELEASE_NOTARY_SECRET_PREFIX:-car-notary}"

# Owned basename prefix for scratch keychains. Nothing else on the machine may
# use it, which is what makes the search-list pruning below safe to apply
# unconditionally to every entry that matches.
THROTTLE_KEYCHAIN_PREFIX="throttle-release-"

THROTTLE_APP_IDENTITY="${THROTTLE_APP_IDENTITY:-}"
THROTTLE_INSTALLER_IDENTITY="${THROTTLE_INSTALLER_IDENTITY:-}"
THROTTLE_KEYCHAIN="${THROTTLE_KEYCHAIN:-}"
THROTTLE_VAULT_TMPROOT="${THROTTLE_VAULT_TMPROOT:-}"
_THROTTLE_KEYCHAIN_PASSWORD=""

# ---------------------------------------------------------------------------
# Output helpers (printf only; see the ISA's no-secret-echo rule)
# ---------------------------------------------------------------------------
if ! command -v vault_red >/dev/null 2>&1; then
    vault_red()  { printf '\033[31m%s\033[0m\n' "$*" >&2; }
    vault_ok()   { printf '\033[32m%s\033[0m\n' "$*"; }
    vault_info() { printf '\033[36m%s\033[0m\n' "$*"; }
fi

# ---------------------------------------------------------------------------
# Azure
# ---------------------------------------------------------------------------

# Every vault call goes through this wrapper so a release can be pinned to one
# subscription instead of depending on whatever `az` was last pointed at.
# A wrapper rather than an array because macOS ships bash 3.2, where expanding
# an empty array under `set -u` is an unbound-variable error.
throttle_az_vault() {
    if [ -n "${THROTTLE_RELEASE_AZURE_SUBSCRIPTION:-}" ]; then
        az "$@" --subscription "$THROTTLE_RELEASE_AZURE_SUBSCRIPTION"
    else
        az "$@"
    fi
}

# Reachability check with an actionable diagnosis. A vault in a DIFFERENT
# subscription is reported by `az` exactly like one that does not exist, so a
# wrong-subscription run otherwise reads as a missing vault or an RBAC problem.
throttle_vault_preflight() {
    local cur_sub cur_id
    if throttle_az_vault keyvault show --name "$THROTTLE_RELEASE_VAULT" -o none 2>/dev/null; then
        return 0
    fi
    vault_red "cannot see vault '$THROTTLE_RELEASE_VAULT' from the current az login."
    cur_sub=$(az account show --query "name" -o tsv 2>/dev/null || printf '<none>')
    cur_id=$(az account show --query "id" -o tsv 2>/dev/null || printf '<none>')
    vault_red "az is using subscription: $cur_sub ($cur_id)"
    if [ -z "${THROTTLE_RELEASE_AZURE_SUBSCRIPTION:-}" ]; then
        vault_red "If the vault lives in another subscription, pin this run with"
        vault_red "  THROTTLE_RELEASE_AZURE_SUBSCRIPTION=<id> scripts/release.sh ..."
        vault_red "or change the default with 'az account set --subscription <id>'."
    else
        vault_red "THROTTLE_RELEASE_AZURE_SUBSCRIPTION is pinned to"
        vault_red "$THROTTLE_RELEASE_AZURE_SUBSCRIPTION, so the vault is absent there"
        vault_red "or you lack RBAC on it."
    fi
    vault_red "Otherwise run 'az login', or set THROTTLE_RELEASE_VAULT=<name>."
    return 1
}

throttle_vault_get_or_empty() {
    throttle_az_vault keyvault secret show \
        --vault-name "$THROTTLE_RELEASE_VAULT" --name "$1" --query value -o tsv 2>/dev/null || true
}

throttle_vault_get() {
    local value
    value=$(throttle_vault_get_or_empty "$1")
    if [ -z "$value" ]; then
        vault_red "required secret '$1' is missing from vault '$THROTTLE_RELEASE_VAULT'."
        return 1
    fi
    printf '%s\n' "$value"
}

# Reassemble a chunked PKCS#12 bundle. Key Vault caps a secret's value, so the
# bundles are stored base64-encoded and split across <base>-1 .. <base>-N with
# the count in <base>-chunks.
#   $1 secret base name (e.g. car-codesign-app-p12)
#   $2 destination path for the decoded .p12
throttle_vault_get_p12() {
    local base="$1" dest="$2" count b64 i
    count=$(throttle_vault_get "${base}-chunks") || return 1
    case "$count" in
        ''|*[!0-9]*) vault_red "'${base}-chunks' is not a number"; return 1 ;;
    esac
    b64="${dest}.b64"
    : > "$b64"
    i=1
    while [ "$i" -le "$count" ]; do
        throttle_vault_get "${base}-${i}" >> "$b64" || return 1
        i=$((i + 1))
    done
    base64 -d < "$b64" > "$dest" || { vault_red "could not decode $base"; return 1; }
    rm -f "$b64"
    [ -s "$dest" ] || { vault_red "$base decoded to an empty file"; return 1; }
    return 0
}

# ---------------------------------------------------------------------------
# Keychain search-list hygiene
# ---------------------------------------------------------------------------

# Drop throttle-release-* scratch keychains from the user search list and remove
# duplicate entries without changing their first-seen order. `$1`, when given, is
# removed whether or not its file exists.
#
# Why this exists: a release must not leave persistent machine state behind, and
# a dangling search-list member is visibly unhealthy — `security
# show-keychain-info` on the login keychain starts reporting "Unable to obtain
# authorization for this operation" on a machine carrying one (car#1265). Entries
# get orphaned two ways and both are covered: the trap never ran (SIGKILL), or
# the trap ran after macOS purged /var/folders, so a file-existence guard skipped
# the prune. Hence this also runs at STARTUP, not only on exit.
throttle_keychain_prune() {
    local drop="${1:-}"
    local kept=() entry existing duplicate i changed=0
    while IFS= read -r entry; do
        [ -z "$entry" ] && continue
        if [ -n "$drop" ] && [ "$entry" = "$drop" ]; then
            changed=1
            continue
        fi
        case "${entry##*/}" in
            "${THROTTLE_KEYCHAIN_PREFIX}"*)
                vault_info "    pruning Throttle scratch keychain from search list: $entry"
                changed=1
                continue
                ;;
        esac
        duplicate=0
        for ((i = 0; i < ${#kept[@]}; i++)); do
            existing="${kept[$i]}"
            if [ "$existing" = "$entry" ]; then
                duplicate=1
                changed=1
                vault_info "    pruning duplicate keychain from search list: $entry"
                break
            fi
        done
        [ "$duplicate" -eq 1 ] && continue
        kept[${#kept[@]}]="$entry"
    done < <(security list-keychains -d user | tr -d '"' | sed 's/^[[:space:]]*//')

    if [ "$changed" -eq 1 ]; then
        if [ ${#kept[@]} -gt 0 ]; then
            security list-keychains -d user -s "${kept[@]}" >/dev/null 2>&1 || true
        else
            security list-keychains -d user -s >/dev/null 2>&1 || true
        fi
    fi
}

# codesign/productsign resolve identities through the USER SEARCH LIST. An
# explicit --keychain selects where signing reads key material but does NOT make
# an otherwise-isolated identity discoverable (measured during car v0.54.0). Join
# only after every import is complete; cleanup prunes this exact path again.
throttle_keychain_join() {
    local existing=() entry
    while IFS= read -r entry; do
        [ -z "$entry" ] && continue
        [ "$entry" = "$THROTTLE_KEYCHAIN" ] && continue
        existing[${#existing[@]}]="$entry"
    done < <(security list-keychains -d user | tr -d '"' | sed 's/^[[:space:]]*//')

    if [ ${#existing[@]} -gt 0 ]; then
        security list-keychains -d user -s "$THROTTLE_KEYCHAIN" "${existing[@]}"
    else
        security list-keychains -d user -s "$THROTTLE_KEYCHAIN"
    fi
}

# Idempotent teardown. Order matters: remove the keychain from the search list
# BEFORE deleting it, otherwise later `security list-keychains` queries return
# stale entries that confuse the next run.
throttle_keychain_cleanup() {
    if command -v security >/dev/null 2>&1; then
        throttle_keychain_prune "${THROTTLE_KEYCHAIN:-}"
        if [ -n "${THROTTLE_KEYCHAIN:-}" ] && [ -f "$THROTTLE_KEYCHAIN" ]; then
            security delete-keychain "$THROTTLE_KEYCHAIN" 2>/dev/null || true
        fi
    fi
    if [ -n "${THROTTLE_VAULT_TMPROOT:-}" ] && [ -d "$THROTTLE_VAULT_TMPROOT" ]; then
        rm -rf "$THROTTLE_VAULT_TMPROOT"
    fi
    THROTTLE_KEYCHAIN=""
    THROTTLE_VAULT_TMPROOT=""
    _THROTTLE_KEYCHAIN_PASSWORD=""
}

# ---------------------------------------------------------------------------
# Bootstrap
# ---------------------------------------------------------------------------

# Import the Developer ID Certification Authority G2 intermediate.
#
# Newer "Developer ID Installer" leaves chain through "Developer ID Certification
# Authority - G2", which is NOT in the macOS System Roots. Without it the chain
# fails validation, `security find-identity` silently omits the Installer
# identity, and productsign later reports "Could not find appropriate signing
# identity" — the failure that cost `car` every .pkg from v0.34.0 to v0.53.0.
#
# Two sources, both tried. Apple's public DER is the one proven to import
# cleanly; the vault copy is kept as an offline fallback because car found its
# stored form can be one openssl refuses ("Expecting: TRUSTED CERTIFICATE").
# Neither is fatal on its own — the productsign probe below is the real gate.
throttle_import_g2_intermediate() {
    local der="$THROTTLE_VAULT_TMPROOT/DeveloperIDG2CA.cer"
    local pem="$THROTTLE_VAULT_TMPROOT/DeveloperIDG2CA.pem"
    local vault_b64 vault_raw imported=0

    if curl -fsSL -o "$der" https://www.apple.com/certificateauthority/DeveloperIDG2CA.cer \
        && openssl x509 -inform DER -in "$der" -out "$pem" 2>/dev/null; then
        security import "$pem" -k "$THROTTLE_KEYCHAIN" >/dev/null 2>&1 || true
        vault_ok "  Developer ID G2 intermediate imported (Apple public CA)"
        imported=1
    fi

    vault_b64=$(throttle_vault_get_or_empty "${THROTTLE_RELEASE_SECRET_PREFIX}-installer-g2-ca")
    if [ -n "$vault_b64" ]; then
        vault_raw="$THROTTLE_VAULT_TMPROOT/g2-from-vault.bin"
        if printf '%s' "$vault_b64" | base64 -d > "$vault_raw" 2>/dev/null && [ -s "$vault_raw" ]; then
            # Could be DER or PEM; try both conversions, ignore the one that fails.
            if openssl x509 -inform DER -in "$vault_raw" \
                -out "$THROTTLE_VAULT_TMPROOT/g2-from-vault.pem" 2>/dev/null \
                || openssl x509 -in "$vault_raw" \
                -out "$THROTTLE_VAULT_TMPROOT/g2-from-vault.pem" 2>/dev/null; then
                security import "$THROTTLE_VAULT_TMPROOT/g2-from-vault.pem" \
                    -k "$THROTTLE_KEYCHAIN" >/dev/null 2>&1 || true
                vault_ok "  Developer ID G2 intermediate imported (vault copy)"
                imported=1
            fi
        fi
    fi

    if [ "$imported" -eq 0 ]; then
        vault_red "  WARNING: no Developer ID G2 intermediate could be imported."
        vault_red "  .pkg signing will likely fail with an unbuildable chain."
    fi
}

# Create the scratch keychain, populate it from the vault, and prove both
# identities actually work. Returns non-zero on any failure; the caller's trap
# calls throttle_keychain_cleanup.
throttle_keychain_bootstrap() {
    local app_p12 installer_p12 app_pass installer_pass
    local identity_list app_line installer_line

    # Repair a search list a previous run left broken BEFORE anything that needs
    # the keychain — including reading Key Vault credentials, since a dangling
    # entry can make every `security` lookup on this machine fail.
    throttle_keychain_prune

    THROTTLE_VAULT_TMPROOT=$(mktemp -d -t throttle-release.XXXXXX)
    chmod 700 "$THROTTLE_VAULT_TMPROOT"
    THROTTLE_KEYCHAIN="$THROTTLE_VAULT_TMPROOT/${THROTTLE_KEYCHAIN_PREFIX}$$.keychain-db"
    _THROTTLE_KEYCHAIN_PASSWORD=$(openssl rand -base64 24)

    vault_info "==> Fetching signing material from '$THROTTLE_RELEASE_VAULT'..."
    THROTTLE_APP_IDENTITY=$(throttle_vault_get "${THROTTLE_RELEASE_SECRET_PREFIX}-app-identity-cn") || return 1
    app_pass=$(throttle_vault_get "${THROTTLE_RELEASE_SECRET_PREFIX}-app-password") || return 1
    NOTARY_APPLE_ID=$(throttle_vault_get "${THROTTLE_RELEASE_NOTARY_SECRET_PREFIX}-apple-id") || return 1
    NOTARY_TEAM_ID=$(throttle_vault_get "${THROTTLE_RELEASE_NOTARY_SECRET_PREFIX}-team-id") || return 1
    NOTARY_PASSWORD=$(throttle_vault_get "${THROTTLE_RELEASE_NOTARY_SECRET_PREFIX}-password") || return 1
    export NOTARY_APPLE_ID NOTARY_TEAM_ID NOTARY_PASSWORD

    app_p12="$THROTTLE_VAULT_TMPROOT/app.p12"
    throttle_vault_get_p12 "${THROTTLE_RELEASE_SECRET_PREFIX}-app-p12" "$app_p12" || return 1
    vault_ok "  Application certificate reassembled ($(wc -c < "$app_p12" | tr -d ' ') bytes)"

    THROTTLE_INSTALLER_IDENTITY=""
    installer_p12="$THROTTLE_VAULT_TMPROOT/installer.p12"
    if [ -n "$(throttle_vault_get_or_empty "${THROTTLE_RELEASE_SECRET_PREFIX}-installer-p12-chunks")" ]; then
        THROTTLE_INSTALLER_IDENTITY=$(throttle_vault_get "${THROTTLE_RELEASE_SECRET_PREFIX}-installer-identity-cn") || return 1
        installer_pass=$(throttle_vault_get "${THROTTLE_RELEASE_SECRET_PREFIX}-installer-password") || return 1
        throttle_vault_get_p12 "${THROTTLE_RELEASE_SECRET_PREFIX}-installer-p12" "$installer_p12" || return 1
        vault_ok "  Installer certificate reassembled ($(wc -c < "$installer_p12" | tr -d ' ') bytes)"
    else
        vault_info "  No Installer certificate in the vault; the .pkg will be left unsigned."
    fi

    # Restart trustd FIRST. Trust evaluations are cached per-user and a poisoned
    # entry survives keychain deletion and new scratch keychains, so a previous
    # failed attempt can make this one reject a perfectly good certificate with
    # CSSMERR_TP_NOT_TRUSTED. It is self-poisoning: each failure dirties the cache
    # for the next run. car measured 7/7 signed with a clean cache vs 1/5 with a
    # poisoned one. Per-user daemon, no sudo, respawns on demand.
    killall trustd 2>/dev/null || true

    vault_info "==> Creating scratch keychain..."
    security create-keychain -p "$_THROTTLE_KEYCHAIN_PASSWORD" "$THROTTLE_KEYCHAIN"
    # create-keychain may register the new keychain in the user search list as a
    # side effect. Remove it while imports run so ambient duplicate checks cannot
    # interfere, then join the populated keychain once, before signing.
    throttle_keychain_prune "$THROTTLE_KEYCHAIN"
    # No auto-lock timeout. `-t <n>` is an INACTIVITY timeout, and a long build
    # with no keychain traffic is exactly the window that trips it; codesign then
    # reports the opaque errSecInternalComponent rather than naming a locked
    # keychain. Safe here only because this keychain is ephemeral: random
    # password, created per run, deleted by the caller's trap on every exit path.
    security set-keychain-settings -u "$THROTTLE_KEYCHAIN"
    security unlock-keychain -p "$_THROTTLE_KEYCHAIN_PASSWORD" "$THROTTLE_KEYCHAIN"

    # `|| true` on both imports: the bundles share intermediate certificates, so
    # residual keychain state can make `security import` report
    # errSecDuplicateItem on those shared certs. That error does NOT prevent the
    # leaf identity and its private key from landing. The sanity checks below are
    # the real gate and hard-fail if an identity is genuinely missing.
    vault_info "==> Importing Application identity..."
    security import "$app_p12" -k "$THROTTLE_KEYCHAIN" -P "$app_pass" -A \
        -t cert -f pkcs12 >/dev/null 2>&1 || true

    if [ -n "$THROTTLE_INSTALLER_IDENTITY" ]; then
        vault_info "==> Importing Installer identity..."
        security import "$installer_p12" -k "$THROTTLE_KEYCHAIN" -P "$installer_pass" -A \
            -t cert -f pkcs12 >/dev/null 2>&1 || true
        throttle_import_g2_intermediate
    fi

    # The p12 files have done their job. Remove them now rather than waiting for
    # the trap, so the window in which private keys exist on disk is as short as
    # the import itself.
    rm -f "$app_p12" "$installer_p12"

    vault_info "==> Joining the populated scratch keychain to the user search list..."
    throttle_keychain_join

    # Tell the keychain the just-imported private keys may be used by signing
    # tools without a UI prompt. `codesign:` must be in the list, not just
    # `apple-tool:,apple:` — codesign checks for that specific partition id, and
    # without it the FIRST real use of the Application key dies with
    # errSecInternalComponent after the whole build has already run (car v0.45.0).
    security set-key-partition-list -S apple-tool:,apple:,codesign: \
        -s -k "$_THROTTLE_KEYCHAIN_PASSWORD" "$THROTTLE_KEYCHAIN" >/dev/null

    # Materialize before matching. `grep -q` exits on its first match and SIGPIPEs
    # find-identity mid-write, which `set -o pipefail` turns into a failed
    # pipeline — inverting the test and aborting the release insisting the
    # identity is missing while it is sitting right there (car#749).
    identity_list="$(security find-identity -v -p codesigning "$THROTTLE_KEYCHAIN" 2>&1 || true)"
    app_line=$(grep -F "$THROTTLE_APP_IDENTITY" <<< "$identity_list" | head -1 || true)
    if [ -z "$app_line" ]; then
        vault_red "imported Application identity is not visible to codesigning."
        vault_red "expected: $THROTTLE_APP_IDENTITY"
        printf '%s\n' "$identity_list" >&2
        return 1
    fi
    case "$app_line" in
        *CSSMERR*)
            vault_red "imported Application identity has a trust failure:"
            vault_red "  $app_line"
            return 1
            ;;
    esac
    vault_ok "  codesign sees: $THROTTLE_APP_IDENTITY"

    # Perform the operation instead of trusting discovery output. During car
    # v0.54.0 find-identity listed the leaf cleanly while the next hardened-runtime
    # codesign failed "no identity found". A copied system Mach-O needs no
    # compiler and proves the exact explicit-keychain operation the real build uses.
    local probe_dir="$THROTTLE_VAULT_TMPROOT/codesignprobe"
    mkdir -p "$probe_dir"
    cp -f /usr/bin/true "$probe_dir/probe"
    chmod u+w "$probe_dir/probe"
    if ! codesign --force --sign "$THROTTLE_APP_IDENTITY" --keychain "$THROTTLE_KEYCHAIN" \
            --options runtime --timestamp=none "$probe_dir/probe" 2>"$probe_dir/err"; then
        vault_red "Application identity is present but hardened-runtime codesign REFUSES it:"
        vault_red "  $(tail -1 "$probe_dir/err" 2>/dev/null)"
        vault_red "Failing now rather than during the release build."
        return 1
    fi
    if ! codesign --verify --strict "$probe_dir/probe" 2>"$probe_dir/verify.err"; then
        vault_red "Application codesign probe did not verify:"
        vault_red "  $(tail -1 "$probe_dir/verify.err" 2>/dev/null)"
        return 1
    fi
    vault_ok "  codesign verified by signing a hardened-runtime probe"

    # Installer certificates are not valid for codesign(1), so use the unfiltered
    # find-identity — and do not trust its output either. `find-identity -v`
    # advertises "Valid identities only" yet still prints chain-failed identities
    # with an inline "(CSSMERR_TP_NOT_TRUSTED)" annotation, so a bare name match
    # reports success for an identity productsign will refuse. That false positive
    # let a car release build for ~55 minutes before dying at the .pkg step.
    # Parsing the annotation is also unreliable (the same leaf has been observed
    # both annotated and clean). So do not infer — sign a throwaway package.
    if [ -n "$THROTTLE_INSTALLER_IDENTITY" ]; then
        installer_line=$(security find-identity -v "$THROTTLE_KEYCHAIN" 2>&1 \
            | grep -F "$THROTTLE_INSTALLER_IDENTITY" | head -1 || true)
        if [ -z "$installer_line" ]; then
            vault_red "imported Installer identity is not findable."
            vault_red "expected: $THROTTLE_INSTALLER_IDENTITY"
            return 1
        fi
        local pkg_probe="$THROTTLE_VAULT_TMPROOT/pkgprobe"
        mkdir -p "$pkg_probe/payload"
        : > "$pkg_probe/payload/.keep"
        if ! pkgbuild --root "$pkg_probe/payload" --identifier ai.parslee.signprobe \
                --version 1 "$pkg_probe/unsigned.pkg" >/dev/null 2>&1; then
            vault_red "could not build the probe package (pkgbuild failed)."
            return 1
        fi
        if ! productsign --sign "$THROTTLE_INSTALLER_IDENTITY" --keychain "$THROTTLE_KEYCHAIN" \
                "$pkg_probe/unsigned.pkg" "$pkg_probe/signed.pkg" 2>"$pkg_probe/err"; then
            vault_red "Installer identity is present but productsign REFUSES it:"
            vault_red "  $(tail -1 "$pkg_probe/err" 2>/dev/null)"
            vault_red "find-identity reported: $installer_line"
            vault_red "Failing now rather than after the full build."
            return 1
        fi
        vault_ok "  productsign verified by signing a probe package"
    fi

    export THROTTLE_KEYCHAIN
    return 0
}
