#!/usr/bin/env bash

set -u

: "${XDG_RUNTIME_DIR:?XDG_RUNTIME_DIR is unset; refusing to keep notification context in /tmp}"
CTX_DIR="$XDG_RUNTIME_DIR/swaync-context"
APPS_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/hypr-de/notify-plugins"

[ -n "${SWAYNC_ID:-}" ] || exit 0
mkdir -p "$CTX_DIR"

candidates() {
    local raw
    for raw in "${SWAYNC_DESKTOP_ENTRY:-}" "${SWAYNC_APP_NAME:-}"; do
        [ -z "$raw" ] && continue
        local lower=${raw,,}
        lower=${lower%.desktop}
        printf '%s\n' "$lower" "${lower##*.}"
    done | awk '!seen[$0]++'
}

ctx_file="$CTX_DIR/$SWAYNC_ID.env"
{
    printf '%s=%q\n' \
        APP_NAME "${SWAYNC_APP_NAME:-}" \
        DESKTOP_ENTRY "${SWAYNC_DESKTOP_ENTRY:-}" \
        SUMMARY "${SWAYNC_SUMMARY:-}" \
        TIME "${SWAYNC_TIME:-}" \
        URGENCY "${SWAYNC_URGENCY:-}"

    while IFS= read -r name; do
        plugin="$APPS_DIR/$name.sh"
        if [ -f "$plugin" ]; then
            # shellcheck source=/dev/null
            . "$plugin"
            if declare -f enrich > /dev/null; then
                enrich || true
            fi
            break
        fi
    done < <(candidates)
} > "$ctx_file"

find "$CTX_DIR" -name '*.env' -mmin +10080 -delete 2>/dev/null

exit 0
