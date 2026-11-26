//! Platform text comparison used by the preserved Mac file/volume lists.
//!
//! On macOS this calls the same Foundation selector as Swift's
//! `String.localizedStandardCompare`. It deliberately does not approximate
//! localized/numeric ordering with lowercase or bytewise comparisons.
//! No AppKit object or main-thread access is involved.
use std::cmp::Ordering;

/// Compare using Foundation's current-locale Finder ordering on macOS.
///
/// Non-Mac targets use a deterministic literal fallback only; that fallback is
/// **not** claimed equivalent to Swift/Foundation. Existing Windows/Linux
/// sorters should remain in use. An allocation failure on Mac also returns the
/// literal fallback rather than panicking or dereferencing a null CF object.
#[must_use]
pub fn natural_compare(a: &str, b: &str) -> Ordering {
    if a.as_bytes() == b.as_bytes() {
        return Ordering::Equal;
    }
    #[cfg(target_os = "macos")]
    if let Some(result) = mac::compare(a, b) {
        return result;
    }
    a.cmp(b)
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
