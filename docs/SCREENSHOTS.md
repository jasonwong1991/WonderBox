# README screenshots

The English and Simplified Chinese READMEs use captures under
`screenshots/` and `screenshots/zh/`. These are native app captures, not mockups.

Use the same app installation for both languages within each capture pass.
`menubar-label.png` is shared because the status-item text uses the same
`CPU / RAM / PWR` abbreviations in English and Chinese.

Use **Light** appearance throughout both READMEs. Only `settings.png`, which
demonstrates the appearance controls, intentionally uses **Dark** appearance.
Do not change sensor values or recolor dark captures to simulate a light theme.

## Capture set

| File | Content |
| --- | --- |
| `overview.png` | Overview, including the system-power card, and system information |
| `memory.png` | Memory categories and app ranking |
| `cpu.png`, `gpu.png` | 60-second charts and per-app usage |
| `power.png` | System/CPU/GPU watts and system-power history |
| `fan.png` | RPM, control modes and available temperature sensors |
| `awake.png` | Duration and display options, without starting an assertion |
| `applications.png` | WonderBox's own related-file review; no uninstall performed |
| `cleaner-deep.png` | Completed deep scan; no cleanup performed |
| `cleaner-detail.png` | Cache groups expanded to individual folders |
| `storage.png` | A deliberately selected folder, without private file contents |
| `menubar.png` | Compact dashboard, including temperatures and quick-clean estimate |
| `menubar-label.png` | CPU/RAM/system-power status-item label |
| `settings.png` | Appearance, language and all three menu-bar toggles |
| `settings-background.png` | Watcher, automatic cleanup and startup |
| `settings-diagnostics.png` | Update and local diagnostic controls |

`app-icon.png` is shared between languages and comes from the repository's icon generator.

## Refresh workflow

1. Confirm the exact app installation requested for the capture pass and record
   its path and version. When using the installed app, launch only
   `/Applications/WonderBox.app`; do not launch or substitute `build/WonderBox.app`.
   Use the same installation for both languages. Only build a development copy
   when explicitly using a source-build capture workflow; its macOS Full Disk
   Access approval can differ from the installed copy's approval.
2. Record the original app language, menu-bar preferences, automatic-cleanup
   setting, window position and size. Temporarily pause automatic cleanup so the
   documentation run remains read-only. Do not install/restart the watcher or
   approve privileged actions for a screenshot.
3. Use a consistent window size (most current captures use 1200 × 850 points).
   Record the original appearance, then explicitly select Light for all captures
   except the appearance-controls example. Wait for scans and initial samples to finish. Allow at least a minute
   of monitoring for useful processor/power charts. Unavailable sensors must remain
   unavailable; never paint over readings or replace them with invented values.
4. Capture only the WonderBox window or sheet. For menu-bar labels, crop to that
   item's bounds, excluding unrelated icons and desktop content. Review each image
   for private names, paths, notifications and unrelated windows before adding it.
   Translucent menu panels should be captured as displayed over a neutral light
   backdrop: window-only capture can incorrectly flatten the material to gray.
5. Capture settings in three scroll positions so menu-bar, background and diagnostic
   features are readable. Capture the new power preference off during verification,
   then enable it for the menu-bar example; it remains **off by default** in code.
6. Switch the app language, relaunch the same build and repeat. Keep counterpart
   filenames identical. Downscale main-window PNGs to 1600 pixels wide while keeping
   their aspect ratio. Preserve transparency and color profiles when optimizing PNGs.
7. Restore the original preferences and window state, including any temporary
   system appearance, wallpaper or display-mode changes. Discard selection drafts;
   do not run cleanup, uninstall, memory optimization or fan writes just for images.
8. Inspect every image at readable size, check all relative links in both READMEs,
   and ensure any added image is actually referenced. Record capture provenance below.

## Provenance

### 2026-11-07 — installed app, light appearance

The overview, memory, CPU, GPU, power, fan, keep-awake, menu panel and menu-bar
label images were refreshed in both languages using only the user's installed
`/Applications/WonderBox.app` (version 1.2.3, build 123), including the new
Overview system-power card. No development app was launched. The installed
executable's SHA-256 was
`8b2375b30a8c0ba5a8860f3338b75cb1a8ff82219f82e7f38424d0426a07a265`.

Existing light cleanup, uninstaller, disk and background/diagnostic settings
images were retained, as were the two intentional dark appearance-control
examples. Menu-bar label capture temporarily used a wider display mode and a
neutral light wallpaper so the actual status item was visible rather than
hidden by other menu items. All displayed readings are native app readings.
Automatic cleanup was paused during capture. The original app preferences,
system appearance, wallpaper, display mode and window geometry were restored;
no cleanup, uninstall, memory optimization or fan-control changes were performed.

### 2026-11-05 to 2026-11-06 — earlier source-build captures

The 2026-11-05 to 2026-11-06 refresh used the source based on version 1.2.3, including the
unreleased menu-bar system-power option, on an Apple M4 Max running macOS 26.5.2.
Values reflect that Mac's workload and are not benchmarks or a promise of sensor
coverage on other machines. Screenshots show chosen settings, not necessarily defaults.
Full Disk Access was approved for the development copy before capturing the
final cleanup, disk and related-file screens. The original installed app and
its preferences were restored after capture; no cleanup or uninstall ran.
