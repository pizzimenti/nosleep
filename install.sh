#!/usr/bin/env bash
# nosleep installer. Installs for the current user only; never needs root.
#
#   ./install.sh                 install / upgrade (starts on login)
#   ./install.sh --no-autostart  install / upgrade without the login autostart
#                                entry (removes one left by an earlier install)
#   ./install.sh --uninstall     remove everything install.sh installed
set -euo pipefail

SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

AUTOSTART=1
UNINSTALL=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --no-autostart) AUTOSTART=0; shift ;;
        --uninstall) UNINSTALL=1; shift ;;
        -h|--help) sed -n '2,7p' "$SELF" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "unknown option: $1" >&2; exit 2 ;;
    esac
done

# Everything lands in the invoking user's home. Under sudo it would land in
# root's, which is never what anyone wants for a tray app.
if [[ $EUID -eq 0 ]]; then
    echo "Refusing to run as root; nosleep installs per user. Re-run install.sh as your user." >&2
    exit 1
fi
if [[ "${HOME:-}" != /* ]]; then
    echo "HOME is not set to an absolute path; cannot tell where to install." >&2
    exit 1
fi

VERSION="$(<"$ROOT_DIR/VERSION")"

# Same locations the app itself uses: QStandardPaths honours XDG_CONFIG_HOME
# for the autostart entry its "Start on login" toggle writes.
CONFIG_HOME="${XDG_CONFIG_HOME:-$HOME/.config}"
DATA_HOME="${XDG_DATA_HOME:-$HOME/.local/share}"

TARGET_BIN="$HOME/.local/bin/nosleep"
TARGET_ICON="$DATA_HOME/icons/hicolor/scalable/apps/nosleep.svg"
TARGET_LAUNCHER="$DATA_HOME/applications/nosleep.desktop"
TARGET_AUTOSTART="$CONFIG_HOME/autostart/nosleep.desktop"
SETTINGS_DIR="$CONFIG_HOME/nosleep"

# PIDs of this user's running nosleep, matched on the exact installed path
# (argv[1] of "python3 <path>"), so nothing else with a similar name is hit.
running_pids() {
    local pid
    for pid in $(pgrep -u "$(id -u)" -f -- "$TARGET_BIN" 2>/dev/null || true); do
        if [[ "$(tr '\0' '\n' < "/proc/$pid/cmdline" 2>/dev/null | sed -n 2p)" == "$TARGET_BIN" ]]; then
            echo "$pid"
        fi
    done
}

# Desktop entries carry an absolute Exec, as the app's own autostart writer
# does: ~/.local/bin is often not on the session or systemd --user PATH.
render_desktop() {  # template dest
    local exec_value="$TARGET_BIN" text
    [[ "$exec_value" =~ [[:space:]] ]] && exec_value="\"$exec_value\""
    text="$(<"$1")"
    text="${text//@NOSLEEP_BIN@/"$exec_value"}"
    install -Dm644 /dev/stdin "$2" <<< "$text"
}

# The lid-close action lives in PowerDevil's config, not in anything installed
# here, so neither Quit nor uninstall changes it. Say so if it is still held.
lid_note() {
    command -v kreadconfig6 >/dev/null 2>&1 || return 0
    local profile value held=()
    for profile in AC Battery; do
        value="$(kreadconfig6 --file powerdevilrc --group "$profile" \
            --group SuspendAndShutdown --key LidAction 2>/dev/null || true)"
        [[ "$value" == 0 ]] && held+=("$profile")
    done
    if [[ ${#held[@]} -gt 0 ]]; then
        echo
        echo "Note: closing the lid is still set to \"Do nothing\" (${held[*]})."
        echo "      Uninstalling does not change power settings. To make the lid sleep"
        echo "      again, set it in System Settings > Power Management."
    fi
}

check_dependencies() {
    if ! command -v python3 >/dev/null 2>&1; then
        echo "Warning: python3 not found; nosleep needs Python 3 with PySide6." >&2
    elif ! python3 -c 'import PySide6.QtWidgets, PySide6.QtSvg, PySide6.QtDBus' >/dev/null 2>&1; then
        echo "Warning: PySide6 (QtWidgets, QtSvg, QtDBus) is not importable by python3." >&2
        echo "         Arch/Manjaro: sudo pacman -S pyside6; elsewhere your distribution's" >&2
        echo "         PySide6 packages, or: python3 -m pip install --user PySide6" >&2
    fi
    local tool
    for tool in kreadconfig6 kwriteconfig6; do
        command -v "$tool" >/dev/null 2>&1 \
            || echo "Warning: $tool not found; nosleep needs KDE Plasma 6 (PowerDevil, KConfig)." >&2
    done
}

# ---------------------------------------------------------------------------
# Uninstall
# ---------------------------------------------------------------------------

if [[ $UNINSTALL == 1 ]]; then
    mapfile -t pids < <(running_pids)
    if [[ ${#pids[@]} -gt 0 ]]; then
        kill -- "${pids[@]}" 2>/dev/null || true
        echo "Stopped the running nosleep (pid ${pids[*]})."
    fi
    removed=()
    for path in "$TARGET_AUTOSTART" "$TARGET_LAUNCHER" "$TARGET_ICON" "$TARGET_BIN"; do
        if [[ -e "$path" || -L "$path" ]]; then
            rm -f -- "$path"
            removed+=("$path")
        fi
    done
    if [[ ${#removed[@]} -gt 0 ]]; then
        printf 'Removed:\n'
        printf '  %s\n' "${removed[@]}"
    else
        echo "Nothing to remove; nosleep was not installed."
    fi
    if [[ -d "$SETTINGS_DIR" ]]; then
        echo "Left in place: $SETTINGS_DIR (the app's settings, including the lid action"
        echo "  it restores when toggled off). Delete it by hand if you no longer want it."
    fi
    lid_note
    echo "nosleep uninstalled."
    exit 0
fi

# ---------------------------------------------------------------------------
# Install / upgrade
# ---------------------------------------------------------------------------

check_dependencies

install -Dm755 "$ROOT_DIR/nosleep" "$TARGET_BIN"
install -Dm644 "$ROOT_DIR/nosleep.svg" "$TARGET_ICON"
render_desktop "$ROOT_DIR/nosleep.desktop" "$TARGET_LAUNCHER"
if [[ $AUTOSTART == 1 ]]; then
    render_desktop "$ROOT_DIR/nosleep-autostart.desktop" "$TARGET_AUTOSTART"
else
    rm -f -- "$TARGET_AUTOSTART"
fi

printf 'Installed nosleep %s:\n' "$VERSION"
printf '  %s\n' "$TARGET_BIN" "$TARGET_ICON" "$TARGET_LAUNCHER"
if [[ $AUTOSTART == 1 ]]; then
    printf '  %s\n' "$TARGET_AUTOSTART"
else
    printf 'Not starting on login (--no-autostart).\n'
fi

mapfile -t pids < <(running_pids)
if [[ ${#pids[@]} -gt 0 ]]; then
    echo
    echo "nosleep is running (pid ${pids[*]}) with the previous version. Quit it from"
    echo "its tray menu and start it again (or log out and in) to load $VERSION."
else
    echo
    echo "Start it now from the application menu (NoSleep), or run: $TARGET_BIN"
fi
case ":$PATH:" in
    *":$HOME/.local/bin:"*) ;;
    *) echo "Note: $HOME/.local/bin is not on PATH; the menu entry works regardless." ;;
esac
