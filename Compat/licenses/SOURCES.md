# Original source license texts

Current packages record the applied source notices in `ported-source-notices.json`
and the Cargo package notices in `rust-packages.json`.

- Swift 6.1.2 stable sorting, translated to Rust: <https://github.com/swiftlang/swift/blob/swift-6.1.2-RELEASE/LICENSE.txt>
- CoreFoundation 6.1.2 string comparison and character tables, translated to Rust: <https://github.com/swiftlang/swift-corelibs-foundation/blob/swift-6.1.2-RELEASE/LICENSE>
- Unicode 15.1 character data and ICU notices: <https://github.com/unicode-org/icu/blob/release-74-2/LICENSE>

The two data generators in `Scripts/` verify the SHA-256 of every upstream input.
Their generated data and source manifests are stored beside the Rust comparison
module. Linux uses the distribution ICU 74. Windows bundles a private C++ ICU 74.1
from `swiftlang/swift-foundation-icu` at commit
`7e255a994ec26a08214f8fea2fdaf60b296e1f22`, tagged `swift-6.1.2-RELEASE`. The
source archive and required exports are pinned in `Scripts/windows/icu-source.json`.
The library is built without Swift and contains its original collation data.
Its unmodified package license is [ICU-74.1-PACKAGE-LICENSE.txt](ICU-74.1-PACKAGE-LICENSE.txt),
from the [pinned upstream package](https://github.com/swiftlang/swift-foundation-icu/blob/7e255a994ec26a08214f8fea2fdaf60b296e1f22/LICENSE.md).
The [ICU 74.1 upstream license](https://github.com/unicode-org/icu/blob/release-74-1/LICENSE)
is retained as [ICU-74.1-LICENSE.txt](ICU-74.1-LICENSE.txt). Actual library hashes and
versions are recorded separately in platform build and test evidence.

## Historical 0.11.0 runtime references

The source archive retains these original license references:

- libdispatch 6.1.2: <https://github.com/swiftlang/swift-corelibs-libdispatch/blob/swift-6.1.2-RELEASE/LICENSE>
- curl 8.7.1: <https://github.com/curl/curl/blob/curl-8_7_1/COPYING>
- libxml2 2.12.6: <https://github.com/GNOME/libxml2/blob/v2.12.6/Copyright>
- zlib 1.3.1: <https://github.com/madler/zlib/blob/v1.3.1/LICENSE>
