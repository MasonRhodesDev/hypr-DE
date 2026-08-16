#!/bin/bash
# Build the SRPM (source tarball from a git tag) and optionally submit it to
# COPR. Derived from waybar-workspace-buttons' non-Rust variant.
#
# Release flow (Fedora + Arch from the same tag):
#   1. Bump spec Version (+ %changelog) + PKGBUILD pkgver — one commit.
#   2. git tag vX.Y.Z && git push --tags
#   3. CI (packaging-workflows release.yml) publishes both distros.
#
# --head builds from HEAD instead of the tag (local/CI testing only).
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
NAME=hypr-de
TARPREFIX=hypr-DE            # GitHub repo name != pkgname; tarball prefix must match spec %autosetup -n
SPEC="$REPO/packaging/$NAME.spec"
SOURCES="${HOME}/rpmbuild/SOURCES"
COPR_PROJECT="${COPR_PROJECT:-$NAME}"

VER=$(sed -n 's/^Version:[[:space:]]*//p' "$SPEC")
PKGBUILD_VER=$(sed -n 's/^pkgver=//p' "$REPO/packaging/PKGBUILD")
if [ "$PKGBUILD_VER" != "$VER" ]; then
    echo "ERROR: version mismatch: spec Version=$VER, PKGBUILD pkgver=$PKGBUILD_VER" >&2
    echo "Bump both together (deps drift is gated separately by gen-deps.sh check)." >&2
    exit 1
fi

# Dependency drift gate (deps.toml is the source of truth)
"$REPO/packaging/gen-deps.sh" check

REF="v$VER"
if [ "${1:-}" = "--head" ]; then
    REF="HEAD"
    echo "WARNING: building from HEAD (testing only)"
    shift
elif ! git -C "$REPO" rev-parse -q --verify "refs/tags/$REF" >/dev/null; then
    echo "ERROR: tag $REF not found — tag the release first (or use --head to test)" >&2
    exit 1
fi

mkdir -p "$SOURCES"
echo "==> source tarball from $REF"
git -C "$REPO" archive --format=tar.gz --prefix="$TARPREFIX-$VER/" \
    -o "$SOURCES/$TARPREFIX-$VER.tar.gz" "$REF"

echo "==> building SRPM"
SRPM=$(rpmbuild -bs "$SPEC" | sed -n 's/^Wrote: //p')
echo "    $SRPM"

if [ "${1:-}" = "--copr" ]; then
    echo "==> submitting to COPR project $COPR_PROJECT"
    if ! copr-cli build "$COPR_PROJECT" "$SRPM"; then
        echo "ERROR: copr build failed. If this was a 401, the API token has" >&2
        echo "expired (~180 days) — renew at https://copr.fedorainfracloud.org/api/" >&2
        exit 1
    fi
fi
