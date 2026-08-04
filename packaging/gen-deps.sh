#!/bin/bash
# Render dependency lists from deps.toml (the source of truth) and verify the
# spec / PKGBUILD carry exactly those deps.
#   gen-deps.sh print {fedora|arch} {main|gaming}   -> one dep per line, sorted
#   gen-deps.sh check                               -> exit 1 on any drift
# TOML parsing is deliberately minimal: top-level [section]s with
# fedora/arch string arrays and an optional subpackage key.
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
TOML="$REPO/deps.toml"
SPEC="$REPO/packaging/hypr-de.spec"
PKGBUILD="$REPO/packaging/PKGBUILD"

deps() { # $1=distro $2=part
    python3 - "$1" "$2" "$TOML" <<'EOF'
import sys, tomllib
distro, part, path = sys.argv[1:4]
data = tomllib.load(open(path, "rb"))
out = set()
for section in data.values():
    sub = section.get("subpackage", "main")
    if sub != part:
        continue
    out.update(section.get(distro, []) if distro.endswith("_weak") else section.get(distro, []))
print("\n".join(sorted(out)))
EOF
}

check() {
    fail=0
    # spec: Requires lines between package headers
    for part in main gaming; do
        want=$(deps fedora "$part")
        if [ "$part" = main ]; then
            have=$(awk '/^%package gaming/{exit} /^Requires:/{print $2}' "$SPEC" | LC_ALL=C sort -u)
        else
            have=$(awk '/^%package gaming/{g=1} g&&/^%description/{exit} g&&/^Requires:/{if ($2 !~ /^hypr-de/) print $2}' "$SPEC" | LC_ALL=C sort -u)
        fi
        if ! diff <(echo "$want") <(echo "$have") >/dev/null; then
            echo "DRIFT (spec, $part): deps.toml vs spec Requires:" >&2
            diff <(echo "$want") <(echo "$have") >&2 || true
            fail=1
        fi
    done
    # spec Recommends (main) must exactly match fedora_weak
    want=$(deps fedora_weak main)
    have=$(awk '/^%package gaming/{exit} /^Recommends:/{print $2}' "$SPEC" | LC_ALL=C sort -u)
    if ! diff <(echo "$want") <(echo "$have") >/dev/null; then
        echo "DRIFT (spec Recommends): deps.toml fedora_weak vs spec:" >&2
        diff <(echo "$want") <(echo "$have") >&2 || true
        fail=1
    fi
    # PKGBUILD: depends arrays from .SRCINFO-style print
    for part in main gaming; do
        want=$(deps arch "$part")
        var=$([ "$part" = main ] && echo "_depends_main" || echo "_depends_gaming")
        have=$(bash -c "source '$PKGBUILD' >/dev/null 2>&1; printf '%s\n' \"\${${var}[@]}\"" | grep -v '^hypr-de' | LC_ALL=C sort -u)
        if ! diff <(echo "$want") <(echo "$have") >/dev/null; then
            echo "DRIFT (PKGBUILD, $part): deps.toml vs $var:" >&2
            diff <(echo "$want") <(echo "$have") >&2 || true
            fail=1
        fi
    done
    [ "$fail" = 0 ] && echo "deps in sync"
    return "$fail"
}

case "${1:-}" in
    print) deps "${2:?distro}" "${3:?part}" ;;
    check) check ;;
    *) echo "usage: gen-deps.sh print {fedora|arch} {main|gaming} | check" >&2; exit 2 ;;
esac
