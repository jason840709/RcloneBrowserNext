//! Preserved platform comparison and stable sorting for file/volume lists.
//!
//! On macOS this calls the same Foundation selector as Swift's
//! `String.localizedStandardCompare`. It deliberately does not approximate
//! localized/numeric ordering with lowercase or bytewise comparisons.
//! No AppKit object or main-thread access is involved.
use std::cmp::Ordering;

#[path = "platform_text/stable_sort.rs"]
mod stable_sort;
#[cfg(any(not(target_os = "macos"), test))]
#[path = "platform_text/comparison.rs"]
mod comparison;
#[cfg(any(not(target_os = "macos"), test))]
#[path = "platform_text/native_icu.rs"]
mod native_icu;

pub(crate) use stable_sort::swift_sort_by as stable_sort_by;

/// Each listing owns its immutable collators on the worker thread. Missing
/// system dependencies are returned before sorting instead of silently choosing
/// a different ordering policy.
pub(crate) struct NameOrder {
    #[cfg(not(target_os = "macos"))]
    icu: native_icu::Icu,
}
impl NameOrder {
    pub(crate) fn new() -> crate::Result<Self> {
        Ok(Self {
            #[cfg(not(target_os = "macos"))]
            icu: native_icu::Icu::new()?,
        })
    }
    pub(crate) fn compare(&self, a: &str, b: &str) -> Ordering {
        if a.as_bytes() == b.as_bytes() { return Ordering::Equal; }
        #[cfg(target_os = "macos")]
        { mac::compare(a, b).unwrap_or_else(|| a.cmp(b)) }
        #[cfg(not(target_os = "macos"))]
        {
            let a: Vec<u16> = a.encode_utf16().collect();
            let b: Vec<u16> = b.encode_utf16().collect();
            comparison::compare_utf16(&self.icu, &a, &b)
        }
    }
}

/// Foundation's current-locale Finder comparison on the native Mac target.
#[cfg(target_os = "macos")]
#[must_use]
pub fn natural_compare(a: &str, b: &str) -> Ordering {
    NameOrder::new().expect("native Foundation comparator").compare(a,b)
}

#[cfg(target_os = "macos")]
mod mac {
    use super::Ordering;
    use std::{ffi::{c_char, c_void}, ptr, sync::OnceLock};

    type Object = *const c_void;
    type Selector = *const c_void;
    const UTF8_ENCODING: u32 = 0x0800_0100;

    #[link(name = "Foundation", kind = "framework")]
    unsafe extern "C" {}

    #[link(name = "CoreFoundation", kind = "framework")]
    unsafe extern "C" {
        fn CFStringCreateWithBytes(allocator: Object, bytes: *const u8, length: isize,
                                   encoding: u32, external: u8) -> Object;
        fn CFRelease(value: Object);
    }

    #[link(name = "objc")]
    unsafe extern "C" {
        fn sel_registerName(name: *const c_char) -> Selector;
        fn objc_msgSend();
        fn objc_autoreleasePoolPush() -> *mut c_void;
        fn objc_autoreleasePoolPop(pool: *mut c_void);
    }

    struct Pool(*mut c_void);
    impl Drop for Pool {
        fn drop(&mut self) {
            if !self.0.is_null() {
                // SAFETY: This exact token was pushed on the current thread
                // below, and no outer/inner pool is popped out of order.
                unsafe { objc_autoreleasePoolPop(self.0) };
            }
        }
    }
    struct StringObject(Object);
    impl StringObject {
        fn new(value: &str) -> Option<Self> {
            let length = isize::try_from(value.len()).ok()?;
            // SAFETY: Rust str is valid UTF-8, and its pointer/byte length are
            // valid for this call. Create copies the bytes and returns +1.
            // A null allocator denotes CoreFoundation's default allocator.
            let object = unsafe {
                CFStringCreateWithBytes(ptr::null(), value.as_ptr(), length, UTF8_ENCODING, 0)
            };
            (!object.is_null()).then_some(Self(object))
        }
    }
    impl Drop for StringObject {
        fn drop(&mut self) {
            // SAFETY: new() accepts only non-null objects owned under CF's
            // Create rule; exactly this one +1 reference is released here.
            unsafe { CFRelease(self.0) };
        }
    }

    pub(super) fn compare(a: &str, b: &str) -> Option<Ordering> {
        // SAFETY: The Objective-C runtime permits a pool on any current
        // thread. The RAII value pops only this thread's matching token.
        let _pool = Pool(unsafe { objc_autoreleasePoolPush() });
        let left = StringObject::new(a)?;
        let right = StringObject::new(b)?;
        static SELECTOR: OnceLock<usize> = OnceLock::new();
        let selector = *SELECTOR.get_or_init(|| {
            // SAFETY: The selector is a static NUL-terminated C string. Its
            // interned runtime result has process lifetime and is immutable.
            unsafe { sel_registerName(c"localizedStandardCompare:".as_ptr()) as usize }
        }) as Selector;
        if selector.is_null() {
            return None;
        }
        type CompareMessage = unsafe extern "C" fn(Object, Selector, Object) -> isize;
        // SAFETY: CFString is toll-free bridged to NSString. Both receivers
        // remain owned immutable strings for the call. This Foundation method
        // takes one NSString* and returns NSComparisonResult (NSInteger/isize)
        // on both supported Mac ABIs; no struct-return dispatcher is needed.
        let send: CompareMessage = unsafe { std::mem::transmute(objc_msgSend as unsafe extern "C" fn()) };
        // SAFETY: The typed ABI and the lifetime/type of all three arguments
        // are established immediately above; no borrowed pointer escapes.
        let result = unsafe { send(left.0, selector, right.0) };
        Some(result.cmp(&0))
    }
}

#[cfg(all(test, target_os = "macos"))]
mod tests {
    use super::*;
    #[test]
    fn finder_order_matches_swift_oracle() {
        let captured = include_str!("../../../Tests/fixtures/mac-text-comparison-swift.json");
        let oracle: serde_json::Value = serde_json::from_str(captured).expect("recorded Swift oracle JSON");
        let cases = oracle["cases"].as_array().expect("oracle cases");
        assert!(cases.len() >= 20, "numeric, Unicode and case coverage");
        for case in cases {
            let left = case["left"].as_str().expect("oracle left");
            let right = case["right"].as_str().expect("oracle right");
            let expected = case["result"].as_i64().expect("oracle result");
            let actual = match natural_compare(left, right) {
                Ordering::Less => -1,
                Ordering::Equal => 0,
                Ordering::Greater => 1,
            };
            assert_eq!(actual, expected, "Foundation comparison {left:?} / {right:?}");
        }
    }
}


#[cfg(test)]
mod portable_tests {
    use super::*;
    use serde_json::Value;

    #[test]
    fn frozen_windows_0_11_order_is_strict_in_both_directions() {
        let data: Value = serde_json::from_str(include_str!(
            "../../../Tests/fixtures/windows-foundation-0.11.0-order.json"
        )).expect("captured old Windows result");
        assert_eq!(data["oldHelperSha256"], "7ec33a6b5e108d601e3d3c339be43e7502256624b48f5ed6a1a992bc135bd32f");
        let entries = data["expectedOrderedEntries"].as_array().unwrap();
        assert_eq!(entries.len(), 34);
        let icu = native_icu::Icu::new().expect("native ICU C interface");
        println!("native ICU test backend: {}", icu.versions());
        let mut compared = 0;
        for (i, a) in entries.iter().enumerate() {
            let left: Vec<u16> = a["name"].as_str().unwrap().encode_utf16().collect();
            assert_eq!(comparison::compare_utf16(&icu, &left, &left), Ordering::Equal);
            for b in &entries[i + 1..] {
                if a["isDirectory"] != b["isDirectory"] { continue; }
                let right: Vec<u16> = b["name"].as_str().unwrap().encode_utf16().collect();
                assert_eq!(comparison::compare_utf16(&icu, &left, &right), Ordering::Less,
                           "old Windows order {:?} / {:?}", a["name"], b["name"]);
                assert_eq!(comparison::compare_utf16(&icu, &right, &left), Ordering::Greater,
                           "reverse old Windows order {:?} / {:?}", a["name"], b["name"]);
                compared += 2;
            }
        }
        assert_eq!(compared, 832);
    }

    #[test]
    fn stable_sort_matches_all_54_captured_swift_permutations() {
        let data: Value = serde_json::from_str(include_str!(
            "../../../Tests/fixtures/swift-0.11.0-sort-permutations.json"
        )).expect("actual old Swift sorting results");
        assert_eq!(data["oldHelperSha256"], "f1acfcbcde43a1096dd3e75ec6687889d35db92dad473a6e74487b0ff679ad81");
        let cases = data["cases"].as_array().unwrap();
        assert_eq!(cases.len(), 54);
        let comparator = NameOrder::new().expect("platform comparison");
        for case in cases {
            let names = case["inputNames"].as_array().unwrap();
            let expected: Vec<usize> = case["expectedIndices"].as_array().unwrap()
                .iter().map(|v| usize::try_from(v.as_u64().unwrap()).unwrap()).collect();
            assert_eq!(names.len(), expected.len());
            let mut index: Vec<usize> = (0..names.len()).collect();
            stable_sort_by(&mut index, |a,b| comparator.compare(
                names[*a].as_str().unwrap(), names[*b].as_str().unwrap()));
            assert_eq!(index, expected, "old Swift permutation case {}", case["id"]);
        }
    }

    #[test]
    fn original_numeric_cycle_is_preserved_without_a_standard_sort_panic() {
        let comparator = NameOrder::new().expect("platform comparison");
        let names = ["x18446744073709551616", "x1", "X2"];
        assert_eq!(comparator.compare(names[0], names[1]), Ordering::Less);
        assert_eq!(comparator.compare(names[1], names[2]), Ordering::Less);
        assert_eq!(comparator.compare(names[2], names[0]), Ordering::Less);
        let mut values = names.to_vec();
        stable_sort_by(&mut values, |a,b| comparator.compare(a,b));
        assert_eq!(values, names);
    }
}
