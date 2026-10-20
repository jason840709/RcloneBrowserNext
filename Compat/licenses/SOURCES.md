# Original runtime license texts

- Swift 6.1.2: <https://github.com/swiftlang/swift/blob/swift-6.1.2-RELEASE/LICENSE.txt>
- Foundation 6.1.2: <https://github.com/swiftlang/swift-corelibs-foundation/blob/swift-6.1.2-RELEASE/LICENSE>
- libdispatch 6.1.2: <https://github.com/swiftlang/swift-corelibs-libdispatch/blob/swift-6.1.2-RELEASE/LICENSE>
- ICU 74.2: <https://github.com/unicode-org/icu/blob/release-74-2/LICENSE>
- curl: <https://github.com/curl/curl/blob/curl-8_7_1/COPYING>
- libxml2: <https://github.com/GNOME/libxml2/blob/v2.12.6/Copyright>
- zlib: <https://github.com/madler/zlib/blob/v1.3.1/LICENSE>

These are license references, not a statement that every library listed is
copied into every package. `runtime-manifest.json` lists the libraries actually
included by the platform build. Linux uses its distribution's curl, libxml2,
zlib and ICU libraries where the official Swift toolchain links to them.
