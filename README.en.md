# Rclone Browser Next

**A dual-pane Mac app for moving files between local folders, NAS storage and the cloud.**

[繁體中文](README.md) · English · [Releases](https://github.com/jason840709/RcloneBrowserNext/releases) · [User guide (Traditional Chinese)](README.zh-TW.md) · [Report an issue](https://github.com/jason840709/RcloneBrowserNext/issues)

![Rclone Browser Next 0.5.0 in dark purple: independent folder panes with transfer direction, operation and Dry Run controls in the middle](docs/images/main-dark.png)

*Version 0.5.0, shown with demonstration data.*

Rclone Browser Next is a macOS interface for [rclone](https://rclone.org/), developed by **Jason Chen**. Each pane can browse a local folder, mounted drive, cloud service or NAS/server connection. Backing up a Mac to a NAS, sending NAS files to the cloud and copying between two local folders use the same controls.

The project builds on Rclone Browser's Remotes, Jobs and Tasks workflows, arranged around two folder panes, central transfer controls and a job list. It aims to make the source, destination and transfer settings clear before a job starts, and to let you save a backup setup for later use.

## Get started

Requires **macOS 13 or later**, on **Apple Silicon or Intel**. The local build script selects the app architecture for your Mac.

1. Choose a version from [Releases](https://github.com/jason840709/RcloneBrowserNext/releases). To build this source tree, you can also choose **Code → Download ZIP** on the repository page. Extract the complete folder.
2. Double-click `Build-on-Mac.command`. It creates and opens `Rclone Browser Next.app` in the same folder.
3. In Settings, choose the **rclone installation location**. Select an existing executable or download the engine into your chosen folder. You can also download it yourself from [rclone's website](https://rclone.org/downloads/).
4. Open **Account setup (Config)** at the top left to add cloud or NAS/server connections through rclone's interactive configuration.
5. Choose the two locations, direction and operation. Use **Dry Run** to inspect the proposed actions, then run the transfer.

Building uses an existing **Xcode or Apple Command Line Tools** installation. The web interface is already built and included, so ordinary app builds need no Node.js or npm. The script does not install Homebrew, developer tools or rclone. Build caches, temporary files and outputs stay inside the project folder; if Apple tools are missing, it explains the requirement and stops.

The app uses Swift, AppKit and the system WebKit. rclone lives separately in the folder you choose. The app therefore does not need to carry its own browser engine or rclone binary, and the two can be updated separately. The app's size does not include the external rclone installation.

Local builds receive a verified **ad-hoc signature**. This is not Apple Developer ID signing or notarization; downloaded app bundles can still be subject to Gatekeeper restrictions. See [Build on Mac (Traditional Chinese)](docs/BUILD_MAC.zh-TW.md) for installation details and troubleshooting.

## Everyday use

| Feature | What it does |
| --- | --- |
| Independent panes and tabs | Browse local folders, mounted volumes, cloud storage and NAS/server remotes on either side; each tab has its own back/forward history, including mouse side-button navigation |
| Copy, move and sync | Transfer in either direction, with optional file and folder selection |
| Dry Run | Run an actual rclone preview with the chosen settings, without copying, moving or deleting data |
| Saved Tasks | Store the source, destination, operation and full transfer settings; every task has Dry Run, Run, Edit and Delete actions |
| Remember workspace | Restore both folders, direction and transfer settings at the next launch, without starting a job automatically |
| Progress and logs | Show bytes, file counts, decimal percentages, average speed, estimated time and logs; cancel active jobs |
| Appearance and language | Dark purple, light purple, dark blue and light blue themes; Traditional Chinese, English and Japanese, with a system-language option |
| Connection settings | Proxies, IPv4/IPv6, connection and idle timeouts, request rate, bandwidth limits and other rclone transfer options |

Dark purple is the default, using neutral dark surfaces with purple accents for selections and primary actions. Appearance and language changes apply immediately. The system-language option uses Traditional Chinese for Chinese, Japanese for Japanese and English for other primary system languages.

### Sync uses the source as the reference

**Sync changes only the destination, making it match the source within the selected scope.** It updates destination files and deletes destination-only files. It does not propagate changes back to the source. Copy keeps extra destination files; move removes corresponding source items after they have been transferred successfully.

Filters, selection and skip rules still affect the result. Excluded destination files are retained by default. If you choose to skip existing or newer files, the destination may keep a version that differs from the source. See the [user guide (Traditional Chinese)](README.zh-TW.md) and [rclone sync documentation](https://rclone.org/commands/rclone_sync/).

Dry Run leaves files unchanged, but still lists directories and reads the information needed for comparison. Hash-based comparison may read file contents. If the files change after a preview, the real run can produce different actions.

## NAS and cloud backup presets

Version 0.5.0 adds three presets to the operation menu. Selecting one applies settings; **it does not change the current locations or start a transfer**. Hide an unused preset with × and restore it later in Transfer Options.

| Preset | Concurrent transfers / checkers | Starting point |
| --- | ---: | --- |
| Computer → NAS | 1 / 10 | Reduce simultaneous file reads and writes; also disable multiple transfer streams within a file |
| NAS → Cloud | 1 / 10 | Reduce the number of files read from the NAS at once |
| Computer → Cloud | 4 / 8 | Allow concurrent file transfers, adjustable for the connection and service |

All three use **one-way sync, deletion during transfer and no deletion-count limit**. They compare **size and modification time, with local hashes disabled**. These are editable starting points, not measured optimal settings for every NAS. One transfer at a time also cannot guarantee unfragmented disk allocation.

A Finder-mounted SMB share appears to rclone as a local filesystem. Disabling local hashes avoids reading an entire file over the network solely to calculate a hash. The tradeoff is that **content changes preserving both size and time can be missed, and the local endpoint no longer participates in post-transfer content-hash verification**. Inconsistent timestamps may also cause unchanged contents to be transferred again. The setting affects the local backend; it does not disable every cloud backend's hashing capabilities. See [NAS comparison and tradeoffs (Traditional Chinese)](docs/NAS_COMPARISON.zh-TW.md).

Presets exclude these specific Mac items: `.DS_Store`, `._*`, `.Spotlight-V100`, `.Trashes`, `.fseventsd` and `.TemporaryItems`. They do not exclude all hidden files. AppleDouble `._*` files can contain resource forks or other Mac metadata; remove that rule when you need to preserve them.

Changed data sent from a NAS to the cloud, or between different cloud services, normally still passes through the Mac running rclone. Direct server-side copying depends on backend support. Avoiding extra hash reads does not change the actual data path. See [rclone's cross-service transfer explanation](https://rclone.org/faq/#can-rclone-sync-directly-from-drive-to-s3).

When upgrading to 0.5.0, **saved tasks and remembered workspaces retain their existing options**. Edit and save a task to adopt a new preset.

## Interface and progress changes in 0.5.0

- **More compact folder navigation:** the selected tab joins the content surface; location, path and navigation controls share one row. Each tab has independent back and forward history.
- **Notifications leave the layout in place:** directory errors contain the icon, explanation and retry action in one card. Temporary notices float above the interface, dismiss after about five seconds and can be closed manually. Empty Tasks show a prompt to add a task.
- **Speed estimates from byte progress:** the app uses existing statistics to estimate a rolling 60-second average, retains the overall average on completion and shows percentages to one decimal place.

The speed estimate adds no file scans, reads or hashing. It represents bytes processed per second; macOS system copies, APFS operations and server-side copies do not necessarily correspond to network traffic. Remaining time is approximate and can change during small-file transfers, checks, deletions or ongoing directory discovery. [Technical basis (Traditional Chinese)](docs/RESEARCH_0.5.0.md) · [Full changelog (Traditional Chinese)](docs/CHANGELOG.zh-TW.md)

## Separate engine and app updates

| Menu action | Update behavior |
| --- | --- |
| Check rclone updates | Check the official stable release, then download, verify and replace the engine at the selected location after confirmation; supports startup checks, postponing and skipping a version |
| Check Rclone Next updates | Check this project's published GitHub releases and offer version information and a download page; it does not overwrite the running app |

Selecting a new rclone location immediately saves it, detects the version and refreshes the interface. Before replacement, the updater checks the downloaded version and Mac compatibility and backs up the existing executable. On failure it preserves or restores the old version. Updating rclone does not require rebuilding the app. Proxy support and updater limitations are covered in [Settings (Traditional Chinese)](README.zh-TW.md#設定).

## Development and verification

Ordinary use only requires building the Mac app. Editing the interface uses the tools in `WebSource`, with dependencies pinned in `package-lock.json`; app builds use the prebuilt `Resources/Web`. See [Development](docs/DEVELOPMENT.md).

The current 0.5.0 validation includes **101 Swift tests on Linux** and **86 distinct UI cases**. Tests use isolated files, rclone test directories and simulated native messages, without private cloud accounts. These results do not establish native Mac UI behavior or compatibility with a particular NAS or cloud account; **this version's 0.5.0 macOS CI results are still pending**. Platforms, scope and current results are recorded in [Validation (Traditional Chinese)](docs/VALIDATION.zh-TW.md).

To run the suites on your own Mac, use `Test-on-Mac.command` and provide the path to rclone. Cases requiring a real engine are reported as skipped if no usable executable is supplied.

## Author, acknowledgments and license

Author: **Jason Chen**. Released under the [MIT License](LICENSE). Jason Chen supplied the app icon.

[rclone](https://rclone.org/) provides the storage connections and transfer engine. [mmozeiko/RcloneBrowser](https://github.com/mmozeiko/RcloneBrowser), [kapitainsky/RcloneBrowser](https://github.com/kapitainsky/RcloneBrowser) and [RcloneBrowser2](https://github.com/downer08tutti/RcloneBrowser2) informed the workflows and feature inventory. Next is an independent implementation with a Swift/AppKit host and React interface. See the [feature comparison (Traditional Chinese)](docs/FEATURE_MATRIX.zh-TW.md) for retained behavior and differences.

ForkLift informed the dual-pane interactions and layout; its code and private resources are not distributed here. Third-party frontend notices accompany the [web resources](Resources/Web/THIRD_PARTY_NOTICES.txt).
