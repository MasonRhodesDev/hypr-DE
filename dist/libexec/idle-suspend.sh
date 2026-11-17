#!/bin/bash
PATH=/usr/local/bin:/usr/bin:/bin; export PATH
command -v hyprstate >/dev/null 2>&1 || exit 0
case "${1:-}" in
    --cancel) exec hyprstate suspend cancel ;;
    *)        exec hyprstate suspend request ;;
esac
