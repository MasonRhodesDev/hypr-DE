#!/bin/bash
# Substitute @TOKEN@ install paths into a staged copy of dist/.
#   usage: substitute.sh <staged-dist-dir>
# Token values come from packaging/paths.conf (env-overridable per distro).
# Binary files (e.g. wallpapers) are skipped by the text-file test.
set -euo pipefail

STAGE="${1:?usage: substitute.sh <staged-dist-dir>}"
. "$(dirname "$0")/paths.conf"

find "$STAGE" -type f | while read -r f; do
    if file -b --mime-encoding "$f" | grep -qv binary; then
        sed -i \
            -e "s|@BINDIR@|$BINDIR|g" \
            -e "s|@DATADIR@|$DATADIR|g" \
            -e "s|@LIBEXECDIR@|$LIBEXECDIR|g" \
            -e "s|@WAYBAR_CFFI@|$WAYBAR_CFFI|g" \
            "$f"
    fi
done

# Gate: none of OUR tokens may survive (@DEFAULT_AUDIO_SINK@ etc. are wpctl's)
if LEFT=$(grep -rn "@\(BINDIR\|DATADIR\|LIBEXECDIR\|WAYBAR_CFFI\|UNITDIR\|PRESETDIR\|ENVGENDIR\|XDGCONFDIR\)@" "$STAGE" -l 2>/dev/null | head -5) && [ -n "$LEFT" ]; then
    echo "ERROR: unsubstituted tokens remain in: $LEFT" >&2
    exit 1
fi
