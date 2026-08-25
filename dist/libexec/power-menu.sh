#!/bin/bash
selection=$(printf 'Logout\nReboot\nShutdown\nLock' | fuzzel --dmenu --prompt 'Power: ')

case "$selection" in
    Logout)   hyprshutdown ;;
    Reboot)   hyprshutdown -p 'systemctl reboot' ;;
    Shutdown) hyprshutdown -p 'systemctl poweroff -i' ;;
    # This entry locks. It was labelled "Suspend", but locking is all it
    # does: hyprstate owns suspend (lid FSM + lock-before-suspend) and
    # exposes no CLI or D-Bus method to request one, and calling systemctl
    # suspend here would bypass its writer. Naming it for what it does beats
    # a menu entry that quietly means something else.
    Lock)     loginctl lock-session ;;
esac
