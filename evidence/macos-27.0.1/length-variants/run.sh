#!/bin/bash
# run.sh — re-test whether the ICNS chunk-length field still drives memory.
# Usage: evidence/macos-27.0.1/length-variants/run.sh [legitimate.icns]
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$HERE/../../.."
LEGIT="${1:-/System/Applications/Calendar.app/Contents/Resources/AppIcon.icns}"
WORK=$(mktemp -d -t icnsvariants)
PROBE="$WORK/vm_probe"

xcrun clang -arch arm64 -fobjc-arc -O0 \
  -framework Foundation -framework ImageIO -framework CoreGraphics \
  -framework CoreText -framework AVFoundation -framework CoreFoundation \
  "$ROOT/reproduce/vm_probe.m" -o "$PROBE"
python3 -I "$HERE/make_variants.py" "$ROOT/pocs/icns.icns" "$LEGIT" "$WORK/v"

echo "OS:      $(sw_vers -productName) $(sw_vers -productVersion) ($(sw_vers -buildVersion))"
echo "Model:   $(sysctl -n hw.model), $(sysctl -n machdep.cpu.brand_string)"
echo "Control: $(basename "$LEGIT") ($(stat -f%z "$LEGIT") bytes)"
echo ""
echo "variant                              images  resident delta"
echo "------------------------------------------------------------"
for f in "$WORK"/v/*.icns; do
  OUT=$("$PROBE" "$f" image 2>&1)
  IMGS=$(grep -c 'image=0x[1-9a-f]' <<<"$OUT")
  RES=$(grep -oE '^\[delta\].*resident=\+[0-9]+' <<<"$OUT" | grep -oE '[0-9]+$')
  printf "%-36s %6s  %8.2f MiB\n" "$(basename "$f" .icns)" "$IMGS" \
    "$(echo "${RES:-0} / 1048576" | bc -l)"
done

echo ""
echo "Quick Look (qlmanage, 12 s budget each)"
echo "------------------------------------------------------------"
mkdir -p /tmp/qlcheck
for n in P0_poc.icns P1_poc_ic13len_fits.icns L3_single_firstlen_BIG.icns \
         G1_patterned.icns G2_header_only.icns G3_broken.png; do
  cp "$WORK/v/$n" "/tmp/qlcheck/$n"
  R=$("$ROOT/reproduce/ql_wrap.sh" 12 "/tmp/qlcheck/$n")
  if grep -q HUNG <<<"$R"; then S="hung (killed after 12 s)"
  elif grep -q 'produced one thumbnail' <<<"$R"; then S="thumbnail produced"
  else S="completed, no thumbnail"; fi
  printf "%-36s %s\n" "$n" "$S"
done
rm -rf "$WORK"
