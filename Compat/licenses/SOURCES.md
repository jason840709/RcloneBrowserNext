# Original source license texts

Current packages record the applied source notices in `ported-source-notices.json`
and the Cargo package notices in `rust-packages.json`.

- Swift 6.1.2 stable sorting, translated to Rust: <https://github.com/swiftlang/swift/blob/swift-6.1.2-RELEASE/LICENSE.txt>
- CoreFoundation 6.1.2 string comparison and character tables, translated to Rust: <https://github.com/swiftlang/swift-corelibs-foundation/blob/swift-6.1.2-RELEASE/LICENSE>
- Unicode 15.1 character data and ICU notices: <https://github.com/unicode-org/icu/blob/release-74-2/LICENSE>

The two data generators in `Scripts/` verify the SHA-256 of every upstream input.
Their generated data and source manifests are stored beside the Rust comparison
module. System ICU supplies collation; its measured version is recorded separately
in platform test evidence.

## Historical 0.11.0 runtime references

The source archive retains these original license references:

- libdispatch 6.1.2: <https://github.com/swiftlang/swift-corelibs-libdispatch/blob/swift-6.1.2-RELEASE/LICENSE>
- curl 8.7.1: <https://github.com/curl/curl/blob/curl-8_7_1/COPYING>
- libxml2 2.12.6: <https://github.com/GNOME/libxml2/blob/v2.12.6/Copyright>
- zlib 1.3.1: <https://github.com/madler/zlib/blob/v1.3.1/LICENSE>
