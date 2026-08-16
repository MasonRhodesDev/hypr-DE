#!/bin/sh
# hypridle lock_cmd. --daemonize returns 0 only after ext-session-lock is
# granted. Then force DPMS on so a lock against dark outputs still has CRTCs.
set -e
vigil-lock --daemonize
exec hyprctl dispatch "hl.dsp.dpms({ action = 'on' })"
