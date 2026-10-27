#!/usr/bin/env bash
# Runs install.sh and install.sh --uninstall against throwaway HOMEs and checks
# that exactly the expected files appear and are removed again. It never runs
# nosleep itself, so the power behaviour of the machine running it is untouched:
# the "running nosleep" the stop test needs is `tail -f` renamed to python3.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/nosleep-test.XXXXXX")"
BG_PIDS=()  # background stand-ins started here and not yet reaped
cleanup() {
    if [[ ${#BG_PIDS[@]} -gt 0 ]]; then
        kill "${BG_PIDS[@]}" 2>/dev/null || true
        wait "${BG_PIDS[@]}" 2>/dev/null || true
    fi
    rm -rf -- "$WORK"
}
trap cleanup EXIT
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

# A python3 for installer runs only, so the PySide6 import check answers the
# same on every machine: importable unless FAKE_PYSIDE=missing.
FAKEBIN="$WORK/fakebin"
mkdir -p "$FAKEBIN"
cat > "$FAKEBIN/python3" <<'EOF'
#!/bin/sh
[ "${FAKE_PYSIDE:-present}" = missing ] && exit 1
exit 0
EOF
chmod 755 "$FAKEBIN/python3"

# Run the installer with HOME pointed at $1 and every XDG base directory
# cleared, so nothing can reach the real home. INSTALL_ENV adds VAR=value
# pairs; RUNNER wraps the call (e.g. unshare -r).
INSTALL_ENV=()
RUNNER=()
run_installer() {  # home [installer args...]
    local home="$1"; shift
    env -u XDG_CONFIG_HOME -u XDG_DATA_HOME -u XDG_CACHE_HOME -u XDG_STATE_HOME \
        HOME="$home" PATH="$FAKEBIN:$PATH" ${INSTALL_ENV[@]+"${INSTALL_ENV[@]}"} \
        ${RUNNER[@]+"${RUNNER[@]}"} bash "$REPO/install.sh" "$@"
}

# Every file and symlink under a directory, with its mode and checksum.
snapshot() {  # dir
    (cd "$1" && find . \( -type f -o -type l \) -printf '%p %m\n' | sort | while read -r p m; do
        printf '%s %s %s\n' "$p" "$m" "$(sha256sum < "$p" | cut -d' ' -f1)"
    done)
}

desktop_exec_raw() { sed -n 's/^Exec=//p' "$1"; }

# The path a desktop entry's Exec runs, decoded the way readers do: string
# escapes first, then one double-quoted argument's escapes, then %%. Anything
# the spec does not allow (an unquoted value, a bare reserved character, a
# lone %) makes it fail, so the caller's comparison fails too.
exec_path() {  # desktop file
    python3 -I - "$(desktop_exec_raw "$1")" <<'PY'
import re, sys
raw = sys.argv[1]
string_escapes = {"s": " ", "n": "\n", "t": "\t", "r": "\r", "\\": "\\"}
out, i = [], 0
while i < len(raw):
    if raw[i] == "\\" and i + 1 < len(raw) and raw[i + 1] in string_escapes:
        out.append(string_escapes[raw[i + 1]]); i += 2
    else:
        out.append(raw[i]); i += 1
value = "".join(out)
if len(value) < 2 or value[0] != '"' or value[-1] != '"':
    sys.exit("Exec is not one quoted argument: " + raw)
arg, i, inner = [], 0, value[1:-1]
while i < len(inner):
    c = inner[i]
    if c == "\\":
        if i + 1 >= len(inner) or inner[i + 1] not in '"`$\\':
            sys.exit("bad escape in Exec: " + raw)
        arg.append(inner[i + 1]); i += 2
    elif c in '"`$':
        sys.exit("unescaped reserved character in Exec: " + raw)
    else:
        arg.append(c); i += 1
path = "".join(arg)
if re.sub("%%", "", path).count("%"):
    sys.exit("lone % in Exec: " + raw)
print(path.replace("%%", "%"), end="")
PY
}

validate_desktop() {  # file
    command -v desktop-file-validate >/dev/null 2>&1 || return 0
    local out
    out="$(desktop-file-validate "$1" 2>&1)" || fail "desktop-file-validate rejected $1: $out"
    [[ -z "$out" ]] || fail "desktop-file-validate reported on $1: $out"
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
    grep -qx 'StartupNotify=false' "$launcher" || fail "$launcher lacks StartupNotify=false"
    grep -qx 'Categories=Utility;' "$launcher" || fail "$launcher is not in the single main category Utility"
    [[ "$(exec_path "$launcher")" == "$bin" ]] || fail "$launcher Exec does not decode to $bin"
    if [[ $autostart == 1 ]]; then
        [[ -f "$auto" && "$(stat -c %a "$auto")" == 644 ]] || fail "$auto missing or mode not 644"
        validate_desktop "$auto"
        grep -qx 'X-GNOME-Autostart-enabled=true' "$auto" || fail "$auto lacks X-GNOME-Autostart-enabled"
        grep -qx 'StartupNotify=false' "$auto" || fail "$auto lacks StartupNotify=false"
        [[ "$(exec_path "$auto")" == "$bin" ]] || fail "$auto Exec does not decode to $bin"
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

# Start `tail <file> -f` in the background with argv[0] set to $1, and wait
# until the exec has happened so /proc shows the final command line. Sets
# BG_PID; the process stays this shell's child, so its pid is not reused
# before it is reaped.
start_stand_in() {  # argv0 file
    bash -c 'exec -a "$1" tail "$2" -f' _ "$1" "$2" > /dev/null 2>&1 &
    BG_PID=$!
    BG_PIDS+=("$BG_PID")
    local i
    for ((i = 0; i < 100; i++)); do
        [[ "$(tr '\0' '\n' < "/proc/$BG_PID/cmdline" 2>/dev/null | head -n 1)" == "$1" ]] && return 0
        sleep 0.05
    done
    fail "stand-in $1 $2 did not start"
}

gone() {  # pid: true once it has exited (absent or a zombie)
    local stat
    stat="$(ps -o stat= -p "$1" 2>/dev/null || true)"
    [[ -z "$stat" || "$stat" == Z* ]]
}

# --- default layout ---------------------------------------------------------

H="$WORK/home"
mkdir -p "$H"
seed_unrelated "$H" "$H/.config"
before="$(snapshot "$H")"

run_installer "$H" > "$WORK/install1.log" 2>&1
check_installed "$H" "$H/.config" "$H/.local/share" 1
ok "install puts the script, icon, launcher and autostart entry in place"

[[ "$(desktop_exec_raw "$H/.local/share/applications/nosleep.desktop")" == "\"$H/.local/bin/nosleep\"" ]] \
    || fail "launcher Exec is not the quoted absolute path"
[[ "$(desktop_exec_raw "$H/.config/autostart/nosleep.desktop")" == "\"$H/.local/bin/nosleep\"" ]] \
    || fail "autostart Exec is not the quoted absolute path"
ok "desktop entries run the installed script by its quoted absolute path"

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
else
    echo "skip - lid note: kreadconfig6 not installed"
fi

run_installer "$H" --uninstall > "$WORK/uninstall2.log" 2>&1
grep -q 'Nothing to remove' "$WORK/uninstall2.log" || fail "second uninstall did not report nothing to remove"
[[ "$(snapshot "$H")" == "$before" ]] || fail "second uninstall changed files"
ok "re-running uninstall is a harmless no-op"

# --- XDG base directories and a HOME with a space -----------------------------

H2="$WORK/home with space"
mkdir -p "$H2"
INSTALL_ENV=(XDG_CONFIG_HOME="$H2/cfg" XDG_DATA_HOME="$H2/data")
run_installer "$H2" >> "$LOG" 2>&1
check_installed "$H2" "$H2/cfg" "$H2/data" 1
[[ ! -e "$H2/.config" && ! -e "$H2/.local/share" ]] || fail "XDG overrides were ignored"
ok "install honours XDG_CONFIG_HOME / XDG_DATA_HOME, with a space in the path"

run_installer "$H2" --uninstall >> "$LOG" 2>&1
leftover="$(find "$H2" \( -type f -o -type l \) -print)"
[[ -z "$leftover" ]] || fail "uninstall left files under the XDG layout: $leftover"
ok "uninstall under the XDG layout leaves no files behind"
INSTALL_ENV=()

# --- reserved characters, and stopping only the real running nosleep ----------

HW="$WORK/we+ird (h\$ome) 100% \`q\` \"x\" b\\s"
mkdir -p "$HW"
run_installer "$HW" >> "$LOG" 2>&1
check_installed "$HW" "$HW/.config" "$HW/.local/share" 1
ok "Exec escapes + ( ) \$ % \` \" and \\ per the desktop entry spec and validates"

BIN_W="$HW/.local/bin/nosleep"
OTHER_W="$HW/.local/bin/nosleep-other"
printf 'not nosleep\n' > "$OTHER_W"
start_stand_in python3 "$BIN_W";   running="$BG_PID"    # what the shebang runs
start_stand_in tail "$BIN_W";      decoy_tail="$BG_PID" # a pager on the file
start_stand_in python3 "$OTHER_W"; decoy_py="$BG_PID"   # python3, another file

run_installer "$HW" --uninstall > "$WORK/uninstall3.log" 2>&1
for ((i = 0; i < 100; i++)); do gone "$running" && break; sleep 0.05; done
gone "$running" || fail "--uninstall did not stop python3 $BIN_W (pid $running)"
grep -qF "Stopped the running nosleep (pid $running)." "$WORK/uninstall3.log" \
    || fail "uninstall did not report stopping exactly pid $running"
ok "--uninstall stops the running nosleep, found by literal path under a regex-hostile HOME"

! gone "$decoy_tail" || fail "uninstall stopped a non-python process holding the installed path"
! gone "$decoy_py" || fail "uninstall stopped python3 running a different file"
ok "--uninstall leaves a pager on the file and python3 on another file running"

kill "$decoy_tail" "$decoy_py"
wait "${BG_PIDS[@]}" 2>/dev/null || true
BG_PIDS=()
rm -f -- "$OTHER_W"
leftover="$(find "$HW" \( -type f -o -type l \) -print)"
[[ -z "$leftover" ]] || fail "uninstall left files under the escaped HOME: $leftover"

# --- PySide6 missing -------------------------------------------------------------

H3="$WORK/no-pyside"
mkdir -p "$H3"
INSTALL_ENV=(FAKE_PYSIDE=missing)
set +e
run_installer "$H3" > "$WORK/nopyside.log" 2>&1
rc=$?
set -e
[[ $rc == 3 ]] || fail "install without PySide6 exited $rc, not 3"
grep -qF 'sudo pacman -S --needed pyside6' "$WORK/nopyside.log" || fail "the refusal does not name the pacman line"
[[ -z "$(find "$H3" -mindepth 1 -print)" ]] || fail "a refused install wrote under HOME"
ok "without PySide6 the install stops (exit 3), names the pacman line and writes nothing"

run_installer "$H3" --force > "$WORK/force.log" 2>&1
check_installed "$H3" "$H3/.config" "$H3/.local/share" 1
grep -qF 'installing anyway (--force)' "$WORK/force.log" || fail "--force did not warn"
run_installer "$H3" --uninstall >> "$LOG" 2>&1
INSTALL_ENV=()
ok "--force installs without PySide6, with a warning"

# --- root ------------------------------------------------------------------------

if unshare -r true 2>/dev/null; then
    HR="$WORK/as-root"
    mkdir -p "$HR"
    RUNNER=(unshare -r)
    for args in install --uninstall; do
        [[ $args == install ]] && args=""
        set +e
        run_installer "$HR" ${args:+"$args"} > "$WORK/root.log" 2>&1
        rc=$?
        set -e
        [[ $rc == 1 ]] || fail "running as root (${args:-install}) exited $rc, not 1"
        grep -q 'Refusing to run as root' "$WORK/root.log" || fail "root refusal message missing"
    done
    RUNNER=()
    [[ -z "$(find "$HR" -mindepth 1 -print)" ]] || fail "a refused root run wrote under HOME"
    ok "install and --uninstall refuse to run as root and write nothing"
else
    echo "skip - root refusal: unshare -r is not permitted here"
fi

# --- argument handling ------------------------------------------------------------

set +e
run_installer "$WORK/home" --bogus > /dev/null 2>&1
rc=$?
set -e
[[ $rc == 2 ]] || fail "an unknown option exited $rc, not 2"
help="$(run_installer "$WORK/home" --help)"
for flag in --no-autostart --force --uninstall; do
    grep -q -- "$flag" <<< "$help" || fail "--help does not list $flag"
done
ok "unknown options are rejected and --help documents the flags"

echo "all $TESTS checks passed"
