# Distribution and API Boundaries

Reference policy: [App Review Guidelines](https://developer.apple.com/app-store/review/guidelines/) and [required-reason API documentation](https://developer.apple.com/documentation/bundleresources/describing-use-of-required-reason-api). The capability split below was last checked on 2026-08-02.

## Capability Matrix

| Capability | API | App Store | Direct |
| --- | --- | --- | --- |
| CPU and memory status | Mach host statistics | Yes | Yes |
| Memory categories, swap, pressure level | Mach host statistics, `sysctl` | Yes | Yes |
| Per-app memory ranking | `libproc` rusage, `NSRunningApplication` | Sandbox-limited | Yes |
| Memory-pressure broadcast and file-cache purge | Fixed-command helper daemon (`memory_pressure -S`, `purge`) | No | Yes |
| Disk and file sizes | Foundation URL resources | Yes, inside sandbox grants | Yes |
| Network throughput | `getifaddrs` | Yes | Yes |
| Battery status | IOKit Power Sources | Yes | Yes |
| Thermal pressure | `ProcessInfo.thermalState` | Yes | Yes |
| Prevent idle sleep | IOKit power assertions | Yes | Yes |
| User-selected app removal | `NSOpenPanel`, `FileManager.trashItem` | Yes | Yes |
| Broad cache cleanup | Foundation file APIs | Sandbox-limited | Yes |
| Full Disk Access onboarding | System Settings privacy pane | No | Yes, user-controlled |
| `/Library/Caches` cleanup | Fixed-command maintenance helper | No | Yes |
| Empty user Trash | Foundation file APIs | Sandbox-limited | Yes |
| Fan read/write | AppleSMC user client | No | Hardware-dependent |

## App Store Profile

1. Create an Xcode macOS app target with bundle identifier `com.wondercraft.WonderBox`.
2. Enable App Sandbox and user-selected read/write access with `WonderBox-AppStore.entitlements`.
3. Exclude `CSMC`, both privileged helpers, system-cache cleanup, and the fan write controls from the Store target.
4. Use security-scoped bookmarks for folders explicitly selected by the user.
5. Keep `PrivacyInfo.xcprivacy` in the application resources.
6. Archive, validate, notarize, and run App Store Connect privacy checks.

## Direct Profile

`scripts/package_app.sh` produces the Direct profile. Production releases should replace ad-hoc signing with a Developer ID Application identity, harden the runtime, notarize the archive, and staple the ticket. The fan/memory helper is a fixed-command daemon reached over a root-owned Unix socket; it only accepts `version`, `status`, `set-auto`, `set-rpm`, and `optimize-memory`. The app compares the daemon's protocol version on every privileged action and reinstalls it (one administrator prompt) when the bundled helper is newer.

The Direct app may guide users to the macOS Full Disk Access pane. Permission remains user-controlled; WonderBox only probes whether a protected file can be opened and does not read its contents. Sandboxed builds suppress this onboarding and retain user-selected directory access.

AppleSMC behavior varies by machine. Macs without an exposed writable SMC remain in automatic mode and the UI reports the capability as unavailable.
