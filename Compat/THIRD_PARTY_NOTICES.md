# Package components and licenses

The Windows and Linux applications use Tauri and the system webview. All three
platforms use the Rust transfer engine and the bundled web interface. Jason Chen
and the Rclone Browser Next contributors maintain this application. The original
Rclone Browser was developed by Mārtiņš Možeiko and maintained by kapitainsky.
Project credits are in the repository README.

## Included components

- **Rust packages, including Tauri, Wry, Tao, dialog and clipboard bindings:**
  the build retains the original license texts from the pinned Cargo packages
  in `licenses/rust/`. `licenses/rust-packages.json` records their versions,
  authors, license identifiers and source locations, including build dependencies.
  The unmodified Servo selectors build dependency uses MPL 2.0; its source is at
  the recorded crate URL and <https://github.com/servo/stylo>.
- **Sorting and string-comparison source:** the Rust implementations include
  translations of the Swift 6.1.2 stable sorting algorithm and, on Windows and
  Linux, CoreFoundation string comparison with fixed character tables and Unicode
  15.1 data. `licenses/ported-source-notices.json` identifies the source and the
  original notices in `licenses/source/`. These algorithms use the Apache 2.0
  license with the Swift runtime library exception and the applicable Unicode
  data license. The engine runs without Swift or Foundation runtime libraries.
- **Bundled web interface:** the original React and other dependency notices are
  in `licenses/Web-THIRD-PARTY-NOTICES.txt`.

The upstream license texts are retained without modification. Source references
for these notices are in `Compat/licenses/SOURCES.md`; fallbacks for crates whose
published packages omit their license text are in `Compat/licenses/crates/sources.json`.

## System components

Windows uses Microsoft Edge WebView2. If the Evergreen runtime is missing, the
installer offers Microsoft's official bootstrapper. Its terms are available at
<https://developer.microsoft.com/microsoft-edge/webview2/>.

Windows and Linux use their system ICU C interface for Unicode collation. Linux
also uses the distribution's WebKitGTK, GTK, GLib and other system libraries. The
Debian package declares its required system packages. Those libraries remain
managed by the operating system; their notices and source packages are supplied
by that system or distribution.

rclone is selected or installed separately through the application settings.
Nick Craig-Wood and the rclone contributors maintain it under the MIT license:
<https://github.com/rclone/rclone>.
