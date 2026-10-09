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
| Check/download releases | GitHub HTTPS endpoints, URLSession, SHA-256 | Use Store updates instead | Yes; no automatic installation |
| Local diagnostic logs/export | Bounded JSONL, user-selected ZIP | Sandbox-local storage | Yes; no automatic upload |

## App Store Profile

1. Create an Xcode macOS app target with bundle identifier `com.wondercraft.WonderBox`.
2. Enable App Sandbox and user-selected read/write access with `WonderBox-AppStore.entitlements`.
3. Exclude `CSMC`, both privileged helpers, system-cache cleanup, and the fan write controls from the Store target. The direct-release updater is hidden and disabled in sandboxed builds; use Store updates.
4. Use security-scoped bookmarks for folders explicitly selected by the user.
5. Keep `PrivacyInfo.xcprivacy` in the application resources.
6. Archive, validate, notarize, and run App Store Connect privacy checks.

## Direct Profile

`scripts/package_app.sh` produces the Direct profile. Production releases should replace ad-hoc signing with a Developer ID Application identity, harden the runtime, notarize the archive, and staple the ticket. The shared helper (protocol v6) is reached over a root-owned Unix socket and verifies the caller's audit-token signing identity and authorizing user ID. It accepts fixed fan and memory-maintenance commands and restricted Trash requests, never arbitrary shell commands. The app reinstalls the helper with administrator authorization when its protocol or the app's signing identity changes.

The Direct app may guide users to the macOS Full Disk Access pane. Permission remains user-controlled; WonderBox only probes whether a protected file can be opened and does not read its contents. Sandboxed builds suppress this onboarding and retain user-selected directory access.

AppleSMC behavior varies by machine. Macs without an exposed writable SMC remain in automatic mode and the UI reports the capability as unavailable.

### Privileged helper privacy attribution

The v6 daemon declares `AssociatedBundleIdentifiers = [com.wondercraft.WonderBox]` in its launchd plist, following [Apple's guidance on responsible code](https://developer.apple.com/forums/thread/678819). Its Mach-O contains an `__TEXT,__info_plist` section with the stable helper identifier. Packaging signs the helper first and writes its actual designated requirement into the app's `SMPrivilegedExecutables` dictionary before signing the main app. This ownership metadata is separate from—and does not replace—the root-owned, UID-bound client authorization and audit-token signature validation.

The protocol bump forces previously installed v5 daemons and launchd plists through the existing administrator-approved upgrade path. Privacy denial does not itself trigger a reinstall or another password prompt. No TCC databases, privacy approvals or system security settings are modified. Ad-hoc signing still changes the app's identity between builds; this fix does not make those identities stable.

The v6 metadata was **not sufficient** on the development machine: the installed daemon still received `EPERM` opening the user's Trash, while the main app had privacy access. Do not treat this metadata as a verified TCC permission fix.

Uninstall now tries `FileManager.trashItem` first, then batches only failures through Finder’s `delete` Apple event (Move to Trash). `NSWorkspace.recycle` was also tested with root-owned samples and returned Cocoa 513, so it is not used as the fallback. Paths are passed as typed Apple-event descriptors, never interpolated into script source; serialized execution stays off the UI thread. Finder handles its own authentication. The existing `NSAppleEventsUsageDescription` now covers moving selected files as well as Trash sizing/emptying. It does not install or call the root daemon for uninstall. The Finder request acknowledgement and source existence are checked, partial success is retained, and cancellation never triggers another privileged attempt. The UI presents the actual system error, not an inferred missing Full Disk Access grant; error -1743 offers Automation settings, and a timeout (-1712) warns that Finder may still be working. Diagnostics retain counts and numeric errors, not filenames or descriptions. The helper's restricted Trash protocol remains available for compatibility, with unchanged authentication and path protections.

`swift test` uses injected system callbacks and never displays authentication dialogs. After explicit user approval, run `zsh scripts/test_system_trash.sh` for real-system verification: it creates uniquely named disposable root-owned app bundles, reproduces the ordinary API's permission failure, then invokes the production system Trash path. It leaves successful test bundles recoverable in the user's Trash and never targets installed apps or empties the Trash. Test macOS 14 and current macOS separately before publishing.

When WonderBox is active, the Finder fallback first calls the macOS 14 cooperative activation API (`yieldActivation`), then sends Finder `activate` immediately before `delete`. It does not activate Finder again after the authentication dialog appears or reactivate WonderBox when the operation finishes. If the user switched to another app during the initial file operation, it does not take that app's focus. This is a focus handoff, not a change to Finder's authentication policy or a cached administrator credential. Unit tests cover the handoff decision and script ordering; confirming that Touch ID works without clicking the dialog requires an interactive test from a foreground WonderBox window.

## Update release contract

Use a stable semantic-version tag (`vMAJOR.MINOR.PATCH`), publish `WonderBox-MAJOR.MINOR.PATCH.zip` and include its SHA-256 in `SHA256SUMS`. Mark the release Latest only after the ZIP and checksums are uploaded. The updater uses the [latest-release API](https://docs.github.com/en/rest/releases/releases#get-the-latest-release); API `assets[].digest` is preferred, with `SHA256SUMS` as a fallback. On REST quota errors, the official `releases/latest` redirect plus archive HEAD and checksum requests supply the same information. Draft/prerelease versions, foreign URLs, oversized assets (over 200 MiB), invalid hashes and downgrades are rejected.

The current downloads remain ad-hoc signed; SHA-256 checks transfer integrity against GitHub's metadata, not independent publisher authenticity. Downloaded archives retain normal quarantine provenance. No application replacement, helper authorization changes or Gatekeeper changes are performed by the updater.
