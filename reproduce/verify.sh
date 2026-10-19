#!/bin/bash
# verify.sh — one-shot reproduction.
# Forces arm64 execution context; reports binary architectures explicitly;
# always completes all measurement sections.
set -uo pipefail

# Re-exec under arm64 if not already (resilient to x86_64 brew Rosetta shells)
if [[ "$(uname -m)" != "arm64" ]]; then
  if /usr/bin/arch -arm64 true 2>/dev/null; then
    exec /usr/bin/arch -arm64 /bin/bash "$0" "$@"
  fi
fi

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$HERE/.."
PROBE="$HERE/vm_probe"
POC_ICNS="$ROOT/pocs/icns.icns"

# Find a SMALL legitimate ICNS control file for fair comparison
CONTROL_ICNS=""
for try in /System/Applications/Calendar.app/Contents/Resources/AppIcon.icns \
           /System/Applications/Tips.app/Contents/Resources/AppIcon.icns \
           /Applications/Xcode.app/Contents/Resources/Xcode.icns; do
  [[ -f "$try" ]] && CONTROL_ICNS="$try" && break
done
[[ -z "$CONTROL_ICNS" ]] && CONTROL_ICNS=$(find /System/Applications -name '*.icns' -size +5k -size -50k 2>/dev/null | head -1)

echo "================================================================"
echo "  Verification report"
echo "================================================================"
echo "Date:        $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
echo "Host model:  $(sysctl -n hw.model)"
echo "Hardware:    $(sysctl -n machdep.cpu.brand_string), $(sysctl -n hw.memsize | awk '{printf "%d GiB RAM", $1/1024/1024/1024}')"
echo "Kernel arch: $(sysctl -n kern.osversion) - $(sysctl -n hw.machine)"
echo "OS:          $(sw_vers -productName) $(sw_vers -productVersion) ($(sw_vers -buildVersion))"
echo "Shell arch:  $(arch) (uname -m: $(uname -m))"
echo ""

# Compile a tiny tool to PROVE process arch at runtime
TMPC=$(mktemp -t archck).c
cat > "$TMPC" <<'EOF'
#include <stdio.h>
#include <sys/sysctl.h>
int main(){
    int translated = 0; size_t sz = sizeof(translated);
    sysctlbyname("sysctl.proc_translated", &translated, &sz, NULL, 0);
    printf("__aarch64__ = "
#ifdef __aarch64__
"yes (compiled for arm64)\n"
#else
"no (compiled for %s)\n", sizeof(void*)==8 ? "x86_64" : "?"
#endif
);
    printf("sysctl.proc_translated = %d (0=native, 1=Rosetta)\n", translated);
    return 0;
}
EOF
ARCHCK=$(mktemp -t archck)
xcrun clang -arch arm64 "$TMPC" -o "$ARCHCK" 2>/dev/null

# Rebuild vm_probe from source on each run so the reviewer is not relying
# on an arbitrary prebuilt binary. The build is fast (sub-second).
echo "(building vm_probe from source: $HERE/vm_probe.m -> $PROBE)"
xcrun clang -arch arm64 -fobjc-arc -O0 -g \
  -framework Foundation -framework ImageIO -framework CoreGraphics \
  -framework CoreText -framework AVFoundation -framework CoreFoundation \
  "$HERE/vm_probe.m" -o "$PROBE"
file "$PROBE"

echo "================================================================"
echo "  Binary architecture verification"
echo "================================================================"
echo ""
echo "vm_probe (the measurement tool):"
file "$PROBE"
echo "  on-the-fly arch check when executed:"
"$ARCHCK" | sed 's/^/    /'
echo ""

echo "================================================================"
echo "  PoC integrity"
echo "================================================================"
shasum -a 256 "$POC_ICNS"
echo ""
echo "Expected from SHA256SUMS.txt:"
cat "$ROOT/pocs/SHA256SUMS.txt"
echo ""

run() {
  local label="$1"; local file="$2"
  echo "----------------------------------------------------------------"
  echo "  $label"
  echo "  file:   $(basename "$file")"
  echo "  size:   $(stat -f%z "$file") bytes"
  echo "----------------------------------------------------------------"
  "$PROBE" "$file" image
  echo ""
}

echo "================================================================"
echo "  Method #1 — task_info(TASK_VM_INFO)"
echo "  Three back-to-back runs each."
echo "================================================================"
run "Run 1/3 — ICNS PoC" "$POC_ICNS"
run "Run 2/3 — ICNS PoC" "$POC_ICNS"
run "Run 3/3 — ICNS PoC" "$POC_ICNS"

echo "================================================================"
echo "  Method #1 control — legitimate files for fair comparison"
echo "================================================================"
if [[ -f "${CONTROL_ICNS:-}" ]]; then
  run "Control: legitimate ICNS" "$CONTROL_ICNS"
fi

echo "================================================================"
echo "  Method #2 — /usr/bin/time -l peak memory footprint"
echo "  (independent measurement using getrusage)"
echo "================================================================"
NAKED=$(mktemp -t naked).bin
SRC=$(mktemp -t naked).m
cat > "$SRC" <<'EOF'
#import <Foundation/Foundation.h>
#import <ImageIO/ImageIO.h>
#import <CoreGraphics/CoreGraphics.h>
int main(int argc, char *argv[]) {
    NSData *d = [NSData dataWithContentsOfFile:@(argv[1])];
    NSDictionary *o = @{
        (id)kCGImageSourceShouldCache: @YES,
        (id)kCGImageSourceCreateThumbnailFromImageAlways: @YES,
        (id)kCGImageSourceShouldCacheImmediately: @YES,
        (id)kCGImageSourceThumbnailMaxPixelSize: @256,
    };
    CGImageSourceRef s = CGImageSourceCreateWithData((__bridge CFDataRef)d,
                                                     (__bridge CFDictionaryRef)o);
    if (!s) return 0;
    CFDictionaryRef p = CGImageSourceCopyProperties(s, NULL);
    if (p) CFRelease(p);
    size_t n = CGImageSourceGetCount(s);
    for (size_t i = 0; i < n && i < 4; i++) {
        CGImageRef img = CGImageSourceCreateImageAtIndex(s, i, (__bridge CFDictionaryRef)o);
        if (img) CGImageRelease(img);
    }
    CFRelease(s);
    return 0;
}
EOF
xcrun clang -arch arm64 -fobjc-arc \
  -framework Foundation -framework ImageIO -framework CoreGraphics \
  -framework CoreFoundation "$SRC" -o "$NAKED"
echo "naked reproducer binary: $(file "$NAKED" | cut -d: -f2-)"
echo ""
echo "▼ ICNS PoC ▼"
/usr/bin/time -l "$NAKED" "$POC_ICNS" 2>&1 | tail -22
echo ""
if [[ -f "${CONTROL_ICNS:-}" ]]; then
  echo "▼ Control (legitimate ICNS) ▼"
  /usr/bin/time -l "$NAKED" "$CONTROL_ICNS" 2>&1 | tail -22
fi
rm -f "$NAKED" "$SRC" "$TMPC" "$ARCHCK"

echo ""
echo "================================================================"
echo "  Method #3 — qlmanage (Quick Look thumbnailer)"
echo "  Each invocation is bounded to 20 seconds so a hung qlmanage"
echo "  cannot stall the run."
echo "================================================================"
mkdir -p /tmp/qlcheck && rm -f /tmp/qlcheck/*

echo ""
echo "▼ qlmanage thumbnailing the ICNS PoC (20s budget) ▼"
cp "$POC_ICNS" /tmp/qlcheck/icns_poc.icns
"$HERE"/ql_wrap.sh 20 /tmp/qlcheck/icns_poc.icns

if [[ -f "${CONTROL_ICNS:-}" ]]; then
  echo ""
  echo "▼ qlmanage thumbnailing the Control ICNS (20s budget) ▼"
  cp "$CONTROL_ICNS" /tmp/qlcheck/control.icns
  "$HERE"/ql_wrap.sh 20 /tmp/qlcheck/control.icns
fi
echo ""
echo "================================================================"
echo "  Verification complete."
echo "================================================================"
