# README screenshots

The English and Simplified Chinese READMEs use captures under
`screenshots/` and `screenshots/zh/`. These are native app captures, not mockups.

The current capture pass covers the same source build in both languages.
`menubar-label.png` is shared because the status-item text uses the same
`CPU / RAM / PWR` abbreviations in English and Chinese.

## Capture set

| File | Content |
| --- | --- |
| `overview.png` | Overview and system information |
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

1. Build the current source with `scripts/package_app.sh`. Use that exact `.app`
   for both languages; do not mix an older `/Applications` copy with the new build.
   Fully quit before changing builds. A development build may need its own macOS
   Full Disk Access approval even when an installed copy already has permission.
2. Record the original app language, menu-bar preferences, automatic-cleanup
   setting, window position and size. Temporarily pause automatic cleanup so the
   documentation run remains read-only. Do not install/restart the watcher or
   approve privileged actions for a screenshot.
3. Use a consistent window size (most current captures use 1200 × 850 points).
   Record whether the current theme is light or dark. Wait for scans and initial samples to finish. Allow at least a minute
   of monitoring for useful processor/power charts. Unavailable sensors must remain
   unavailable; never paint over readings or replace them with invented values.
4. Capture only the WonderBox window or sheet. For menu-bar labels, crop to that
   item's bounds, excluding unrelated icons and desktop content. Review each image
   for private names, paths, notifications and unrelated windows before adding it.
5. Capture settings in three scroll positions so menu-bar, background and diagnostic
   features are readable. Capture the new power preference off during verification,
   then enable it for the menu-bar example; it remains **off by default** in code.
6. Switch the app language, relaunch the same build and repeat. Keep counterpart
   filenames identical. Downscale main-window PNGs to 1600 pixels wide while keeping
   their aspect ratio. Preserve transparency and color profiles when optimizing PNGs.
7. Restore the original preferences and window state. Discard selection drafts;
   do not run cleanup, uninstall, memory optimization or fan writes just for images.
8. Inspect every image at readable size, check all relative links in both READMEs,
   and ensure any added image is actually referenced. Record capture provenance below.

## Provenance

The 2026-11-05 to 2026-11-06 refresh uses the current source based on version 1.2.3, including the
unreleased menu-bar system-power option, on an Apple M4 Max running macOS 26.5.2.
Values reflect that Mac's workload and are not benchmarks or a promise of sensor
coverage on other machines. Screenshots show chosen settings, not necessarily defaults.
Full Disk Access was approved for the development copy before capturing the
final cleanup, disk and related-file screens. The original installed app and
its preferences were restored after capture; no cleanup or uninstall ran.
