#!/bin/bash
# What the session reveals to someone at a locked machine, and what it will
# run as root on a single click. See issue #18.
set -uo pipefail
root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
fail=0
ok()  { printf 'ok   %s\n' "$*"; }
bad() { printf 'FAIL %s\n' "$*"; fail=1; }

echo "== the activation environment is enumerated, not wholesale"
lua="$root/dist/hypr/main.lua"
grep -q 'dbus-update-activation-environment --all' "$lua" \
    && bad "--all pushes the whole session environment into every activated service" \
    || ok "no --all"
grep -q 'dbus-update-activation-environment --systemd .*HYPRLAND_INSTANCE_SIGNATURE' "$lua" \
    && ok "the enumerated set still carries HYPRLAND_INSTANCE_SIGNATURE" \
    || bad "activated services (xdph) need HYPRLAND_INSTANCE_SIGNATURE"

echo
echo "== a locked screen does not announce what is playing"
stub="$work/stub"; mkdir -p "$stub"
cat > "$stub/playerctl" <<'P'
#!/bin/sh
case "$*" in
    *status*)          echo Playing ;;
    *"metadata title"*) echo "Some Confidential Demo" ;;
    *"metadata artist"*) echo "A Band" ;;
esac
exit 0
P
cat > "$stub/notify-send" <<'N'
#!/bin/sh
printf 'notify %s\n' "$*" >> "$NOTIFY_LOG"
N
cat > "$stub/session-locked.sh" <<'L'
#!/bin/sh
[ "${FAKE_LOCKED:-0}" = 1 ]
L
chmod +x "$stub"/*
osd="$work/media-osd.sh"
sed "s|@LIBEXECDIR@|$stub|g" "$root/dist/libexec/osd/media-osd.sh" > "$osd"; chmod +x "$osd"
export NOTIFY_LOG="$work/notify.log"

: > "$NOTIFY_LOG"
FAKE_LOCKED=1 PATH="$stub:$PATH" bash "$osd" next
if grep -q "Some Confidential Demo" "$NOTIFY_LOG"; then
    cat "$NOTIFY_LOG"
    bad "the track title was announced over a locked screen"
else
    ok "locked: no title or artist in the notification"
fi
grep -q "Next" "$NOTIFY_LOG" && ok "locked: the control still works and still confirms" || bad "locked: no feedback at all"

: > "$NOTIFY_LOG"
FAKE_LOCKED=0 PATH="$stub:$PATH" bash "$osd" previous
grep -q "Some Confidential Demo" "$NOTIFY_LOG" \
    && ok "unlocked: metadata is still shown" \
    || { cat "$NOTIFY_LOG"; bad "unlocked: metadata should still be shown"; }

echo
echo "== the update click cannot be pointed at an arbitrary program"
# shellcheck disable=SC1090
source <(sed -n '/^resolve_terminal()/,/^}/p' "$root/dist/libexec/waybar-updates-check")
if ! declare -F resolve_terminal >/dev/null; then
    bad "there is no resolve_terminal: \$TERMINAL is used as-is"
    resolve_terminal() { printf '%s' "${TERMINAL:-kitty}"; }   # so the cases below still mean something
fi
shadow="$work/shadowbin"; mkdir -p "$shadow"
printf '#!/bin/sh\necho pwned\n' > "$shadow/kitty"; chmod +x "$shadow/kitty"
got=$(PATH="$shadow:$PATH" TERMINAL=kitty resolve_terminal)
case "$got" in
    /usr/bin/*|/usr/local/bin/*|/bin/*) ok "a PATH shadow is ignored: $got" ;;
    "") echo "   (no terminal installed here; skipping)" ;;
    *)  bad "resolved outside a root-owned directory: $got" ;;
esac
got=$(TERMINAL="$shadow/kitty" resolve_terminal)
case "$got" in
    "$shadow"*) bad "an absolute \$TERMINAL was honoured: $got" ;;
    *)          ok "an absolute \$TERMINAL is not honoured" ;;
esac
grep -q 'This will ask for your password' "$root/dist/libexec/waybar-updates-check" \
    && ok "the command is shown before the password prompt" \
    || bad "a click goes straight to a root password prompt"

echo
echo "== the power menu is named for what it does"
pm="$root/dist/libexec/power-menu.sh"
if grep -q "Suspend)" "$pm" && grep -q 'Suspend).*lock-session' "$pm"; then
    bad "a menu entry called Suspend only locks the session"
else
    ok "no entry promises a suspend it does not perform"
fi
grep -q "Lock)" "$pm" && ok "the lock entry exists" || bad "the lock action disappeared"

echo
echo "== the reload helper only talks to sockets the uid owns"
helper="$work/reload"
fixture="$work/run"; mkdir -p "$fixture/1000/hypr/sig"
# Both the glob and the prefix it strips, or the uid parse silently yields
# nothing and every case below passes for the wrong reason.
sed -e "s|/run/user/\*|$fixture/*|" -e "s|\${sock#/run/user/}|\${sock#$fixture/}|" \
    "$root/dist/libexec/hypr-de-reload-sessions" > "$helper"
chmod +x "$helper"
python3 -c "
import socket, sys
s = socket.socket(socket.AF_UNIX); s.bind('$fixture/1000/hypr/sig/.socket.sock')
"
rbin="$work/rbin"; mkdir -p "$rbin"
printf '#!/bin/sh\necho \"%s\" > \"$STAT_OUT\"\nexit 0\n' "runuser-called" > "$rbin/runuser"
printf '#!/bin/sh\nexit 0\n' > "$rbin/pgrep"
printf '#!/bin/sh\necho notmyuser\n' > "$rbin/id"
# stat reports an owner that is NOT the uid in the path
printf '#!/bin/sh\necho 4242\n' > "$rbin/stat"
chmod +x "$rbin"/*
export STAT_OUT="$work/runuser.out"; : > "$STAT_OUT"
PATH="$rbin:$PATH" bash "$helper" >/dev/null 2>&1
if [ -s "$STAT_OUT" ]; then
    bad "ran as a user for a socket that uid does not own"
else
    ok "a socket owned by someone else is skipped"
fi
grep -q 'stat -c %u' "$root/dist/libexec/hypr-de-reload-sessions" \
    && ok "ownership is checked before acting" || bad "no ownership check"

echo
[ "$fail" -eq 0 ] && { echo "privacy and privilege boundaries hold"; exit 0; }
exit 1
