# Windows 0.9.0 revision 1: evidence and implementation

## Scope

This repair starts from completed 0.9.0 commit `7ec095e9b9c949a79ff55cbd40d0fda9499b4faa`. The Mac application is frozen. `Sources/Core`, `Sources/Mac`, `Resources`, `WebSource`, Mac build/test scripts, shared tests and the existing desktop workflow retain their Git content and modes. The Windows workflow checks 162 protected files before and after building and on the clean installation runner.

The repair lives in `Sources/Compat`, the Tauri compatibility host, Windows scripts and Windows workflows. It does not change the shared UI to compensate for an unverified dropdown problem.

## Reproduction with the published installers

The [released-app diagnostic run](https://github.com/jason840709/RcloneBrowserNext/actions/runs/39571154441) downloaded the actual 0.8.0 and 0.9.0 Windows installers, checked their release/asset identities, lengths and SHA-256, then installed them on separate `windows-2025` machines. It did not rebuild the old application or substitute a mock engine.

| Installer | SHA-256 |
| --- | --- |
| Windows 0.8.0 | `4b71936b341c7030f12fbadafd5f74246fc7eaf1ad0c5fa6e69fe102bc4d7a63` |
| Windows 0.9.0 | `d943ee8a30e5bb8e16ad8a2c1edd20645c3cef733378ea8a1a7890de0f886780` |

Both installed helpers produced the same results in the 16 filesystem cases:

| Case | Observed old-version result |
| --- | --- |
| Local location catalog, with or without configured rclone | C: and D: absent |
| Ordinary small Unicode directory | Passed |
| Actual Windows runner user home | Permission error; no complete listing |
| System drive root | Invalid-file-name error; no complete listing |
| Directory containing a broken junction and an ordinary sibling | Entire listing failed with missing-file error |
| File of 2 GiB minus one byte, listing and size | Both passed |
| File of 2 GiB plus one byte, listing and size | Helper exited with `0xC000001D` |
| File of 3 GiB, listing and size | Helper exited with `0xC000001D` |
| Files of 4 GiB plus one byte and 5 GiB, listing and size | Requests failed with `NSCocoaErrorDomain` 256 |

These are targeted defect cases, not a general application pass-rate benchmark. Every case starts its own helper so one crash cannot hide subsequent failures. Sparse-file sizes are independently verified by Python stat and Windows allocation metadata; the fixtures do not write gigabytes of content.

The older diagnostic run `39569734306` remains available for provenance, but its large-file fixtures were incomplete: Python's Windows truncate path allocated content. The corrected run above uses `SetFilePointerEx` / `SetEndOfFile` and completed all 16 cases without infrastructure errors. Baseline diagnostic exit success means the observations completed, not that the old product passed.

## Why the Windows filesystem path changed

The original catalog populates mounted volumes only in its Mac-specific block. Windows therefore had no drive-letter entries. Its local listing also obtains resource values for every child and throws away the entire result if one child cannot be inspected.

The pinned [Swift 6.1.2 Windows Foundation implementation](https://github.com/swiftlang/swift-corelibs-foundation/blob/swift-6.1.2-RELEASE/Sources/Foundation/FileManager%2BWin32.swift) checks that the high 32 size bits are zero, then converts the low 32 bits to signed `_off_t`. This is reached by the resource-value path even when callers also ask for directory type or dates. The observed size boundary agrees with that code and [Swift issue 5258](https://github.com/swiftlang/swift-corelibs-foundation/issues/5258).

`WindowsLocalFileSystem` replaces only the Windows host's local `list`, `size`, `mkdir`, `rename` and `remove` calls. Remote operations, rclone transfer behavior, saved tasks and settings still use the shared engine. The adapter uses wide-character Windows APIs, combines both size words as `UInt64`, preserves drive/UNC roots and uses extended internal paths for long names.

Listing reads metadata supplied by `FindFirstFileW` / `FindNextFileW`; it does not open every child merely to obtain its size. A failure to enumerate the requested parent remains an error. The implementation does not grant filesystem access or bypass Windows ACLs.

Before deletion, all selected names and types are checked. Directory handles are retained while deleting their children, without write/delete sharing that would allow the directory to be replaced during traversal. Name-surrogate reparse points are removed as links; their targets are not traversed. Folder-size traversal also skips those links. Rename never enables the Windows replace-existing option. Errors during a multi-item deletion are reported; deletion is not transactional.

## Installed UI verification

The previous compatibility smoke checked startup, the bridge and appearance with an empty remote configuration. It did not select remotes or browse actual Windows drives.

The new probe launches the normal installed app with an isolated CI profile and 17 local alias remotes. Trusted pointer/keyboard operations select first, middle and last entries on both panes, assert the actual remote and its unique listed file, navigate local directories, edit startup locations and repeat selections at 125% interface size in a small native window. It uses the real WebView2 and rclone, without replacing host calls with mocks.

The first two baseline UI attempts did not attach to CDP and are not evidence of a dropdown pass or failure. Their native diagnostics confirm that the app and WebView2 were running. Subsequent receipts distinguish attachment/setup failure from an executed product case.

A successful candidate requires every required filesystem, mutation and UI case, matching executable identities, clean installation/upgrade receipts and the existing Rust/platform/transfer regressions. Missing or empty reports fail the gate. The release verification attachment links the successful exact-source run; workflow artifacts contain the original JSON, logs and synthetic UI evidence.

## Version and release isolation

| Item | Windows revision | Existing Mac |
| --- | --- | --- |
| App base version | 0.9.0 | 0.9.0 |
| Windows Tauri override | `0.9.0+1` | Not used |
| Windows numeric version | `0.9.0.1` | Not used |
| Release tag | `windows-v0.9.0-r1` | `v0.9.0` |
| Stable latest release | Remains `v0.9.0` | Remains `v0.9.0` |

The Windows-only Tauri configuration preserves the existing product identifier and uses numeric build metadata supported by the pinned NSIS packager. Installation and upgrade tests inspect actual PE and registry versions and compare saved state before and after installation.

Publication uses the already tested installer from the successful Windows candidate run for the exact source commit. It creates a separate prerelease and never replaces an existing release or asset. It checks the original release, tag, all asset metadata and stable latest endpoint before and after publication. No Mac application is rebuilt or republished by the Windows workflows.

The UI cases use synthetic local aliases, not the original reporter's cloud credentials. Hosted Windows Server 2025 x64 verification does not replace testing every Windows desktop version, storage provider, device or permission configuration.
