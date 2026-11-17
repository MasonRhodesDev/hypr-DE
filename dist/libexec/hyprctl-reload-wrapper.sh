#!/bin/bash

/usr/bin/hyprctl reload "$@"
exit_code=$?

if [ $exit_code -eq 0 ]; then
    (sleep 1 && systemctl --user restart waybar) &
fi

exit $exit_code
