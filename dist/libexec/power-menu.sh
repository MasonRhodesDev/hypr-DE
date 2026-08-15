#!/bin/bash
selection=$(printf 'Logout\nReboot\nShutdown\nSuspend' | fuzzel --dmenu --prompt 'Power: ')

case "$selection" in
    Logout)   hyprshutdown ;;
    Reboot)   hyprshutdown -p 'systemctl reboot' ;;
    Shutdown) hyprshutdown -p 'systemctl poweroff -i' ;;
    # hyprstate owns suspend (lid FSM + lock-before-suspend) and has no
    # suspend/lock CLI. loginctl lock-session is the session lock path;
    # do not call systemctl suspend — that bypasses hyprstate's writer.
    Suspend)  loginctl lock-session ;;
esac
