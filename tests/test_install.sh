#!/usr/bin/env bash
# Runs install.sh and install.sh --uninstall against throwaway HOMEs and checks
# that exactly the expected files appear and are removed again. It never runs
# nosleep itself, so the power behaviour of the machine running it is untouched.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/nosleep-test.XXXXXX")"
trap 'rm -rf -- "$WORK"' EXIT
LOG="$WORK/installer.log"  # output of the installer runs no check reads
: > "$LOG"

TESTS=0
fail() {
    echo "FAIL: $*" >&2
    local log
    for log in "$WORK"/*.log; do
        [[ -s "$log" ]] && { echo "--- $(basename "$log")" >&2; tail -n 20 "$log" >&2; }
    done
    exit 1
}
ok() { TESTS=$((TESTS + 1)); echo "ok $TESTS - $*"; }

# Run the installer with HOME pointed at $1 and every XDG base directory
# cleared, so nothing can reach the real home. Extra VAR=value pairs may
# precede the installer arguments via the INSTALL_ENV array.
INSTALL_ENV=()
run_installer() {  # home [installer args...]
    local home="$1"; shift
    env -u XDG_CONFIG_HOME -u XDG_DATA_HOME -u XDG_CACHE_HOME -u XDG_STATE_HOME \
        HOME="$home" ${INSTALL_ENV[@]+"${INSTALL_ENV[@]}"} \
        bash "$REPO/install.sh" "$@"
}

# Every file and symlink under a directory, with its mode and checksum.
snapshot() {  # dir
    (cd "$1" && find . \( -type f -o -type l \) -printf '%p %m\n' | sort | while read -r p m; do
        printf '%s %s %s\n' "$p" "$m" "$(sha256sum < "$p" | cut -d' ' -f1)"
    done)
}

desktop_exec() { sed -n 's/^Exec=//p' "$1"; }

validate_desktop() {  # file
    if command -v desktop-file-validate >/dev/null 2>&1; then
        desktop-file-validate --no-hints "$1" || fail "desktop-file-validate rejected $1"
    fi
}

check_installed() {  # home config_home data_home autostart(1|0)
    local home="$1" cfg="$2" data="$3" autostart="$4"
    local bin="$home/.local/bin/nosleep"
    local icon="$data/icons/hicolor/scalable/apps/nosleep.svg"
    local launcher="$data/applications/nosleep.desktop"
    local auto="$cfg/autostart/nosleep.desktop"

    [[ -f "$bin" && -x "$bin" ]] || fail "$bin missing or not executable"
    [[ "$(stat -c %a "$bin")" == 755 ]] || fail "$bin mode is not 755"
    cmp -s "$bin" "$REPO/nosleep" || fail "$bin differs from the repo script"
    [[ -f "$icon" && "$(stat -c %a "$icon")" == 644 ]] || fail "$icon missing or mode not 644"
    cmp -s "$icon" "$REPO/nosleep.svg" || fail "$icon differs from the repo icon"
    [[ -f "$launcher" && "$(stat -c %a "$launcher")" == 644 ]] || fail "$launcher missing or mode not 644"
    validate_desktop "$launcher"
    if [[ $autostart == 1 ]]; then
        [[ -f "$auto" && "$(stat -c %a "$auto")" == 644 ]] || fail "$auto missing or mode not 644"
        validate_desktop "$auto"
        grep -qx 'X-GNOME-Autostart-enabled=true' "$auto" || fail "$auto lacks X-GNOME-Autostart-enabled"
    else
        [[ ! -e "$auto" ]] || fail "$auto present with --no-autostart"
    fi
    if grep -rq '@NOSLEEP_BIN@' "$data/applications" "$cfg/autostart" 2>/dev/null; then
        fail "an unsubstituted @NOSLEEP_BIN@ placeholder was installed"
    fi
}

seed_unrelated() {  # home config_home
    # Files the installer must never touch: an unrelated autostart entry and
    # binary, the app's own settings, and PowerDevil's config with the lid
    # still held awake (as it would be after toggling nosleep on).
    mkdir -p "$2/autostart" "$1/.local/bin" "$2/nosleep"
    printf '[Desktop Entry]\nType=Application\nName=Other\nExec=true\n' > "$2/autostart/other.desktop"
    printf '#!/bin/sh\nexit 0\n' > "$1/.local/bin/other-tool"
    chmod 755 "$1/.local/bin/other-tool"
    printf '[General]\nrestore_AC=1\nrestore_Battery=1\n' > "$2/nosleep/nosleep.conf"
    printf '[AC][SuspendAndShutdown]\nLidAction=0\n\n[Battery][SuspendAndShutdown]\nLidAction=1\n' > "$2/powerdevilrc"
}

# --- default layout ---------------------------------------------------------

H="$WORK/home"
mkdir -p "$H"
seed_unrelated "$H" "$H/.config"
before="$(snapshot "$H")"

run_installer "$H" > "$WORK/install1.log" 2>&1
check_installed "$H" "$H/.config" "$H/.local/share" 1
ok "install puts the script, icon, launcher and autostart entry in place"

[[ "$(desktop_exec "$H/.local/share/applications/nosleep.desktop")" == "$H/.local/bin/nosleep" ]] \
    || fail "launcher Exec is not the installed absolute path"
[[ "$(desktop_exec "$H/.config/autostart/nosleep.desktop")" == "$H/.local/bin/nosleep" ]] \
    || fail "autostart Exec is not the installed absolute path"
ok "desktop entries point at the installed script by absolute path"

grep -q "Installed nosleep $(<"$REPO/VERSION")" "$WORK/install1.log" || fail "install did not report its version"
ok "install reports VERSION"

first="$(snapshot "$H")"
run_installer "$H" >> "$LOG" 2>&1
[[ "$(snapshot "$H")" == "$first" ]] || fail "a second install changed the installed files"
ok "re-running install is idempotent"

run_installer "$H" --no-autostart >> "$LOG" 2>&1
check_installed "$H" "$H/.config" "$H/.local/share" 0
[[ -f "$H/.config/autostart/other.desktop" ]] || fail "--no-autostart removed an unrelated autostart entry"
ok "--no-autostart removes only nosleep's autostart entry"

run_installer "$H" >> "$LOG" 2>&1
[[ "$(snapshot "$H")" == "$first" ]] || fail "re-install after --no-autostart did not restore the same files"
ok "a plain re-install restores the autostart entry"

run_installer "$H" --uninstall > "$WORK/uninstall1.log" 2>&1
for f in .local/bin/nosleep .local/share/icons/hicolor/scalable/apps/nosleep.svg \
         .local/share/applications/nosleep.desktop .config/autostart/nosleep.desktop; do
    [[ ! -e "$H/$f" ]] || fail "uninstall left $H/$f"
done
ok "uninstall removes all four installed files"

[[ "$(snapshot "$H")" == "$before" ]] || {
    diff <(echo "$before") <(snapshot "$H") >&2 || true
    fail "uninstall did not return HOME to exactly its pre-install files"
}
ok "uninstall leaves unrelated files, the app's settings and powerdevilrc untouched"

if command -v kreadconfig6 >/dev/null 2>&1; then
    grep -q 'still set to "Do nothing" (AC)' "$WORK/uninstall1.log" \
        || fail "uninstall did not warn that the AC lid action is still held"
    ok "uninstall notes the lid action it leaves held (AC only)"
fi

run_installer "$H" --uninstall > "$WORK/uninstall2.log" 2>&1
grep -q 'Nothing to remove' "$WORK/uninstall2.log" || fail "second uninstall did not report nothing to remove"
[[ "$(snapshot "$H")" == "$before" ]] || fail "second uninstall changed files"
ok "re-running uninstall is a harmless no-op"

# --- XDG base directories and a HOME with a space -------------------------------

H2="$WORK/home with space"
mkdir -p "$H2"
INSTALL_ENV=(XDG_CONFIG_HOME="$H2/cfg" XDG_DATA_HOME="$H2/data")
run_installer "$H2" >> "$LOG" 2>&1
check_installed "$H2" "$H2/cfg" "$H2/data" 1
[[ ! -e "$H2/.config" && ! -e "$H2/.local/share" ]] || fail "XDG overrides were ignored"
[[ "$(desktop_exec "$H2/data/applications/nosleep.desktop")" == "\"$H2/.local/bin/nosleep\"" ]] \
    || fail "an Exec path with a space is not quoted"
ok "install honours XDG_CONFIG_HOME / XDG_DATA_HOME and quotes a path with a space"

run_installer "$H2" --uninstall >> "$LOG" 2>&1
leftover="$(find "$H2" \( -type f -o -type l \) -print)"
[[ -z "$leftover" ]] || fail "uninstall left files under the XDG layout: $leftover"
ok "uninstall under the XDG layout leaves no files behind"
INSTALL_ENV=()

# --- argument handling ------------------------------------------------------------

set +e
run_installer "$WORK/home" --bogus > /dev/null 2>&1
rc=$?
set -e
[[ $rc == 2 ]] || fail "an unknown option exited $rc, not 2"
run_installer "$WORK/home" --help | grep -q -- '--uninstall' || fail "--help does not list --uninstall"
ok "unknown options are rejected and --help documents the flags"

echo "all $TESTS checks passed"
