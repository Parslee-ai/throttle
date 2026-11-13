#!/usr/bin/env bash
# Drives a Debug build of Throttle from this checkout through macOS
# Accessibility (System Events via osascript), for verification.
#
# It never touches an installed /Applications/Throttle.app. Every action is
# addressed to the one pid this script launched and recorded, and that pid's
# executable path is checked against this checkout's Debug build first.
#
# Usage: throttle-verify.sh <command> [args]
#   build               Debug build into build/verify/DerivedData
#   launch              start the Debug app, wait for its menu bar item
#   doctor              read-only checks; exit 0 only when safe to drive
#   label               print the menu bar item's text
#   window <name>       open the detail window, record its elements, close it
#   add-menu <name>     open "Add account", record every item, cancel it
#   settings <name>     open Settings, record it, press Done, close
#   quit-ui             click Quit in the detail window, confirm the pid exits
#   snapshots [dir]     render the hosted-view PNGs from fixtures (no live app)
#   cleanup             stop the pid this script started; evidence is kept
#   ax '<applescript>'  one raw statement inside `tell process <our pid>`
#
# window, add-menu and settings also save <name>.png of the app's own window
# when Screen Recording is granted. Evidence goes to $THROTTLE_VERIFY_OUT, or
# build/verify/evidence/<launch time>/ when unset.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SELF="$SCRIPT_DIR/$(basename "${BASH_SOURCE[0]}")"
ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd)"
DERIVED="$ROOT/build/verify/DerivedData"
APP="$DERIVED/Build/Products/Debug/Throttle.app"
EXE="$APP/Contents/MacOS/Throttle"
TEST_HOST="$ROOT/build/DerivedData/Build/Products/Debug/Throttle.app/Contents/MacOS/Throttle"
STATE="$ROOT/build/verify/run"
PIDFILE="$STATE/pid"
DEV_ID="ai.parslee.throttle.dev"
AX_TIMEOUT="${THROTTLE_VERIFY_AX_TIMEOUT:-20}"

# One run, one evidence folder: launch records it and later commands reuse it.
if [ -n "${THROTTLE_VERIFY_OUT:-}" ]; then OUT="$THROTTLE_VERIFY_OUT"
elif [ -f "$STATE/out" ]; then OUT="$(cat "$STATE/out")"
else OUT="$ROOT/build/verify/evidence/$(date +%Y%m%d-%H%M%S)"; fi

die() { echo "error: $*" >&2; exit 1; }

# osascript can block on an Accessibility call; perl's alarm (stock on macOS)
# bounds every call so a stuck one fails instead of hanging the run.
bounded() { perl -e 'alarm shift; exec @ARGV or die "exec: $!"' "$AX_TIMEOUT" "$@"; }

exe_of() { ps -o comm= -p "$1" 2>/dev/null || true; }

# Pids whose executable is exactly <path>. Never match by name: the installed
# app is also called Throttle, and other apps carry "Throttle" in arguments.
pids_running() {
  local p
  for p in $(pgrep -x Throttle || true); do
    [ "$(exe_of "$p")" = "$1" ] && echo "$p"
  done
  return 0
}

our_pid() {
  [ -f "$PIDFILE" ] || die "no run recorded ($PIDFILE missing); run launch first"
  local pid; pid="$(cat "$PIDFILE")"
  kill -0 "$pid" 2>/dev/null || die "recorded pid $pid is not running"
  [ "$(exe_of "$pid")" = "$EXE" ] || die "pid $pid runs '$(exe_of "$pid")', not $EXE"
  echo "$pid"
}

# Runs AppleScript inside `tell (first process whose unix id is <our pid>)`.
# Every UI specifier in the body must be written out from the window or menu
# bar down, never stored in a variable: System Events rewrites a stored
# element reference as `application process "Throttle"`, a name the installed
# app shares, and the next use can land on it.
ax() {
  local pid; pid="$(our_pid)"
  bounded osascript \
    -e 'on run argv' \
    -e 'tell application "System Events"' \
    -e 'tell (first process whose unix id is (item 1 of argv as integer))' \
    -e "$1" \
    -e 'end tell' -e 'end tell' -e 'end run' "$pid"
}

# The detail window closes as soon as Throttle stops being the active app,
# which happens between two osascript calls. So a drive opens the window,
# acts and records, and closes it again inside one script.
drive() {
  ax "$(cat <<EOF
if (count windows) = 0 then click menu bar item 1 of menu bar 2
repeat 40 times
  if (count windows) > 0 then exit repeat
  delay 0.25
end repeat
if (count windows) = 0 then error "detail window did not open"
set out to ""
-- Settings stays open across a close and reopen of the window; start clean.
if exists static text "Settings" of group 1 of group 1 of window 1 then
  click last button of group 1 of group 1 of window 1
  delay 0.5
  set out to out & "dismissed a Settings panel left open by an earlier drive" & linefeed
end if
$1
if (count windows) > 0 then click menu bar item 1 of menu bar 2
delay 0.5
return out & "windows open at end: " & (count windows)
EOF
)"
}

# AppleScript that appends every element of the window, two levels below its
# root group, to `out`.
DUMP='
set n to count UI elements of group 1 of window 1
repeat with i from 1 to n
  set {r, nm, h, en, v} to {role, name, help, enabled, value} of UI element i of group 1 of window 1
  set out to out & i & " " & r & " | name=" & nm & " | value=" & v & " | help=" & h & " | enabled=" & en & linefeed
  set k to count UI elements of UI element i of group 1 of window 1
  repeat with j from 1 to k
    set {r, nm, h, en, v} to {role, name, help, enabled, value} of UI element j of UI element i of group 1 of window 1
    set out to out & "  " & i & "." & j & " " & r & " | name=" & nm & " | value=" & v & " | help=" & h & " | enabled=" & en & linefeed
  end repeat
end repeat'

# AppleScript that saves a PNG of the app's own window while it is open.
shot() { # shot <name>
  printf 'tell current application to set out to out & (do shell script "%s _capture-window %s") & linefeed' \
    "$SELF" "$1"
}

ax_trusted() {
  bounded osascript -l JavaScript -e 'ObjC.import("ApplicationServices"); $.AXIsProcessTrusted()'
}

screen_capture_allowed() {
  bounded osascript -l JavaScript -e 'ObjC.import("CoreGraphics"); ObjC.bindFunction("CGPreflightScreenCaptureAccess", ["bool", []]); $.CGPreflightScreenCaptureAccess()'
}

ensure_out() { mkdir -p "$OUT"; }

cmd_build() {
  cd "$ROOT"
  mkdir -p build/verify
  xcodebuild -project Throttle.xcodeproj -scheme Throttle -configuration Debug \
    -derivedDataPath "$DERIVED" build > build/verify/build.log 2>&1 \
    || { tail -20 build/verify/build.log >&2; die "build failed; full log in build/verify/build.log"; }
  [ -x "$EXE" ] || die "build reported success but $EXE is missing"
  echo "built $APP"
}

cmd_launch() {
  [ -x "$EXE" ] || die "$EXE missing; run build first"
  local id; id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Contents/Info.plist")"
  [ "$id" = "$DEV_ID" ] || die "built app is $id, not $DEV_ID; refusing to launch a release identity"
  if [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; then
    die "a verification instance is already running (pid $(cat "$PIDFILE")); run cleanup first"
  fi
  [ -z "$(pids_running "$EXE")" ] || die "a Debug Throttle from this checkout is already running (pid $(pids_running "$EXE" | tr '\n' ' ')) that this script did not record; stop it by pid first"
  mkdir -p "$STATE"
  ensure_out
  (cd "$OUT" && pwd) > "$STATE/out"
  nohup "$EXE" > "$OUT/app-stdout.log" 2>&1 < /dev/null &
  echo "$!" > "$PIDFILE"
  # Ready means the menu bar item answers through Accessibility.
  local i=0
  until ax 'get title of menu bar item 1 of menu bar 2' > /dev/null 2>&1; do
    i=$((i + 1)); [ "$i" -lt 40 ] || die "pid $(cat "$PIDFILE") started but no menu bar item answered in 20 s"
    sleep 0.5
  done
  echo "launched pid $(cat "$PIDFILE"); evidence in $(cat "$STATE/out")"
}

cmd_doctor() {
  local ok=0 pid exe id seid title others
  pid="$(our_pid)" || { echo "doctor: NOT safe to drive"; return 1; }
  exe="$(exe_of "$pid")"
  if [ "$exe" = "$EXE" ]; then echo "ok   pid $pid runs this checkout's Debug build: $exe"
  else echo "FAIL pid $pid runs '$exe', expected $EXE"; ok=1; fi
  id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Contents/Info.plist")"
  if [ "$id" = "$DEV_ID" ]; then echo "ok   bundle identifier on disk is $id"
  else echo "FAIL bundle identifier on disk is $id, expected $DEV_ID"; ok=1; fi
  if [ "$(ax_trusted 2>/dev/null || true)" = "true" ]; then echo "ok   Accessibility is granted to the app hosting this shell"
  else echo "FAIL Accessibility is not granted to the app hosting this shell (see Launch in SKILL.md)"; ok=1; fi
  seid="$(ax 'get bundle identifier' 2>/dev/null || true)"
  if [ "$seid" = "$DEV_ID" ]; then echo "ok   System Events sees pid $pid as $seid"
  else echo "FAIL System Events sees pid $pid as '$seid', expected $DEV_ID"; ok=1; fi
  title="$(ax 'get title of menu bar item 1 of menu bar 2' 2>/dev/null || true)"
  if [ -n "$title" ]; then echo "ok   menu bar item answers: $title"
  else echo "FAIL menu bar item does not answer"; ok=1; fi
  if [ "$(screen_capture_allowed 2>/dev/null || true)" = "true" ]; then echo "ok   Screen Recording is granted: drives also save PNGs"
  else echo "note Screen Recording is not granted: no PNGs; the element records are the evidence"; fi
  others="$(pgrep -x Throttle | grep -vx "$pid" | tr '\n' ' ' || true)"
  [ -z "$others" ] || echo "note other Throttle pids, never driven or stopped by this script: $others"
  if [ "$ok" -eq 0 ]; then echo "doctor: safe to drive pid $pid"; else echo "doctor: NOT safe to drive"; fi
  return "$ok"
}

cmd_label() { ax 'get title of menu bar item 1 of menu bar 2'; }

record() { # record <name> <text>: writes the text, prints the path
  ensure_out
  printf '%s\n' "$2" > "$OUT/$1.txt"
  echo "$OUT/$1.txt"
  [ ! -f "$OUT/$1.png" ] || echo "$OUT/$1.png"
}

maybe_shot() { # AppleScript for a PNG, or nothing when capture is not granted
  [ "$(screen_capture_allowed 2>/dev/null || true)" = "true" ] && shot "$1" || true
}

cmd_window() {
  local name="${1:?usage: window <name>}"; ensure_out
  local r; r="$(drive "$(maybe_shot "$name")
$DUMP")"
  record "$name" "$r"
}

cmd_add_menu() {
  local name="${1:?usage: add-menu <name>}"; ensure_out
  # The menu is opened without waiting for a reply (a click on a menu button
  # blocks for as long as the menu tracks), read, then cancelled. No item is
  # ever chosen: every leaf starts a real sign-in or reads another app's login.
  local r; r="$(drive '
ignoring application responses
  click menu button "Add account" of group 1 of window 1
end ignoring
delay 1
set AppleScript'"'"'s text item delimiters to " | "
set providers to name of every menu item of menu 1 of menu button "Add account" of group 1 of window 1
set out to out & "Add account: " & (providers as text) & linefeed
repeat with p in providers
  set pn to contents of p
  set out to out & pn & ": " & ((name of every menu item of menu 1 of menu item pn of menu 1 of menu button "Add account" of group 1 of window 1) as text) & linefeed
end repeat
set AppleScript'"'"'s text item delimiters to ""
perform action "AXCancel" of menu 1 of menu button "Add account" of group 1 of window 1
delay 0.5
set out to out & "menu open after cancel: " & ((count menus of menu button "Add account" of group 1 of window 1) > 0) & linefeed
')"
  record "$name" "$r"
}

cmd_settings() {
  local name="${1:?usage: settings <name>}"; ensure_out
  # Settings opens inside the detail window, as group 1 of group 1. Its Done
  # button has no accessible name; it is the last button in that group.
  local r; r="$(drive "click (first button of group 1 of window 1 whose help is \"Settings\")
delay 0.8
if not (exists static text \"Settings\" of group 1 of group 1 of window 1) then error \"Settings did not open\"
$(maybe_shot "$name")
$DUMP
click last button of group 1 of group 1 of window 1
delay 0.5
set out to out & \"settings open after Done: \" & (exists static text \"Settings\" of group 1 of group 1 of window 1) & linefeed")"
  record "$name" "$r"
}

# Internal: called from inside a drive while the window is open.
cmd_capture_window() {
  local name="${1:?}" pid id
  pid="$(our_pid)"
  id="$(bounded osascript -l JavaScript -e "ObjC.import('CoreGraphics');
    var l = ObjC.deepUnwrap(ObjC.castRefToObject(\$.CGWindowListCopyWindowInfo(1 | 16, 0)));
    var w = l.filter(function (w) { return w.kCGWindowOwnerPID == $pid && w.kCGWindowLayer > 0; });
    w.length ? String(w[0].kCGWindowNumber) : ''")"
  [ -n "$id" ] || { echo "no window of pid $pid on screen; no PNG"; return 0; }
  # -l captures that one window's own pixels, never what is behind it.
  screencapture -x -o -l "$id" "$OUT/$name.png" && echo "saved $name.png"
}

cmd_quit_ui() {
  local pid; pid="$(our_pid)"
  ax 'if (count windows) = 0 then click menu bar item 1 of menu bar 2
repeat 40 times
  if (count windows) > 0 then exit repeat
  delay 0.25
end repeat
-- Not under "ignoring application responses": the whose-lookup needs a reply.
-- The app may exit before the click is acknowledged, so an error is expected.
try
  click (first button of group 1 of window 1 whose help is "Quit Throttle")
end try' > /dev/null || true
  local i=0
  while kill -0 "$pid" 2>/dev/null && [ "$i" -lt 20 ]; do sleep 0.5; i=$((i + 1)); done
  kill -0 "$pid" 2>/dev/null && die "pid $pid still running after Quit"
  rm -f "$PIDFILE"
  echo "pid $pid exited through the Quit button"
}

cmd_snapshots() {
  local dir="${1:-$OUT/snapshots}"
  mkdir -p "$dir"
  dir="$(cd "$dir" && pwd)"
  cd "$ROOT"
  TEST_RUNNER_THROTTLE_SNAPSHOT_DIR="$dir" xcodebuild test \
    -project Throttle.xcodeproj -scheme Throttle -destination 'platform=macOS' \
    -derivedDataPath build/DerivedData \
    -only-testing:ThrottleTests/PopupSnapshotTests \
    -test-timeouts-enabled YES -default-test-execution-time-allowance 60 \
    > "$dir/xcodebuild-test.log" 2>&1 \
    || { tail -20 "$dir/xcodebuild-test.log" >&2; die "snapshot tests failed; log in $dir/xcodebuild-test.log"; }
  # The test host is a Debug Throttle.app; none may be left running.
  local left; left="$(pids_running "$TEST_HOST")"
  [ -z "$left" ] || die "test host still running (pid $left); stop it by pid"
  echo "$(find "$dir" -name '*.png' | wc -l | tr -d ' ') PNGs in $dir"
}

cmd_cleanup() {
  if [ -f "$PIDFILE" ]; then
    local pid; pid="$(cat "$PIDFILE")"
    if kill -0 "$pid" 2>/dev/null; then
      [ "$(exe_of "$pid")" = "$EXE" ] || die "pid $pid is not ours ('$(exe_of "$pid")'); not stopping it"
      kill -TERM "$pid"
      local i=0
      while kill -0 "$pid" 2>/dev/null && [ "$i" -lt 20 ]; do sleep 0.5; i=$((i + 1)); done
      kill -0 "$pid" 2>/dev/null && die "pid $pid did not exit"
      echo "stopped pid $pid"
    fi
    rm -f "$PIDFILE"
  fi
  rm -f "$STATE/out"
  local left; left="$(pids_running "$EXE")"
  [ -z "$left" ] || die "a Debug Throttle from this checkout is still running (pid $left) that this run did not start; stop it by pid yourself"
  echo "no verification instance running; evidence kept in $OUT"
}

cmd="${1:-}"; shift || true
case "$cmd" in
  build) cmd_build ;;
  launch) cmd_launch ;;
  doctor) cmd_doctor ;;
  label) cmd_label ;;
  window) cmd_window "$@" ;;
  add-menu) cmd_add_menu "$@" ;;
  settings) cmd_settings "$@" ;;
  quit-ui) cmd_quit_ui ;;
  snapshots) cmd_snapshots "$@" ;;
  cleanup) cmd_cleanup ;;
  ax) ax "${1:?usage: ax '<applescript>'}" ;;
  _capture-window) cmd_capture_window "$@" ;;
  *) sed -n '2,24p' "$SELF" | sed 's/^# \{0,1\}//'; exit 2 ;;
esac
