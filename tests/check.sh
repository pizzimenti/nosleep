#!/usr/bin/env bash
# All of nosleep's checks: syntax of every shell file, shellcheck when it is
# installed, a parse of the Python script (no bytecode written, nothing run),
# then the install/uninstall test against a throwaway HOME.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SHELL_FILES=("$REPO/install.sh" "$REPO/tests/check.sh" "$REPO/tests/test_install.sh")

for f in "${SHELL_FILES[@]}"; do
    bash -n "$f"
done
echo "ok - bash -n: ${#SHELL_FILES[@]} files"

if command -v shellcheck >/dev/null 2>&1; then
    shellcheck "${SHELL_FILES[@]}"
    echo "ok - shellcheck"
else
    echo "skip - shellcheck not installed"
fi

python3 -c 'import ast, sys; ast.parse(open(sys.argv[1], encoding="utf-8").read(), sys.argv[1])' "$REPO/nosleep"
echo "ok - nosleep parses as Python"

bash "$REPO/tests/test_install.sh"
