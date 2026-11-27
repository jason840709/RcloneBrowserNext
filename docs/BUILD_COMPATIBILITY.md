# Windows and Linux compatibility builds

macOS is the primary platform. All editions use the same Rust transfer engine and bundled web interface. Windows and Linux host the interface in Tauri with the system webview; macOS retains its Swift AppKit and WebKit window. The editions provide browsing, copy, one-way sync, move, dry run, saved tasks and transfer reports.

## Install

The current public release is [0.11.0](https://github.com/jason840709/RcloneBrowserNext/releases/tag/v0.11.0). The package names below describe the 0.12.0 candidate. Its downloads will be available on the release page after publication.

- **Windows x64:** run `Rclone_Browser_Next_0.12.0_Windows_x64_Setup.exe` when it is available. Installation is per user and preserves existing application settings. If WebView2 is absent, the installer downloads Microsoft's official Evergreen bootstrapper. The app does not bundle Swift. Swift, Rust and Node.js are not needed to run it.
- **Ubuntu 24.04 amd64:** install `Rclone_Browser_Next_0.12.0_Linux_amd64.deb` with your package installer or `sudo apt install ./Rclone_Browser_Next_0.12.0_Linux_amd64.deb`. The package declares its WebKitGTK, GTK and native system dependencies and does not bundle Swift. Other distributions require matching dependencies or a source build.

In Settings, choose an existing rclone executable or an installation folder for the app's rclone downloader. Account setup defaults to a short form followed by browser login, with a detailed form for custom options; the adjacent `config` link opens the traditional terminal configuration. Existing rclone configuration files can be selected directly.

Mac-specific Finder integration, status-bar controls and mount integration are available in the macOS edition. The compatibility editions focus on the file-transfer workflow. Windows packages do not have an Authenticode signature; macOS packages use ad-hoc signatures. Release checksums are supplied separately.

## Build

Use the candidate source, or `Rclone_Browser_Next_0.12.0_Source.zip` and tag `v0.12.0` after publication. The source package includes the prebuilt web interface and all platform build scripts.

The release workflow pins Rust 1.90.0 on all three platforms and builds with `--locked`. Rust dependencies are pinned in `Sources/Rust/Cargo.lock` and `Compat/desktop/Cargo.lock`; JavaScript build tooling is pinned in `Compat/cli/package-lock.json`. Windows and Linux build products and caches stay in `.build-cache/compat`. Mac products and logs stay in `.build/mac`, with temporary files in `.tmp`.

Windows builds require x64 MSVC, a compatible LLVM `clang-cl` (from Visual Studio or a standalone LLVM installation), CMake 3.24 or later, Ninja, Rust, Python and Node.js. The ICU dependency uses `clang-cl` with the MSVC ABI, linker and SDK; the existing C process launcher still uses `cl.exe`. The script checks the active MSVC headers and installed LLVM compiler versions before choosing a compatible compiler. It requires an existing LLVM toolchain and does not install one or use a compiler from a Swift toolchain. Run `Scripts/build-compat-windows.ps1` in the x64 developer environment. The script downloads the SHA-256-pinned ICU 74.1 source archive into the project cache and builds a private C++ `RBNUnicode.dll`, including its matching Unicode collation data. This avoids sorting changes caused by different Windows system ICU versions. The build rejects an archive, exported API or ICU version that does not match its source pin. The unchanged C process launcher supports both cancellable transfer processes and interactive account configuration. A Swift toolchain is not required.

Linux builds require Rust, Python, Node.js, pkg-config, patchelf and WebKitGTK/GTK development packages. Run `bash Scripts/build-compat-linux.sh`. The CI workflow lists the Ubuntu packages needed for compilation. A Swift toolchain is not required.

Mac builds require the Apple command line tools, a macOS SDK, Rust and Python. Run `bash Scripts/build-mac.sh --no-launch`; it builds the Swift window and Rust engine into the same signed App bundle. The Swift window keeps the existing SDK 15.0 link setting for its toolbar appearance.

The Windows and Linux scripts package only the required redistributable native runtime dependencies, retain their licenses and write a runtime manifest. Unused Swift runtime libraries and their license files are excluded. The separately required ICU library and translated algorithms retain their original licenses. See [third-party notices](../Compat/THIRD_PARTY_NOTICES.md).

## Verification

The [unified desktop workflow](../.github/workflows/macos.yml) builds all platforms. A separate clean Windows runner installs the exact built package, verifies filesystem and WebView2 behavior, and checks upgrades from every published Windows stable version through 0.11.0: 0.7.0, 0.8.0, 0.8.1, 0.9.0, 0.9.1, 0.9.2, 0.9.3, 0.9.4, 0.9.5, 0.9.6, 0.10.1, 0.10.2, 0.10.3, 0.10.4, 0.10.6 and 0.11.0. The historical Windows 0.9.0-r1 prerelease is checked as well. Each baseline is pinned by release ID, asset ID, byte count and SHA-256. The shared release job requires every platform and upgrade job to pass. Windows inherits the same version as Mac and Linux; there is no separate revision override. [Historical Windows repair evidence](WINDOWS_0.9.0_R1.md).

The 0.12.0 candidate requires a complete passing workflow before publication. Pushes to `work/0.12.0` run the checks without publishing; publication requires a push to `main` after every required job passes. The old Windows R1 prerelease remains available as historical material; new installations and upgrades should use the unified stable release. The update checker finds new releases on all platforms.

The workflow builds installers on `windows-2025` and `ubuntu-24.04` without installing Swift. Rust tests cover the original core cases, including platform file operations, account configuration and listing cancellation with real rclone processes. Windows filesystem behavior is guarded by these tests and the installed filesystem and mutation probes; removed Swift files are no longer fingerprinted as unchanged. The unchanged Windows C launcher's fingerprint is still checked. Local copy/sync and cancellation also run through the packaged Rust engine, followed by native window and interface bridge checks. These checks use isolated local fixtures. The macOS edition retains its Swift native interface and local recovery suites alongside the Rust core tests.

Test and package receipts are retained as workflow artifacts. [GitHub Actions](https://github.com/jason840709/RcloneBrowserNext/actions) is the source for each run's result.
