#!/bin/bash
# Media keys stay live on the lock screen (main.lua binds them locked = true),
# so these notifications can be raised over a locked session. Track title and
# artist are not shown there: the point of a lock screen is that someone at
# the machine learns nothing about the session. Controls still work; only the
# metadata is withheld.
#
# "Is the session locked" has one owner -- the compositor lock, via
# session-locked.sh -- rather than a second opinion here.
locked() { "@LIBEXECDIR@/session-locked.sh" 2>/dev/null; }

case $1 in
    "play-pause")
        playerctl play-pause
        sleep 0.1  # Brief delay to allow state change
        status=$(playerctl status 2>/dev/null)
        if [[ $status == "Playing" ]]; then
            notify-send -t 2000 -a "osd-media" -h string:x-canonical-private-synchronous:media "▶️ Playing" ""
        elif [[ $status == "Paused" ]]; then
            notify-send -t 2000 -a "osd-media" -h string:x-canonical-private-synchronous:media "⏸️ Paused" ""
        elif [[ $status == "Stopped" ]]; then
            notify-send -t 2000 -a "osd-media" -h string:x-canonical-private-synchronous:media "⏹️ Stopped" ""
        else
            notify-send -t 2000 -a "osd-media" -h string:x-canonical-private-synchronous:media "🎵 Media" "Toggle"
        fi
        ;;
    "stop")
        playerctl stop
        notify-send -t 2000 -a "osd-media" -h string:x-canonical-private-synchronous:media "⏹️ Stopped" ""
        ;;
    "next")
        playerctl next
        sleep 0.1
        title=$(playerctl metadata title 2>/dev/null)
        artist=$(playerctl metadata artist 2>/dev/null)
        if [[ -n "$title" ]] && ! locked; then
            notify-send -t 3000 -a "osd-media" -h string:x-canonical-private-synchronous:media "⏭️ Next Track" "$artist - $title"
        else
            notify-send -t 2000 -a "osd-media" -h string:x-canonical-private-synchronous:media "⏭️ Next" ""
        fi
        ;;
    "previous")
        playerctl previous
        sleep 0.1
        title=$(playerctl metadata title 2>/dev/null)
        artist=$(playerctl metadata artist 2>/dev/null)
        if [[ -n "$title" ]] && ! locked; then
            notify-send -t 3000 -a "osd-media" -h string:x-canonical-private-synchronous:media "⏮️ Previous Track" "$artist - $title"
        else
            notify-send -t 2000 -a "osd-media" -h string:x-canonical-private-synchronous:media "⏮️ Previous" ""
        fi
        ;;
esac