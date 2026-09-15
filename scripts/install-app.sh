#!/bin/sh
# Build DropCode, install it to /Applications (or $INSTALL_DIR), and relaunch it.
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
INSTALL_DIR=${INSTALL_DIR:-/Applications}
TARGET="$INSTALL_DIR/DropCode.app"

BUILT=$("$ROOT/scripts/build-app.sh" | tail -n 1)

if pgrep -x DropCode >/dev/null 2>&1; then
    pkill -x DropCode
    # Wait for the previous instance to exit so the new one does not bail out
    # from its single-instance check.
    for _ in 1 2 3 4 5 6 7 8 9 10; do
        pgrep -x DropCode >/dev/null 2>&1 || break
        sleep 0.2
    done
fi

mkdir -p "$INSTALL_DIR"
rm -rf "$TARGET"
ditto "$BUILT" "$TARGET"
open "$TARGET"

printf '%s\n' "$TARGET"
