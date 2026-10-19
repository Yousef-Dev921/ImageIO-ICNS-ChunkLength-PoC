# ICNS chunk walker in `ImageIO.framework`

## Where the bug lives

```
/System/Library/Frameworks/ImageIO.framework/ImageIO
  ICNS-decoding path inside ImageIO's reader pipeline
```

Reached through `CGImageSource` entry points on an ICNS-magic
file: confirmed via `CGImageSourceCreateImageAtIndex`,
`CGImageSourceCreateThumbnailAtIndex`, and `qlmanage`.
(`NSImage initWithData:` is NOT impacted on ICNS — it takes a
different code path; see `evidence/nsimage/`.)

The CGImageSource path accepts this malformed ICNS input and
proceeds far enough to allocate/commit memory proportional to the
attacker-controlled chunk length. As supplementary context I
include an lldb backtrace of the first large allocation observed
during processing (`evidence/lldb-backtrace.txt`); the trace
captures dyld/plugin-loading code inside the ImageIO reader
pipeline, not the ICNS decoder itself, so I do not present it as
identification of the exact internal allocation site. The
strongest evidence for this finding is the byte-level chunk
layout below combined with the stable resident-memory
measurements.


## What the PoC actually contains

The 796-byte `icns.icns` file in `pocs/` decodes as:

```
0x00  69 63 6e 73                  magic = "icns"
0x04  00 00 07 c8                  header total length = 1992  (file is only 796)
0x08  69 63 31 33                  first chunk type = "ic13"
0x0c  97 97 97 97                  first chunk length = 0x97979797 = 2,543,294,359 (≈2.4 GiB)
0x10  ... 0x97 0x97 ... 0x97       ic13 payload byte-pattern starts here
0x6c  00 00 05 22                  embedded length field
0x70  89 50 4e 47 ...              embedded PNG header inside the ic13 payload
```

So this PoC does **not** trigger the `length < 8` unsigned-underflow
case — `length` here is huge, not small. The defect the PoC
demonstrates is more straightforward: the chunk-length field is
**not bounded against the bytes remaining in the file**. The walker
accepts a 4-byte field that claims this single chunk is roughly
2.4 GiB long, and uses that value as an allocation/size driver
inside the rest of the decode pipeline.

The numerical correspondence is direct:

```
Claimed chunk length:   0x97979797 = 2,543,294,359 bytes  ≈ 2.37 GiB
Measured resident commit (avg of 3 runs): ~2.37 GiB
```

For precise byte accounting: the file is 796 bytes total, the chunk
header occupies bytes 0x08–0x0f (8 bytes), so 788 bytes remain from
the chunk start (including the header) and 780 bytes of payload remain
after the chunk header. Either way, the declared chunk length of
2,543,294,359 bytes is roughly 3.3 million times larger than what the
file can possibly contain, and the parser proceeds without that check.

(The `length < 8` underflow path is a separate sub-defect in the
same walker — I confirmed it independently during early triage by
varying chunk-type and chunk-length fields — but the PoC in this
package does not demonstrate that case. It demonstrates the
unbounded-large-length case.)

## Suggested fix

Before using the chunk's `length` field as a size in any subsequent
arithmetic, validate:

- `length >= 8`                        (must include its own header)
- `length <= remaining_bytes_in_file`  (cannot extend past EOF)
- `length <= MAX_ICNS_CHUNK_BYTES`     (an implementation-defined
                                         sane maximum)

Reject the file with an appropriate error code if any check fails.

## Measurement (from `evidence/measurements.txt`)

Three back-to-back runs in a native arm64 process
(`sysctl.proc_translated = 0`):

```
Run 1/3:  resident +2,546,155,520  (2.37 GiB)
Run 2/3:  resident +2,546,089,984  (2.37 GiB)
Run 3/3:  resident +2,546,139,136  (2.37 GiB)
```

Identical to within 64 KiB (max-min spread = 65,536 bytes exactly).
Independent measurement via
`/usr/bin/time -l peak memory footprint`: 2,547,501,312 bytes
(2.37 GiB), agreeing with `task_info` to within 0.06%.

Running `qlmanage -t -s 1024` on the PoC completes in about 1 s
and reports:

```
peak memory footprint:  2,560,690,480 B  (2.38 GiB)
Done producing thumbnails
```

A thumbnail is produced — the user sees a small icon — but the
process commits roughly 2.4 GB to render it. The peak matches the
chunk-length value to within ~0.7%, which is direct evidence that
the unchecked length field is the size driver.

## Legitimate ICNS control

For fair comparison, ran a normal ICNS file from the system
(Calendar.app's `AppIcon.icns`, 31,408 bytes — about 40× larger
than the PoC) through the same APIs:

```
task_info resident delta:       +3,555,328     (3.39 MiB)
/usr/bin/time -l peak:          3,047,904       (2.91 MiB)
qlmanage peak memory footprint: 16,040,488      (15.3 MiB)
qlmanage outcome:               thumbnail produced in 1 s
```

A legitimate ICNS file 40× larger than the PoC uses ~170× less
memory through the same code path. The behaviour is specific to
the malformed chunk-length field, not a general framework
characteristic.


## Preview.app on the same input

Opening the PoC with `open -a Preview icns.icns` causes Preview.app
itself to spike to **at least ~2.5 GiB resident** within a few seconds
and sustain multi-GiB usage while displaying the icon. One captured run reached a peak of ~4.0 GiB at
sample [9] (~4.5 s in) and settled around ~2.8 GiB
(`evidence/preview-app/measurements.txt`, TEST 1a). That exact peak
is not deterministic — separate re-runs on the same input have peaked
at ~2.5 GiB without reaching 4 GiB — but the multi-GiB commit itself
is consistent across runs. I reproduced the same multi-GiB behaviour
with `open icns.icns` (no `-a` flag), which routes through Launch
Services to the default app for `.icns` — the same code path Finder
uses on a double-click; that pathway consistently peaks at ~2.5 GiB
across re-runs.

The same Preview.app, opening a legitimate ICNS file 60× larger
(`AppIconLoc.icns`, 47,110 bytes), stays at about **117 MiB** —
roughly 34× less memory from a 60× larger file, indicating the
behaviour is input-specific.

A user double-clicking this 796-byte file in Finder triggers the
Launch-Services-routed `Preview` launch tested above and silently
consumes ~3 GiB of system RAM for the lifetime of the window.

## Why this matters

The decode succeeds. A user double-clicking the file in Finder
sees Preview.app open and display a normal-looking icon, and
Quick Look thumbnail generation produces a thumbnail; in both
cases the process has committed multi-gigabyte memory with no
visible indication. On a 16 GiB Mac with several apps open, this
can push the system into noticeable swap pressure.

The PoC reaches the `qlmanage` / Quick Look thumbnail path; any
system component that requests thumbnails for such files may incur
this cost. Mail, AirDrop, and Files are plausible reachable surfaces
given the shared Quick Look pipeline, but they are not measured
here.
