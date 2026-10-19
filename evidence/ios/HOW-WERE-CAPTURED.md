# How the iPhone logs were captured

## Device
- iPhone 15 Plus (iPhone15,5)
- iOS 26.5 (build 23F77)
- Hardware UDID: <HARDWARE_UDID_REDACTED>
- CoreDevice ID: <COREDEVICE_ID_REDACTED>

## Tooling
- Test app: `ImageProbe` (signed with a personal Apple Developer
  cert; team ID and signing identity redacted; bundle id
  `com.example.imageprobe`).
- Entitlements: `get-task-allow=true`, signed with an iOS Team
  Provisioning Profile that includes the device's UDID.
- The iOS test app is a small arm64 UIKit binary that calls the
  same CGImageSource* APIs and samples `task_info(TASK_VM_INFO)`
  before and after each call. Source is included in this folder
  as `ImageProbe_main.m`.

## Workflow
```
# 1. Sign + install
xcrun devicectl device install app --device <UDID> ImageProbe.app

# 2. Launch (probe runs, writes Documents/result.txt, app stays alive)
xcrun devicectl device process launch --device <UDID> \
    com.example.imageprobe

# 3. Pull the result.txt the probe wrote
xcrun devicectl device copy from \
    --device <UDID> \
    --domain-type appDataContainer \
    --domain-identifier com.example.imageprobe \
    --source Documents/result.txt \
    --destination ./iphone-result.txt
```

The `appDataContainer` domain reaches the app's sandboxed Documents
directory. No jailbreak; this is the standard CoreDevice path for
pulling files from your own signed app.

## What the logs show
On iOS 26.5 the same size-derived allocation path appears to run
(matching virtual growth — ~2.37 GiB for the ICNS PoC, matching
macOS), but iOS does not commit the pages. Resident growth is only
+1.02 MiB. No user-visible impact was observed on iOS; the test app
stays alive and continues to run.
