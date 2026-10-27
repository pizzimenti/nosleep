# nosleep

KDE Plasma 6 tray toggle that keeps a laptop awake when its lid is closed, and
changes nothing else about power management.

Current version: `0.1.0` · See [CHANGELOG.md](CHANGELOG.md) · Use GitHub Issues for bugs and feature requests.

## What it does

nosleep changes one thing: the action PowerDevil takes when you close the lid.

| Tray icon | Lid close |
|---|---|
| Steaming cup | Does nothing; the system stays awake |
| Empty grey cup | Your normal action (Sleep unless you set another) |

- **Left- or middle-click** the icon to toggle. The right-click menu has the
  same toggle plus *Start on login*, *Show notifications*, *About* and *Quit*.
- **Idle sleep is untouched.** If your "suspend after N minutes" timer fires,
  the machine still sleeps. The battery widget's *Manually block sleep and
  screen locking* toggle is a separate thing and is also left alone.
- **No lock to leak.** It writes `LidAction` for the AC and Battery profiles in
  `~/.config/powerdevilrc` (via `kwriteconfig6`) and asks PowerDevil to reload
  over D-Bus. The setting is PowerDevil's own, so it survives restarts and
  stays as set when you quit nosleep. Turning it off restores the lid action
  you had before (remembered in `~/.config/nosleep/nosleep.conf`).
- On a machine without a lid the menu says *No laptop lid detected*.

## Requirements

- KDE Plasma 6 with PowerDevil (verified on Plasma 6.6, Wayland)
- `kreadconfig6` and `kwriteconfig6` (KDE Frameworks 6 KConfig; installed with Plasma)
- Python 3 with PySide6 (QtWidgets, QtSvg, QtDBus). Arch/Manjaro: `pyside6`;
  elsewhere your distribution's PySide6 packages or `python3 -m pip install --user PySide6`
- A system tray (Plasma's is fine)

No root: everything installs into your home directory.

## Install

```bash
git clone https://github.com/pizzimenti/nosleep.git && cd nosleep
./install.sh
```

The installer (per user, idempotent; re-run it to upgrade):

| Path | Role |
|------|------|
| `~/.local/bin/nosleep` | The tray app |
| `~/.local/share/icons/hicolor/scalable/apps/nosleep.svg` | Its icon |
| `~/.local/share/applications/nosleep.desktop` | Application-menu entry |
| `~/.config/autostart/nosleep.desktop` | Starts it on login |

`$XDG_DATA_HOME` and `$XDG_CONFIG_HOME` replace `~/.local/share` and `~/.config`
when set. The desktop entries run the app by its absolute path, so it starts
even when `~/.local/bin` is not on the session's `PATH`.

It does not start the app; launch *NoSleep* from the menu, or log out and in.
If an older version is running, quit it from its tray menu and start it again.

Options:

```bash
./install.sh --no-autostart   # install / upgrade without starting on login
./install.sh --uninstall      # remove the four files above
```

The *Start on login* menu item writes and removes the same autostart entry, so
it and `--no-autostart` agree. A plain re-install turns autostart back on.

## Uninstall

```bash
./install.sh --uninstall
```

This stops a running nosleep and removes exactly the four installed files. It
does not change your power settings: if the lid was set to stay awake, it stays
that way (the uninstaller says so); set it back in System Settings > Power
Management, or toggle nosleep off before uninstalling. The app's settings in
`~/.config/nosleep/` are left in place; delete that directory by hand if you
want them gone.

## Tests

```bash
tests/check.sh
```

Runs `bash -n` on every shell file, `shellcheck` when installed, a parse of the
Python script (nothing is executed), and `tests/test_install.sh`, which installs
into a throwaway `HOME` and checks the files, their modes and contents, the
absolute `Exec` paths, idempotency, `--no-autostart`, XDG overrides, a `HOME`
with a space, and that `--uninstall` returns the home to exactly its prior
files (unrelated files, the app's settings and `powerdevilrc` untouched). The
tests never run nosleep, so they are safe on any machine.

## License

MIT (see `LICENSE`)
