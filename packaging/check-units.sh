#!/bin/bash
set -uo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
DIST="${1:-$REPO/dist}"
UNITDIR="$DIST/systemd/user"
PRESET="$DIST/systemd/user-preset/90-hypr-de.preset"
SETUP="$DIST/bin/hypr-de-setup"
TOML="$REPO/deps.toml"

fail=0
bad() { printf 'UNIT-DRIFT: %s\n' "$*" >&2; fail=1; }

[ -d "$UNITDIR" ] || { echo "no unit dir at $UNITDIR" >&2; exit 2; }
[ -f "$PRESET" ]  || { echo "no preset at $PRESET" >&2; exit 2; }

declare -A UNMANAGED=(
)
declare -A UNIT_PKG=(
    ["obex.service"]="bluez-obex"
    ["logind-idle-control-tray.service"]="logind-idle-control"
)

declared=()
mapfile -t shipped < <(
    for f in "$UNITDIR"/*.service "$UNITDIR"/*.timer "$UNITDIR"/*.path "$UNITDIR"/*.socket; do
        [ -e "$f" ] && basename "$f"
    done | sort
)
mapfile -t preset  < <(grep -oE '^(enable|disable)[[:space:]]+\S+' "$PRESET" | awk '{print $2}' | sort -u)

in_list() { local n="$1"; shift; local x; for x in "$@"; do [ "$x" = "$n" ] && return 0; done; return 1; }
pulled_in() {
    grep -hE '^(Wants|Requires|BindsTo|Upholds|OnFailure|OnSuccess)=' \
        "$UNITDIR"/*.service "$UNITDIR"/*/*.conf 2>/dev/null \
        | tr ' ' '\n' | sed 's/^[A-Za-z]*=//' | grep -qx "$1"
}

for u in "${shipped[@]}"; do
    in_list "$u" "${preset[@]}" && continue
    stem="${u%.*}"
    if [[ "$u" == *.service ]] \
        && { in_list "$stem.path" "${preset[@]}" || in_list "$stem.timer" "${preset[@]}"; }; then
        continue
    fi
    pulled_in "$u" && continue
    [ -n "${UNMANAGED[$u]:-}" ] && continue
    bad "$u is shipped but never preset (and no .path/.timer or Wants= activates it). Add it to 90-hypr-de.preset, or to UNMANAGED here with a reason."
done

if [ -f "$TOML" ]; then
    deps=$(grep -oE '"[a-zA-Z0-9._+-]+(\s*[<>=]+\s*[^" ]+)?"' "$TOML" \
        | tr -d '"' | sed -E 's/\s*[<>=].*//' | sort -u)
    for u in "${preset[@]}"; do
        in_list "$u" "${shipped[@]}" && continue
        pkg="${UNIT_PKG[$u]:-${u%.*}}"
        printf '%s\n' "$deps" | grep -qx "$pkg" && continue
        bad "$u is preset but no shipped unit provides it and '$pkg' is not in deps.toml. Depend on the package, map it in UNIT_PKG, or drop the preset line."
    done
fi

for u in "${shipped[@]}"; do
    f="$UNITDIR/$u"
    grep -q '^WantedBy=graphical-session.target' "$f" 2>/dev/null || continue
    grep -q '^PartOf=graphical-session.target' "$f" 2>/dev/null && continue
    bad "$u is WantedBy=graphical-session.target but not PartOf= it, so it will not stop when the session ends."
done

if [ -f "$TOML" ]; then
    mapfile -t declared < <(python3 "$REPO/packaging/declared-units.py" "$TOML")
    for u in "${declared[@]}"; do
        [ -n "$u" ] || continue
        in_list "$u" "${preset[@]}" \
            || bad "$u is declared required in deps.toml but is not in 90-hypr-de.preset, so a fresh install never enables it."
        if [ -f "$SETUP" ] && ! grep -q "$u" "$SETUP"; then
            bad "$u is declared required in deps.toml but hypr-de-setup does not verify it."
        fi
    done
fi

for f in "$UNITDIR"/*.service "$UNITDIR"/*.conf "$UNITDIR"/*/*.conf; do
    [ -f "$f" ] || continue
    while IFS= read -r line; do
        case "$line" in
            *'command -v '*|*'which '*)
                bad "$(basename "$(dirname "$f")")/$(basename "$f"): resolves an executable through \$PATH ($line). Name an absolute path -- the user manager's PATH includes ~/.local/bin."
                continue
                ;;
        esac
        cmd=${line#*=}
        cmd=${cmd##[[:space:]]}
        while :; do
            case "$cmd" in
                [-+!:]*) cmd=${cmd#?} ;;
                *) break ;;
            esac
        done
        [ -z "$cmd" ] && continue
        case "$cmd" in
            /*|@[A-Z_]*@/*) ;;
            *) bad "$(basename "$f"): Exec line does not start with an absolute path ($line)" ;;
        esac
    done < <(grep -hE '^Exec(Start|Stop|StartPre|StartPost|StopPost|Reload)=' "$f" 2>/dev/null)
done

[ "$fail" = 0 ] && echo "units in sync (${#shipped[@]} shipped, ${#preset[@]} preset, ${#declared[@]} declared)"
exit "$fail"
