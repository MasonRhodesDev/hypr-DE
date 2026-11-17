#!/bin/bash
if command -v desktop-boot-exit >/dev/null 2>&1; then
    exit_cmd=desktop-boot-exit
else
    exit_cmd=hyprshutdown
fi

selection=$(printf 'Logout\nReboot\nShutdown\nLock' | fuzzel --dmenu --prompt 'Power: ')

case "$selection" in
    Logout)   "$exit_cmd" ;;
    Reboot)   "$exit_cmd" -p 'systemctl reboot' ;;
    Shutdown) "$exit_cmd" -p 'systemctl poweroff -i' ;;
    Lock)     loginctl lock-session ;;
esac
