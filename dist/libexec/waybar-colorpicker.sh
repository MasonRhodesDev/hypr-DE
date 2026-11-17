#!/usr/bin/env bash
check() {
  command -v "$1" 1>/dev/null
}



loc="$HOME/.cache/colorpicker"
[ -d "$loc" ] || mkdir -p "$loc"
[ -f "$loc/colors" ] || touch "$loc/colors"

limit=10

[[ $# -eq 1 && $1 = "-l" ]] && {
  cat "$loc/colors"
  exit
}

pango_escape() { printf '%s' "$1" | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g'; }
is_color()     { printf '%s' "$1" | grep -qE '^#[0-9A-Fa-f]{3,8}$'; }

emit_json() {
  jq -cn --arg text "$1" --arg tooltip "$2" '{text: $text, tooltip: $tooltip}'
}

[[ $# -eq 1 && $1 = "-j" ]] && {
  text="$(head -n 1 "$loc/colors")"

  if [[ -z "$text" ]] || ! is_color "$text"; then
    emit_json "󰉦" $'<b>   COLORS</b>\n\nNo colors picked yet'
    exit
  fi

  mapfile -t allcolors < <(tail -n +2 "$loc/colors")
  tooltip=$'<b>   COLORS</b>\n\n'
  tooltip+="-> <b>$(pango_escape "$text")</b>  <span color='$text'></span>  "
  tooltip+=$'\n'
  for i in "${allcolors[@]}"; do
    is_color "$i" || continue
    tooltip+="   <b>$(pango_escape "$i")</b>  <span color='$i'></span>  "
    tooltip+=$'\n'
  done

  emit_json "<span color='$text'></span>" "$tooltip"
  exit
}

check hyprpicker || {
  notify "hyprpicker is not installed"
  exit
}
killall -q hyprpicker
color=$(hyprpicker)

check wl-copy && {
  echo "$color" | sed -z 's/\n//g' | wl-copy
}

prevColors=$(head -n $((limit - 1)) "$loc/colors")
echo "$color" >"$loc/colors"
echo "$prevColors" >>"$loc/colors"
sed -i '/^$/d' "$loc/colors"
notify-send "Color Picker" "This color has been selected: $color"
pkill -RTMIN+1 waybar
