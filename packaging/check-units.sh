#!/bin/bash
# Service-activation completeness gate.
#
# hypr-DE ships user units, presets some of them, and presets units that belong
# to its dependencies. Nothing checked that those lists agree, and the failure
# mode is silent: logind-idle-control-tray.service shipped for months without
# ever being preset, so the idle inhibitor simply never appeared in the tray.
# Nothing errored; a feature was just quietly absent on every install.
#
# Build-time, offline checks:
#   1. every unit hypr-DE ships is preset, is a companion activated by a preset
#      .path/.timer, or is explicitly declared unmanaged with a reason
#   2. every unit preset but not shipped here comes from a package declared in
#      deps.toml (presetting a unit nothing installs makes setup warn forever)
#   3. every unit WantedBy=graphical-session.target is also PartOf= it, so it
#      stops with the session instead of lingering
#   4. every unit deps.toml declares as required is preset AND validated by
#      hypr-de-setup -- this is the rule that catches the tray-class bug, where
#      the unit comes from a dependency and rules 1-3 cannot see it
#   5. no Exec* line resolves its binary through $PATH -- the user manager's
#      PATH includes ~/.local/bin, so a PATH-resolved unit can be pointed at
#      an attacker-supplied binary by anything running in the session
#
# usage: check-units.sh [dist-dir]
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

# Units deliberately not preset, with the reason they are exempt.
declare -A UNMANAGED=(
    # (none today; add "unit.service"="why" here rather than silently skipping)
)
# Preset units from dependencies whose package name is not the unit stem.
declare -A UNIT_PKG=(
    ["obex.service"]="bluez-obex"
    ["logind-idle-control-tray.service"]="logind-idle-control"
)

declared=()
# Glob rather than ls|grep so odd filenames cannot confuse the listing (SC2010).
mapfile -t shipped < <(
    for f in "$UNITDIR"/*.service "$UNITDIR"/*.timer "$UNITDIR"/*.path "$UNITDIR"/*.socket; do
        [ -e "$f" ] && basename "$f"
    done | sort
)
mapfile -t preset  < <(grep -oE '^(enable|disable)[[:space:]]+\S+' "$PRESET" | awk '{print $2}' | sort -u)

in_list() { local n="$1"; shift; local x; for x in "$@"; do [ "$x" = "$n" ] && return 0; done; return 1; }

# --- 1. shipped units must be activated somehow -----------------------------
for u in "${shipped[@]}"; do
    in_list "$u" "${preset[@]}" && continue
    stem="${u%.*}"
    if [[ "$u" == *.service ]] \
        && { in_list "$stem.path" "${preset[@]}" || in_list "$stem.timer" "${preset[@]}"; }; then
        continue
    fi
    [ -n "${UNMANAGED[$u]:-}" ] && continue
    bad "$u is shipped but never preset (and no .path/.timer activates it). Add it to 90-hypr-de.preset, or to UNMANAGED here with a reason."
done

# --- 2. presetting a unit we do not install ---------------------------------
if [ -f "$TOML" ]; then
    # A dep may carry a version floor ("hypridle >= 0.1.8"); match on the name.
    deps=$(grep -oE '"[a-zA-Z0-9._+-]+( ?[<>=]+ ?[0-9][0-9.]*)?"' "$TOML" \
        | tr -d '"' | sed -E 's/ ?[<>=].*//' | sort -u)
    for u in "${preset[@]}"; do
        in_list "$u" "${shipped[@]}" && continue
        pkg="${UNIT_PKG[$u]:-${u%.*}}"
        printf '%s\n' "$deps" | grep -qx "$pkg" && continue
        bad "$u is preset but no shipped unit provides it and '$pkg' is not in deps.toml. Depend on the package, map it in UNIT_PKG, or drop the preset line."
    done
fi

# --- 3. graphical-session binding -------------------------------------------
for u in "${shipped[@]}"; do
    f="$UNITDIR/$u"
    grep -q '^WantedBy=graphical-session.target' "$f" 2>/dev/null || continue
    grep -q '^PartOf=graphical-session.target' "$f" 2>/dev/null && continue
    bad "$u is WantedBy=graphical-session.target but not PartOf= it, so it will not stop when the session ends."
done

# --- 4. units a dependency must contribute ----------------------------------
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

# --- 5. no Exec* resolved through $PATH -------------------------------------
# `ExecStart=/bin/sh -c 'exec "$(command -v hypridle)" ...'` let anything in
# the session shadow hypridle from ~/.local/bin and silently disable
# auto-lock, with the unit still reporting active. Every executable a unit
# names must be an absolute path in a root-owned location.
for f in "$UNITDIR"/*.service "$UNITDIR"/*.conf "$UNITDIR"/*/*.conf; do
    [ -f "$f" ] || continue
    while IFS= read -r line; do
        case "$line" in
            *'command -v '*|*'which '*)
                bad "$(basename "$(dirname "$f")")/$(basename "$f"): resolves an executable through \$PATH ($line). Name an absolute path -- the user manager's PATH includes ~/.local/bin."
                continue
                ;;
        esac
        # Strip the Exec*= key and any +/-/!/: prefixes, then require /.
        cmd=${line#*=}
        cmd=${cmd##[[:space:]]}
        while :; do
            case "$cmd" in
                [-+!:]*) cmd=${cmd#?} ;;
                *) break ;;
            esac
        done
        [ -z "$cmd" ] && continue          # ExecStart= reset line
        # @TOKENS@ expand to absolute paths from packaging/paths.conf, and CI
        # already rejects literal install paths in dist/.
        case "$cmd" in
            /*|@[A-Z_]*@/*) ;;
            *) bad "$(basename "$f"): Exec line does not start with an absolute path ($line)" ;;
        esac
    done < <(grep -hE '^Exec(Start|Stop|StartPre|StartPost|StopPost|Reload)=' "$f" 2>/dev/null)
done

[ "$fail" = 0 ] && echo "units in sync (${#shipped[@]} shipped, ${#preset[@]} preset, ${#declared[@]} declared)"
exit "$fail"
