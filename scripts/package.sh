#!/usr/bin/env bash
set -euo pipefail

# scripts/package.sh — turn build/Throttle.app into build/Throttle-<version>.pkg.
#
# Usage:
#   scripts/package.sh <version> [options]
#
# Options:
#   --identity "<CN>"   Developer ID Installer common name; signs the .pkg with
#                       productsign. Omit for an unsigned package.
#   --keychain <path>   Keychain holding that identity (the scratch keychain
#                       scripts/release.sh builds). Passed to productsign.
#   --app <path>        App bundle to package (default build/Throttle.app).
#   --out <path>        Output .pkg (default build/Throttle-<version>.pkg).
#
# Called by scripts/release.sh, and runnable on its own against any built app.
#
# The safety measures here were paid for by Parslee-ai/car#1488 and car#1489:
# an installer whose OS floor drifted from the app's, and a relocatable payload
# that silently merged a signed install into a stale dev build — and then, once
# that stale copy was renamed away, installed the app NOWHERE while Installer.app
# reported "Install Succeeded".

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="$ROOT_DIR/build"

APP_NAME="Throttle.app"
PKG_IDENTIFIER="ai.parslee.throttle"
# Fallback installer floor, used only when the bundle carries no
# LSMinimumSystemVersion. Matches the ISA's macOS 14 (Sonoma) minimum.
DEFAULT_MIN_OS="14.0"

red()  { printf '\033[31m%s\033[0m\n' "$*" >&2; }
ok()   { printf '\033[32m%s\033[0m\n' "$*"; }
info() { printf '\033[36m%s\033[0m\n' "$*"; }

usage() {
    sed -n '4,17p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' >&2
    exit 2
}

# --- arguments -------------------------------------------------------------

VERSION=""
INSTALLER_IDENTITY=""
SIGN_KEYCHAIN="${THROTTLE_KEYCHAIN:-}"
APP_SRC=""
PKG_OUT=""

while [ $# -gt 0 ]; do
    case "$1" in
        --identity) INSTALLER_IDENTITY="${2:?--identity needs a common name}"; shift 2 ;;
        --keychain) SIGN_KEYCHAIN="${2:?--keychain needs a path}"; shift 2 ;;
        --app)      APP_SRC="${2:?--app needs a path}"; shift 2 ;;
        --out)      PKG_OUT="${2:?--out needs a path}"; shift 2 ;;
        -h|--help)  usage ;;
        -*)         red "unknown option: $1"; usage ;;
        *)
            if [ -z "$VERSION" ]; then VERSION="$1"; shift
            else red "unexpected argument: $1"; usage; fi
            ;;
    esac
done

[ -n "$VERSION" ] || { red "a version is required"; usage; }
if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+([-+][0-9A-Za-z.-]+)?$ ]]; then
    red "version must look like X.Y.Z (got '$VERSION')"
    exit 2
fi

APP_SRC="${APP_SRC:-$BUILD_DIR/$APP_NAME}"
PKG_OUT="${PKG_OUT:-$BUILD_DIR/Throttle-$VERSION.pkg}"

for tool in pkgbuild productbuild pkgutil lsbom ditto; do
    command -v "$tool" >/dev/null 2>&1 || { red "missing required tool: $tool"; exit 1; }
done

if [ ! -d "$APP_SRC" ]; then
    red "$APP_SRC not found. Run scripts/build.sh first."
    exit 2
fi
if [ ! -f "$APP_SRC/Contents/Info.plist" ]; then
    red "$APP_SRC has no Contents/Info.plist, so it is not an app bundle."
    exit 2
fi

# --- work area -------------------------------------------------------------

# Outside build/, so a concurrent scripts/build.sh that clears build/ cannot
# delete the staging tree out from under pkgbuild mid-run.
WORK_DIR="$(mktemp -d -t throttle-package.XXXXXX)"
APP_STAGE="$WORK_DIR/stage"
COMPONENT_PLIST="$WORK_DIR/component.plist"
COMPONENT_PKG="$WORK_DIR/.throttle-app.pkg"
DIST_XML="$WORK_DIR/Distribution.xml"
UNSIGNED_PKG="$WORK_DIR/Throttle-unsigned.pkg"

cleanup() {
    rm -rf "$WORK_DIR"
}
trap cleanup EXIT

mkdir -p "$APP_STAGE"

# --- installer OS floor ----------------------------------------------------

# One source of truth for both floors: the Distribution's <os-version min> is
# read from the app's own LSMinimumSystemVersion, so the installer's gate can
# never drift from the app's (car#1488 shipped a .pkg gating installs at 15.0 for
# an app that refused to launch below 26.0). A present-but-malformed value is
# fatal: a gate built on a guess either blocks users the app supports or waves
# through users it does not, and productbuild catches neither.
MIN_OS="$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' \
    "$APP_SRC/Contents/Info.plist" 2>/dev/null || true)"
if [ -z "$MIN_OS" ]; then
    red "WARNING: $APP_SRC has no LSMinimumSystemVersion; using $DEFAULT_MIN_OS."
    red "The app bundle should declare it (ISC-14)."
    MIN_OS="$DEFAULT_MIN_OS"
elif [[ ! "$MIN_OS" =~ ^[0-9]+([.][0-9]+)*$ ]]; then
    red "LSMinimumSystemVersion is not a plain dotted version number: '$MIN_OS'."
    red "Refusing to emit an installer gate built on a bad value."
    exit 2
fi

info "=== Packaging $APP_NAME $VERSION (installer floor: macOS $MIN_OS) ==="

# --- stage -----------------------------------------------------------------

# The staged root holds ONLY the bundle. A stage that also owned an
# ./Applications directory let the BOM claim the real /Applications and hand
# installd metadata for a live system directory (car#1489 round 2). `ditto` is
# the bundle-faithful copy on macOS: it preserves bytes, modes, symlinks and
# extended attributes, which is what lets an embedded code signature survive.
ditto "$APP_SRC" "$APP_STAGE/$APP_NAME"

# The staged copy must still verify exactly as the source did. The gate is the
# SOURCE's own verdict, not the mere presence of signing metadata: an unsigned or
# ad-hoc bundle has nothing for the copy to preserve, while a bundle that
# verifies must still verify after ditto or the release is shipping a broken
# signature. scripts/release.sh signs before calling here, so on a real signed
# release this branch always runs.
if command -v codesign >/dev/null 2>&1 \
    && codesign --verify --deep --strict "$APP_SRC" >/dev/null 2>&1; then
    info "  Verifying the staged bundle with codesign..."
    if ! codesign --verify --deep --strict "$APP_STAGE/$APP_NAME"; then
        red "the staged bundle failed codesign --verify --deep --strict;"
        red "the copy is not faithful to the signed source. Aborting."
        exit 3
    fi
    ok "  staged copy still verifies"
else
    info "  Source bundle has no verifiable signature; skipping the staged-copy check."
fi

# --- component plist -------------------------------------------------------

info "  Analyzing the bundle for a component plist..."
pkgbuild --analyze --root "$APP_STAGE" "$COMPONENT_PLIST" >/dev/null

# --analyze emits the Installer defaults, BundleIsRelocatable=true among them.
# Force it false on every entry so installd may never place the payload onto
# some other on-disk bundle with the same CFBundleIdentifier (car#1489). The
# plist is regenerated per build and never checked in, because a hand-edited
# copy drifts from the bundle it describes.
idx=0
found_expected=0
while /usr/libexec/PlistBuddy -c "Print :${idx}" "$COMPONENT_PLIST" >/dev/null 2>&1; do
    entry_path="$(/usr/libexec/PlistBuddy -c "Print :${idx}:RootRelativeBundlePath" \
        "$COMPONENT_PLIST" 2>/dev/null || true)"
    [ "$entry_path" = "$APP_NAME" ] && found_expected=1
    if /usr/libexec/PlistBuddy -c "Print :${idx}:BundleIsRelocatable" \
            "$COMPONENT_PLIST" >/dev/null 2>&1; then
        /usr/libexec/PlistBuddy -c "Set :${idx}:BundleIsRelocatable false" "$COMPONENT_PLIST"
    else
        /usr/libexec/PlistBuddy -c "Add :${idx}:BundleIsRelocatable bool false" "$COMPONENT_PLIST"
    fi
    idx=$((idx + 1))
done
if [ "$found_expected" -ne 1 ]; then
    red "pkgbuild --analyze found no entry for $APP_NAME in the staged root."
    red "Refusing to package an unexpected payload."
    exit 3
fi
ok "  BundleIsRelocatable=false on all $idx component entr$([ "$idx" -eq 1 ] && printf 'y' || printf 'ies')"

# --- component package -----------------------------------------------------

info "  Building the Applications component..."
pkgbuild \
    --root "$APP_STAGE" \
    --install-location /Applications \
    --component-plist "$COMPONENT_PLIST" \
    --identifier "$PKG_IDENTIFIER" \
    --version "$VERSION" \
    "$COMPONENT_PKG" >/dev/null

# Expand the component and read its BOM: the payload must own ONLY the bundle —
# no ./Applications entry — so installing it can never touch the real
# /Applications directory's owner, group or permissions.
BOM_CHECK="$WORK_DIR/bom-check"
rm -rf "$BOM_CHECK"
pkgutil --expand "$COMPONENT_PKG" "$BOM_CHECK" >/dev/null
bom_paths="$(lsbom "$BOM_CHECK/Bom" | awk '{print $1}')"
if printf '%s\n' "$bom_paths" | grep -qx './Applications' \
    || ! printf '%s\n' "$bom_paths" | grep -qx "./$APP_NAME"; then
    red "the component payload is not exactly ./$APP_NAME. lsbom reports:"
    printf '%s\n' "$bom_paths" | sed 's/^/  /' >&2
    exit 3
fi
rm -rf "$BOM_CHECK"

# --- distribution ----------------------------------------------------------

cat > "$DIST_XML" <<XML
<?xml version="1.0" encoding="utf-8"?>
<installer-gui-script minSpecVersion="2">
    <title>Throttle</title>
    <organization>ai.parslee</organization>
    <domains enable_localSystem="true"/>
    <options customize="never" require-scripts="false" rootVolumeOnly="true"/>
    <!-- The installer's OS floor IS the app's floor: os-version min is read at
         build time from the bundle's own LSMinimumSystemVersion, so the two
         cannot drift (car#1488). Installer.app enforces it with its native
         volume-check dialog, so a user on an older macOS is refused before
         anything is written rather than left with an app that will not launch. -->
    <volume-check>
        <allowed-os-versions>
            <os-version min="${MIN_OS}"/>
        </allowed-os-versions>
    </volume-check>
    <choices-outline>
        <line choice="default">
            <line choice="${PKG_IDENTIFIER}"/>
        </line>
    </choices-outline>
    <choice id="default"/>
    <choice id="${PKG_IDENTIFIER}" visible="false">
        <pkg-ref id="${PKG_IDENTIFIER}"/>
    </choice>
    <pkg-ref id="${PKG_IDENTIFIER}" version="${VERSION}" onConclusion="none">.throttle-app.pkg</pkg-ref>
</installer-gui-script>
XML

info "  Assembling the distribution package..."
productbuild \
    --distribution "$DIST_XML" \
    --package-path "$WORK_DIR" \
    --version "$VERSION" \
    "$UNSIGNED_PKG" >/dev/null

# --- sign ------------------------------------------------------------------

mkdir -p "$(dirname "$PKG_OUT")"
rm -f "$PKG_OUT"

if [ -n "$INSTALLER_IDENTITY" ]; then
    # productsign with Developer ID Installer, distinct from the codesign that
    # signed the .app with Developer ID Application. `--keychain` when the caller
    # named one: without it productsign searches only the ambient user search
    # list, which anything on the machine can change mid-build.
    PRODUCTSIGN_ARGS=(--sign "$INSTALLER_IDENTITY")
    if [ -n "$SIGN_KEYCHAIN" ]; then
        PRODUCTSIGN_ARGS+=(--keychain "$SIGN_KEYCHAIN")
    fi
    info "  Signing with: $INSTALLER_IDENTITY"
    productsign "${PRODUCTSIGN_ARGS[@]}" "$UNSIGNED_PKG" "$PKG_OUT"
else
    info "  No installer identity given; leaving the package unsigned."
    mv "$UNSIGNED_PKG" "$PKG_OUT"
fi
chmod 0644 "$PKG_OUT"

# --- verify ----------------------------------------------------------------

info "  Verifying the built package..."

VERIFY_DIR="$WORK_DIR/verify"
rm -rf "$VERIFY_DIR"
pkgutil --expand "$PKG_OUT" "$VERIFY_DIR" >/dev/null

component_dirs=()
while IFS= read -r d; do
    [ -n "$d" ] && component_dirs+=("$d")
done < <(find "$VERIFY_DIR" -maxdepth 1 -type d -name '*.pkg' | sort)

if [ "${#component_dirs[@]}" -ne 1 ]; then
    red "expected exactly one component package inside $PKG_OUT, found ${#component_dirs[@]}."
    exit 3
fi
component_dir="${component_dirs[0]}"

install_location="$(sed -n 's/.*install-location="\([^"]*\)".*/\1/p' \
    "$component_dir/PackageInfo" | head -1)"
if [ "$install_location" != "/Applications" ]; then
    red "component install-location is '$install_location', expected /Applications."
    exit 3
fi
verify_bom="$(lsbom "$component_dir/Bom" | awk '{print $1}')"
if ! printf '%s\n' "$verify_bom" | grep -qx "./$APP_NAME"; then
    red "component payload does not contain ./$APP_NAME."
    exit 3
fi
# The built package's own record of whether installd may redirect the payload.
# pkgbuild always emits a <relocate> element; what differs is its content. With
# BundleIsRelocatable=false it is the empty, self-closing "<relocate/>"; with
# true it lists the bundle to search for:
#     <relocate><bundle id="ai.parslee.throttle"/></relocate>
# So the open-tag form is the failure, and grepping for it reads the shipped
# artifact rather than trusting the plist we handed pkgbuild (car#1489).
if grep -q '<relocate>' "$component_dir/PackageInfo" 2>/dev/null; then
    red "PackageInfo lists a relocatable bundle; installd could redirect the payload."
    sed -n '/<relocate>/,/<\/relocate>/p' "$component_dir/PackageInfo" | sed 's/^/  /' >&2
    exit 3
fi
ok "  payload root: Applications/$APP_NAME (install-location $install_location)"
rm -rf "$VERIFY_DIR"

if [ -n "$INSTALLER_IDENTITY" ]; then
    SIGCHECK="$(pkgutil --check-signature "$PKG_OUT" 2>&1 || true)"
    if ! printf '%s\n' "$SIGCHECK" | grep -q 'signed by a developer certificate issued by Apple'; then
        red "pkgutil --check-signature did not report an Apple developer signature:"
        printf '%s\n' "$SIGCHECK" | sed 's/^/  /' >&2
        exit 3
    fi
    ok "  signature: $(printf '%s\n' "$SIGCHECK" | sed -n '2p' | sed 's/^[[:space:]]*//')"
else
    info "  signature: none (unsigned package)"
fi

ok "Package: $PKG_OUT ($(wc -c < "$PKG_OUT" | tr -d ' ') bytes)"
