# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project follows [Semantic Versioning](https://semver.org/).
Each version's heading says whether it was a major, minor or patch change.

## [Unreleased]

## [0.1.0] - 2026-10-27 (minor)

First release as a repository. The app itself is unchanged from the copy that
ran on ithilien, where it was installed by hand.

### Added

- `nosleep`, the PySide6 tray app that toggles PowerDevil's lid-close action
  between "Do nothing" and your normal action, leaving idle sleep alone.
- `install.sh`: per-user install and upgrade (no root), `--no-autostart`, and
  `--uninstall`, which stops a running nosleep and removes exactly the files it
  installed. Power settings and the app's own settings are left as they are.
- Application-menu and login-autostart desktop entries, both running the app by
  its absolute installed path.
- `tests/check.sh` and `tests/test_install.sh`: syntax checks and an
  install / uninstall test against a throwaway `HOME`.
