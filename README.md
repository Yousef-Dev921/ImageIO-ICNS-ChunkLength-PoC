# ImageIO ICNS chunk-length memory exhaustion — PoC and write-up

A reproducible memory-exhaustion defect in the ICNS reader path of
`ImageIO.framework` on **macOS 26.5 (build 25F71)** running on Apple
Silicon. A **796-byte** ICNS file drives the decoder to commit about
**2.37 GiB** of resident physical memory. This no longer
reproduces on macOS 27.0.1 (build 26A434); see the status section
below.

On macOS 26.5 the defect reaches the same code paths used by `qlmanage` (Quick Look
thumbnails) and Preview.app. Double-clicking the malformed file in
Finder shows a normal-looking icon; the process behind it has
committed multi-GiB of RAM with no visible indication.

Reported to Apple Product Security and closed without being
classified as an exploitable vulnerability. Published here for the
record. **No memory corruption or code execution is claimed.**

## Status on macOS 27.0.1

Re-tested on 2026-10-19 on **macOS 27.0.1 (build 26A434)**, Mac17,3
with Apple M5, 16 GiB RAM, using the same `verify.sh`
(`evidence/macos-27.0.1/`):

```
ICNS PoC (796 B)
  CGImageSource:             count=1, but image and thumbnail are NULL
  task_info resident delta:  +2.41 to +2.66 MiB across 3 runs
  /usr/bin/time -l peak:     2.83 MiB
  qlmanage:                  hangs, no thumbnail, killed after 20 s
                             (qlmanage peak footprint 7.9 MiB)
  NSBitmapImageRep:          no spike (unchanged)

Legitimate ICNS control (Calendar.app's AppIcon.icns, 31,779 bytes)
  task_info resident delta:  +3.84 MiB, 4 images decoded
  (the system icon changed on 27.0.1; the 26.5 control was the
  31,408-byte version of the same file)
```

**The multi-GiB memory commit no longer reproduces on macOS 27.0.1.**
ImageIO now rejects the malformed image instead of decoding it.

### Does it still reproduce? Length-field variants

To check whether the chunk length still drives memory with other
inputs, 99 variants were tested
(`evidence/macos-27.0.1/length-variants/`; `run.sh` regenerates them
from the PoC and a system icon and re-runs everything):

```
Variant                                        images   resident
PoC as-is (ic13 length 0x97979797)               0      2.45 MiB
PoC with only the ic13 length set to fit         1      3.38 MiB  (decodes 256x256)
Legitimate icon, first chunk length 0x97979797   1      3.58 MiB  (decodes normally)
Legitimate icon (one chunk), length = EOF + 1    1      3.66 MiB
88 crafted files: 11 chunk types x 4 payload
  formats x {0x97979797, EOF + 1}               0 or 1  2.36 – 3.28 MiB
Largest value in the whole set                          3.83 MiB  (unmodified icon)
```

No variant used more than 4 MiB. With the 0x97979797 length, a valid
payload decodes normally and an invalid one is rejected. **In every
tested case on macOS 27.0.1, the chunk-length field no longer drives
memory use.** The PoC itself decodes as an ordinary 256×256 image
once only its length field is corrected. The behaviour described
below no longer reproduces on 27.0.1.

What is not known:

- whether the change was a deliberate fix, or a side effect of
  other changes in ImageIO;
- in which release it shipped. Only 26.5 (affected) and 27.0.1 (not
  affected) were tested.

The [macOS 27 security notes](https://support.apple.com/en-us/149035) list four ImageIO CVEs; none mentions
ICNS or memory exhaustion, so none can be matched to this report.
macOS 27.0.1 has [no published CVE entries](https://support.apple.com/en-us/100100).

**Quick Look hang.** `qlmanage` still hangs on the PoC, but on macOS
27.0.1 it also hangs on an 8-byte header-only `.icns` and on a broken
`.png`, and it produces a thumbnail for the length-corrected PoC. The
hang is how `qlmanage` behaves on files it cannot thumbnail, not a
remnant of this finding.

## What this is, and what it is not

- **What it is:** a resource-exhaustion robustness bug on macOS 26.5.
  The ICNS reader used a chunk-length field from the file to size
  memory, without checking it against the 796 bytes actually present.
  One small file made the decoding process hold about 2.4 GiB of
  physical memory.
- **What it is not:** no crash, out-of-bounds access, memory
  corruption, or code execution was observed or is claimed. In every
  run the allocation succeeded and the process continued normally.
- **Scope:** the cost falls on the process that decodes the file:
  Quick Look thumbnailing (~2.4 GiB) and Preview.app (≥2.5 GiB while
  open). `NSImage` and `NSBitmapImageRep` were not affected. The effect
  on overall system responsiveness was not measured.
- **Apple's assessment:** Apple reviewed the report and did not
  classify it as a security vulnerability. This repository does not
  dispute that. It documents a reproducible bug with the evidence
  needed to check it, and its status on macOS 27.0.1.

Everything below documents the original behaviour on macOS 26.5.

## Repository layout

```
pocs/         icns.icns (the PoC) + SHA-256 checksum.
reproduce/    vm_probe.m (source only; verify.sh rebuilds it),
              verify.sh (one-shot reproduction),
              ql_wrap.sh (qlmanage with a timeout).
evidence/     measurements.txt — captured run of verify.sh.
              lldb-backtrace.txt — lldb breakpoint capture.
              preview-app/ — Preview.app sampling notes.
              nsimage/ — AppKit per-step reproducer (negative
              result: AppKit does not reach the spike).
              ios/ — iPhone test log (device IDs redacted).
              macos-27.0.1/ — re-test on macOS 27.0.1, including
              length-variants/ (fix check).
analysis/     icns-chunk-length.md — full write-up.
```

## Quick verify

```
cd ImageIO-ICNS-ChunkLength-PoC
./reproduce/verify.sh > evidence.txt 2>&1
```

The script:
- re-execs itself under `arch -arm64` if invoked from a Rosetta shell;
- rebuilds `vm_probe` from source on each run;
- prints the binary architectures it uses;
- captures `task_info(TASK_VM_INFO)`, `/usr/bin/time -l`, and
  `qlmanage` measurements against the PoC and a legitimate ICNS
  control file from a system app;
- bounds each `qlmanage` invocation to a 20-second budget.

Preview.app and iOS observations are not regenerated by
`verify.sh`; they are captured separately under
`evidence/preview-app/` and `evidence/ios/`.

## Headline numbers on macOS 26.5 (from `evidence/`)

```
ICNS PoC (796 B)
  task_info resident delta:  ~2.37 GiB across all 3 runs (max-min spread = 64 KiB)
  /usr/bin/time -l peak:     ~2.37 GiB
  qlmanage peak footprint:   ~2.38 GiB  (thumbnail produced in 1 s)
  Preview.app:               via `open -a Preview` → ≥2.5 GiB peak, sustained multi-GiB
                             (one captured run reached 4.0 GiB peak / 2.8 GiB sustained;
                             that exact peak is not deterministic across re-runs, but the
                             multi-GiB commit itself is consistent)
                             via `open file` (Launch Services) → peak ~2.5 GiB
                             (Finder double-click pathway; consistent across re-runs)

Legitimate ICNS control (Calendar.app's AppIcon.icns, 31,408 bytes)
  task_info resident delta:  3.39 MiB
  /usr/bin/time -l peak:     2.91 MiB
  qlmanage peak footprint:   15.3 MiB  (thumbnail produced in 1 s)
```

A legitimate ICNS file about 40× larger than the PoC uses roughly
160× (Quick Look) to 700×+ (`task_info`, `/usr/bin/time`) less memory
through the same APIs. The behaviour is specific to the malformed
chunk-length field described in
[analysis/icns-chunk-length.md](analysis/icns-chunk-length.md), not a
general framework characteristic.

## The finding in one paragraph

The 796-byte ICNS PoC declares a single `ic13` chunk whose length
field is `0x97979797` (~2.37 GiB). The file is only 796 bytes total:
after the 8-byte chunk header, only 780 bytes of payload could
possibly remain. The CGImageSource path accepts this malformed input
and commits memory proportional to the file-supplied chunk
length. Reproduces in `CGImageSource`, `qlmanage`, and Preview.app;
`NSImage` / `NSBitmapImageRep` do not reach it (see
`evidence/nsimage/`). Full write-up, byte layout and suggested fix in
[analysis/icns-chunk-length.md](analysis/icns-chunk-length.md).

## Measurement environment

- macOS 26.5 Tahoe, build 25F71
- Mac15,12 with Apple M3, 16 GiB RAM
- Measurement tool compiled `-arch arm64`; `sysctl.proc_translated = 0`
  confirms native arm64 execution at runtime

## iOS

A signed test app on an iPhone 15 Plus running iOS 26.5 reproduces
the virtual reservation (~2.37 GiB of virtual growth, comparable to
macOS),
but iOS does not commit the pages in this code path — resident growth
is only +1.02 MiB. iOS is **not** characterised here as affected as a
user-visible DoS. The log is in `evidence/ios/` for completeness.

## Disclosure

- Reported to Apple Product Security.
- Apple closed the report without classifying the behaviour as an
  exploitable vulnerability.
- Published here to document the finding. The PoC is a 796-byte ICNS
  file with one malformed `ic13` chunk. It contains no executable code
  and no payload.

## Author

Yousef — [@yousef_dev921](https://x.com/yousef_dev921)

## License

The text, scripts, and analysis in this repository are released under
the MIT License — see [LICENSE](LICENSE). The PoC file in `pocs/` is
provided for research and reproducibility only.
