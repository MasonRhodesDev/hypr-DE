#!/usr/bin/env bash

set -u

APPS_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/hypr-de/notify-plugins"
: "${XDG_RUNTIME_DIR:?XDG_RUNTIME_DIR is unset; refusing to keep notification context in /tmp}"
CTX_DIR="$XDG_RUNTIME_DIR/swaync-context"

needle_raw="${SWAYNC_DESKTOP_ENTRY:-${SWAYNC_APP_NAME:-}}"
[ -z "$needle_raw" ] && exit 0

needle=$(printf '%s' "$needle_raw" \
    | tr '[:upper:]' '[:lower:]' \
    | sed -E 's/\.desktop$//; s/[[:space:]]+desktop$//; s/^[[:space:]]+|[[:space:]]+$//g')

[ -z "$needle" ] && exit 0

needle=$(printf '%s' "$needle" | tr -cd 'a-z0-9._-')
case "$needle" in
    ""|.|..|*..*) exit 0 ;;
esac

run_plugin() {
    local name plugin
    for name in "$needle" "${needle##*.}"; do
        plugin="$APPS_DIR/$name.sh"
        if [ -f "$plugin" ]; then
            # shellcheck source=/dev/null
            . "$plugin"
            if declare -f on_action > /dev/null; then
                local ctx="$CTX_DIR/${SWAYNC_ID:-none}.env"
                if [ -f "$ctx" ]; then
                    # shellcheck source=/dev/null
                    . "$ctx"
                fi
                on_action "$ctx"
            fi
            return
        fi
    done
}
run_plugin &

clients_json=$(hyprctl clients -j 2>/dev/null)
address="" workspace=""
for n in "$needle" "${needle##*.}"; do
    read -r address workspace < <(
        jq -r --arg n "$n" '
            [ .[] | select(
                  (.class        // "" | ascii_downcase | contains($n)) or
                  (.initialClass // "" | ascii_downcase | contains($n)) or
                  (.initialTitle // "" | ascii_downcase | contains($n))
            ) ] | .[0] | if . then "\(.address) \(.workspace.name)" else "" end
        ' <<< "$clients_json"
    )
    [ -n "${address:-}" ] && break
done

if [ -n "${address:-}" ]; then
    lua_str() { printf '"%s"' "$(printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g')"; }
    dispatch_toggle_special() { hyprctl dispatch "hl.dsp.workspace.toggle_special($(lua_str "$1"))" >/dev/null; }
    dispatch_focus_window()   { hyprctl dispatch "hl.dsp.focus({ window = $(lua_str "address:$1") })" >/dev/null; }

    if [[ "$workspace" == special:* ]]; then
        special_name="${workspace#special:}"
        active_special=$(hyprctl -j monitors | jq -r '.[] | select(.focused) | .specialWorkspace.name')
        if [ "$active_special" != "$workspace" ]; then
            dispatch_toggle_special "$special_name"
        fi
    fi

    dispatch_focus_window "$address"
fi

wait
