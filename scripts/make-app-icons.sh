#!/bin/bash
##########################################################
# Ionix Link app icons, rendered from the Ionix logo SVG #
##########################################################
#
# Writes the Android launcher icons (legacy and adaptive) and the splash logo into
# app/android/app/src/main/res from assets/ionix-logo.svg, the same mark the
# distribution ships as /usr/share/ionix/ionix-logo.svg. Run it again after the logo
# changes; the PNGs it writes are committed, because Gradle cannot render SVG.
# The monochrome and notification icons are vector drawables written by hand from
# the same path data (res/drawable/ic_launcher_monochrome.xml, ic_stat_ionix.xml).
#
# Needs rsvg-convert (librsvg).

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOGO="$ROOT/assets/ionix-logo.svg"
RES="$ROOT/app/android/app/src/main/res"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# Ionix palette: deepest background and window background.
BG_DEEP="#0f0a18"
BG_GLOW="#2a1846"

# Density name and its scale against mdpi.
DENSITIES=("mdpi 1" "hdpi 1.5" "xhdpi 2" "xxhdpi 3" "xxxhdpi 4")

# The logo's own geometry (path data only, no <svg> wrapper), reused in every composition.
logo_body() {
  sed -n '/<defs>/,/<\/svg>/p' "$LOGO" | sed '$d'
}

# Writes an SVG of SIZE x SIZE units with the logo scaled so its diamond (456 of 512 units tall)
# is HEIGHT units tall, centred, over BACKGROUND ("none", or the glow background).
compose() {
  local SIZE="$1" HEIGHT="$2" BACKGROUND="$3" OUT="$4"
  local SCALE
  SCALE="$(awk -v h="$HEIGHT" 'BEGIN { printf "%.6f", h / 456 }')"
  {
    printf '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 %s %s" width="%s" height="%s">\n' "$SIZE" "$SIZE" "$SIZE" "$SIZE"
    if [[ "$BACKGROUND" == "glow" ]]; then
      printf '<defs><radialGradient id="bgGlow" cx="50%%" cy="42%%" r="70%%"><stop offset="0" stop-color="%s"/><stop offset="1" stop-color="%s"/></radialGradient></defs>\n' "$BG_GLOW" "$BG_DEEP"
      printf '<rect width="%s" height="%s" fill="url(#bgGlow)"/>\n' "$SIZE" "$SIZE"
    fi
    printf '<g transform="translate(%s %s) scale(%s) translate(-256 -256)">\n' "$(awk -v s="$SIZE" 'BEGIN { print s / 2 }')" "$(awk -v s="$SIZE" 'BEGIN { print s / 2 }')" "$SCALE"
    logo_body
    printf '</g>\n</svg>\n'
  } > "$OUT"
}

# Same, but the background is a rounded square, for launchers without adaptive icons (Android 7 and older).
compose_legacy() {
  local OUT="$1"
  {
    printf '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 48 48" width="48" height="48">\n'
    printf '<defs><radialGradient id="bgGlow" cx="50%%" cy="42%%" r="70%%"><stop offset="0" stop-color="%s"/><stop offset="1" stop-color="%s"/></radialGradient></defs>\n' "$BG_GLOW" "$BG_DEEP"
    printf '<rect x="2" y="2" width="44" height="44" rx="10" fill="url(#bgGlow)"/>\n'
    printf '<g transform="translate(24 24) scale(%s) translate(-256 -256)">\n' "$(awk 'BEGIN { printf "%.6f", 34 / 456 }')"
    logo_body
    printf '</g>\n</svg>\n'
  } > "$OUT"
}

# Renders SVG to a PNG of PX x PX pixels.
render() {
  rsvg-convert -w "$2" -h "$2" -o "$3" "$1"
}

command -v rsvg-convert > /dev/null || { echo "rsvg-convert not found. Install librsvg." >&2; exit 1; }

# Adaptive icon: a 108dp canvas of which the launcher mask shows at least the middle 66dp,
# so the diamond is kept to 64dp tall. Legacy icon: 48dp with its own rounded square.
# Splash (Android 12+): the icon area is 288dp of which the middle 192dp is shown.
compose 108 64 none "$WORK/foreground.svg"
compose 108 0 glow "$WORK/background.svg"
compose_legacy "$WORK/legacy.svg"
compose 288 150 none "$WORK/splash.svg"

for entry in "${DENSITIES[@]}"; do
  read -r NAME SCALE <<< "$entry"
  DIR="$RES/mipmap-$NAME"
  mkdir -p "$DIR" "$RES/drawable-$NAME"
  render "$WORK/legacy.svg" "$(awk -v s="$SCALE" 'BEGIN { print int(48 * s) }')" "$DIR/ic_launcher.png"
  render "$WORK/foreground.svg" "$(awk -v s="$SCALE" 'BEGIN { print int(108 * s) }')" "$DIR/ic_launcher_foreground.png"
  render "$WORK/background.svg" "$(awk -v s="$SCALE" 'BEGIN { print int(108 * s) }')" "$DIR/ic_launcher_background.png"
  render "$WORK/splash.svg" "$(awk -v s="$SCALE" 'BEGIN { print int(288 * s) }')" "$RES/drawable-$NAME/splash_logo.png"
done

echo "Done! Wrote launcher icons and splash logo to $RES"
