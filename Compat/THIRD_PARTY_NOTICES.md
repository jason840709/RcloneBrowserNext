# Compatibility package components

The Windows and Linux windows use Tauri and the system webview. They run the
same Swift transfer engine and bundled web interface as the Mac application.
Jason Chen and the Rclone Browser Next contributors maintain this application.
The original Rclone Browser was developed by Mārtiņš Možeiko and maintained by
kapitainsky. Project history and credits are in the main repository README.

## Included components

- **Tauri, Wry, Tao, dialog and clipboard bindings:** MIT or Apache 2.0. The
  release build retains original license texts from the pinned Cargo packages
  in `licenses/rust/`; `licenses/rust-packages.json` records their versions,
  authors, license identifiers and source locations. This includes build
  dependencies as well as runtime dependencies. The unmodified Servo selectors
  build dependency uses MPL 2.0; its source is available at the recorded crate
  URL and <https://github.com/servo/stylo>.
- **Swift, Foundation and libdispatch runtime libraries:** Apache 2.0 with the
  Swift runtime library exception. Their license texts are in `licenses/`.
  The build copies the dependent runtime libraries, not the compiler or SDK.
- **ICU:** Unicode license and included third-party notices. **libcurl,
  libxml2 and zlib:** their respective permissive licenses. License texts are
  in `licenses/` for the runtime components used by Swift. The exact copied
  library filenames and checksums are recorded in `runtime-manifest.json`.
- **React and other bundled web interface dependencies:** see
  `licenses/Web-THIRD-PARTY-NOTICES.txt` for the original notices.

The upstream license texts are retained without modification. Runtime libraries
are copied from the official Swift toolchain. The versioned runtime source
license references used in this repository are recorded in
`licenses/SOURCES.md`; fallbacks for crates that omit their license text from
the published crate are recorded in `licenses/crates/sources.json`.

## System components

Windows uses Microsoft Edge WebView2. If the Evergreen runtime is missing,
the installer offers Microsoft's official bootstrapper. This application does
not include a copy of Chromium or a fixed WebView2 runtime. Microsoft runtime
components are subject to their own terms:
<https://developer.microsoft.com/microsoft-edge/webview2/>.

Linux links to the distribution's WebKitGTK, GTK, GLib and other system
libraries. The Debian package declares its required system packages. Those
libraries remain managed by the distribution; their notices and source packages
are provided through that distribution.

rclone is selected or installed separately through the application settings.
It is maintained by Nick Craig-Wood and the rclone contributors under the MIT
license: <https://github.com/rclone/rclone>.
