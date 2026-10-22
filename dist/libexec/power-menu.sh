#!/bin/bash
# Logout, reboot and shutdown go through one exit command. desktop-boot-exit
# (the desktop-boot project, optional) covers every screen with the boot
# splash scene while windows close; without it, hyprshutdown's own dialog.
# Both take -p COMMAND, run once the apps are gone.
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
    # This entry locks. hyprstate 2.6.0 does expose `hyprstate suspend
    # request`, but that verb feeds the idle/lid countdown -- a 30 s grace
    # window with lock verification -- not an immediate suspend, and a menu
    # entry named Suspend that acts half a minute later quietly means
    # something else. Naming it for what it does beats that. (A real Suspend
    # entry would be one line: `Suspend) hyprstate suspend request ;;`.)
    Lock)     loginctl lock-session ;;
esac
