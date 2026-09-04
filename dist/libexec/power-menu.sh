#!/bin/bash
selection=$(printf 'Logout\nReboot\nShutdown\nLock' | fuzzel --dmenu --prompt 'Power: ')

case "$selection" in
    Logout)   hyprshutdown ;;
    Reboot)   hyprshutdown -p 'systemctl reboot' ;;
    Shutdown) hyprshutdown -p 'systemctl poweroff -i' ;;
    # This entry locks. hyprstate 2.6.0 does expose `hyprstate suspend
    # request`, but that verb feeds the idle/lid countdown -- a 30 s grace
    # window with lock verification -- not an immediate suspend, and a menu
    # entry named Suspend that acts half a minute later quietly means
    # something else. Naming it for what it does beats that. (A real Suspend
    # entry would be one line: `Suspend) hyprstate suspend request ;;`.)
    Lock)     loginctl lock-session ;;
esac
