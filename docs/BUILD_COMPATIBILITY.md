# Windows and Linux compatibility builds

macOS is the primary platform. The compatibility editions reuse the bundled web interface and Swift transfer core, hosted by Tauri with the system webview. Windows includes the native filesystem adapter validated in 0.9.0 revision 1. The editions provide browsing, copy, one-way sync, move, dry run, saved tasks and transfer reports.

## Install

- **Windows x64:** use [0.9.1](https://github.com/jason840709/RcloneBrowserNext/releases/tag/v0.9.1) and run `Rclone_Browser_Next_0.9.1_Windows_x64_Setup.exe`. Installation is per user and preserves existing application settings. If WebView2 is absent, the installer downloads Microsoft's official Evergreen bootstrapper. The installer includes the Swift runtime; Swift, Rust and Node.js are not needed to run the app.
- **Ubuntu 24.04 amd64:** install `Rclone_Browser_Next_0.9.1_Linux_amd64.deb` with your package installer or `sudo apt install ./Rclone_Browser_Next_0.9.1_Linux_amd64.deb`. The package includes Swift runtime libraries and declares its WebKitGTK, GTK, ICU and other system dependencies. Other distributions require matching dependencies or a source build.

In Settings, choose an existing rclone executable or an installation folder for the app's rclone downloader. Account setup opens rclone's interactive configuration in a terminal. Existing rclone configuration files can be selected directly.

Mac-specific Finder integration, status-bar controls and mount integration are available in the macOS edition. The compatibility editions focus on the file-transfer workflow. Windows packages do not have an Authenticode signature; macOS packages use ad-hoc signatures. Release checksums are supplied separately.

## Build

Use `Rclone_Browser_Next_0.9.1_Source.zip` from the same release, or check out tag `v0.9.1`. The package includes the prebuilt web interface and all platform build scripts.

The release workflow pins Swift 6.1.2 and Rust 1.90.0. JavaScript build tooling is pinned in `Compat/cli/package-lock.json`; Rust dependencies are pinned in `Compat/desktop/Cargo.lock`. Generated files and caches stay in `.build-cache/compat`.

Windows builds require x64 MSVC, the x64 Swift toolchain, Rust, Python and Node.js. Run `Scripts/build-compat-windows.ps1` in the x64 developer environment. Its native process launcher supports both cancellable transfer processes and interactive account configuration.

Linux builds require Swift, Rust, Python, Node.js, pkg-config, patchelf and WebKitGTK/GTK development packages. Run `bash Scripts/build-compat-linux.sh`. The CI workflow lists the Ubuntu packages needed for compilation.

Both scripts package only redistributable runtime dependencies, retain their licenses and write a runtime manifest. See [third-party notices](../Compat/THIRD_PARTY_NOTICES.md).

## Verification

The [unified desktop workflow](../.github/workflows/macos.yml) builds all platforms. A separate clean Windows runner installs the exact built package, verifies filesystem and WebView2 behavior, and checks upgrades from both published 0.9.0 and Windows r1. The shared release job requires every platform and upgrade job to pass. Windows inherits the same version as Mac and Linux; there is no separate revision override. [Historical Windows repair evidence](WINDOWS_0.9.0_R1.md).

Mac, Windows and Linux now use stable 0.9.1. The old Windows R1 prerelease remains available as historical material; new installations and upgrades should use the unified release. The stable update checker can discover 0.9.1 on all platforms.

The workflow builds installers on `windows-2025` and `ubuntu-24.04`. It runs platform file-operation checks, local copy/sync and cancellation through the packaged Swift helper, then opens the native window and checks the production interface bridge. These checks use isolated local fixtures. The macOS edition has its own full native core and WebKit test suites.

Test and package receipts are retained as workflow artifacts. [GitHub Actions](https://github.com/jason840709/RcloneBrowserNext/actions) is the source for each run's result.
