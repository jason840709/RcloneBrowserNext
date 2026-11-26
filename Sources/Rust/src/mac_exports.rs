//! The preserved Mac host's NSFileManager export operation, without AppKit.
//! This intentionally retains Foundation's copy/replace metadata and symlink
//! semantics. It does not add source/destination rejection or stream a new file.
#[cfg(target_os = "macos")]
pub fn copy_export(source: &std::path::Path, destination: &std::path::Path) -> crate::Result<()> {
    mac::copy_export(source, destination)
}

/// Read the exact three NSURL resource flags used by the old Finder drop
/// parser. The caller retains its original ordering of path/name validation.
#[cfg(target_os = "macos")]
pub fn finder_kind(path: &std::path::Path) -> crate::Result<(bool, bool, bool)> {
    mac::finder_kind(path)
}

#[cfg(target_os = "macos")]
mod mac {
    use std::{ffi::{c_char, c_void}, path::Path, ptr};
    type Object = *const c_void;
    type Selector = *const c_void;
    type Bool = i8; // Objective-C BOOL return register on both supported Mac ABIs.
    #[link(name = "Foundation", kind = "framework")]
    unsafe extern "C" {
        static NSURLIsDirectoryKey: Object;
        static NSURLIsSymbolicLinkKey: Object;
        static NSURLIsRegularFileKey: Object;
    }
    #[link(name = "CoreFoundation", kind = "framework")]
    unsafe extern "C" {
        fn CFStringCreateWithBytes(allocator: Object, bytes: *const u8, length: isize, encoding: u32, external: u8) -> Object;
        fn CFRelease(value: Object);
    }
    #[link(name = "objc")]
    unsafe extern "C" {
        fn objc_getClass(name: *const c_char) -> Object;
        fn sel_registerName(name: *const c_char) -> Selector;
        fn objc_msgSend();
        fn objc_autoreleasePoolPush() -> *mut c_void;
        fn objc_autoreleasePoolPop(pool: *mut c_void);
    }
    // Every invocation below states its exact signature from Apple's installed
    // NSFileManager/NSURL/NSString headers. There are no struct return values.
    macro_rules! send {
        ($signature:ty, $receiver:expr, $selector:literal $(, $argument:expr)* $(,)?) => {{
            // SAFETY: The selector is a static C literal; the signature at each
            // call matches that selector's documented Objective-C ABI.
            let method: $signature = unsafe { std::mem::transmute(objc_msgSend as unsafe extern "C" fn()) };
            // SAFETY: All receivers/arguments are live Foundation objects from
            // this autorelease pool, or the method's permitted nil/out values.
            unsafe { method($receiver, sel_registerName($selector.as_ptr()), $($argument),*) }
        }};
    }
    struct Pool(*mut c_void);
    impl Drop for Pool {
        fn drop(&mut self) {
            // SAFETY: The token was pushed on this same thread and is popped
            // after every object/cleanup created inside this scope is done.
            unsafe { objc_autoreleasePoolPop(self.0) };
        }
    }
    struct StringObject(Object);
    impl StringObject {
        fn new(text: &str) -> crate::Result<Self> {
            let length = isize::try_from(text.len()).map_err(|e| e.to_string())?;
            // SAFETY: The bytes are valid UTF-8 for the supplied byte length.
            // CF copies them; a null allocator requests its default allocator.
            let object = unsafe { CFStringCreateWithBytes(ptr::null(), text.as_ptr(), length, 0x0800_0100, 0) };
            if object.is_null() { Err("Unable to allocate a Foundation path.".into()) } else { Ok(Self(object)) }
        }
    }
    impl Drop for StringObject {
        fn drop(&mut self) {
            // SAFETY: CFStringCreateWithBytes returned this nonnull +1 object.
            unsafe { CFRelease(self.0) };
        }
    }
    fn error_text(error: Object) -> String {
        if !error.is_null() {
            let description = send!(unsafe extern "C" fn(Object, Selector) -> Object, error, c"localizedDescription");
            let bytes = send!(unsafe extern "C" fn(Object, Selector) -> *const c_char, description, c"UTF8String");
            if !bytes.is_null() {
                let length = send!(unsafe extern "C" fn(Object, Selector, usize) -> usize,
                    description, c"lengthOfBytesUsingEncoding:", 4); // NSUTF8StringEncoding
                // SAFETY: NSString reports this UTF-8 byte length and keeps its
                // buffer alive until the pool drains. Explicit length also
                // preserves embedded NUL characters in a system error string.
                let text = unsafe { std::slice::from_raw_parts(bytes.cast::<u8>(), length) };
                return String::from_utf8_lossy(text).into_owned();
            }
        }
        "檔案操作失敗。".into() // Foundation filesystem methods normally provide NSError.
    }
    pub(super) fn finder_kind(path: &Path) -> crate::Result<(bool, bool, bool)> {
        // SAFETY: This thread owns the matching pool until every temporary URL,
        // array, dictionary, NSNumber and NSError has been consumed.
        let _pool = Pool(unsafe { objc_autoreleasePoolPush() });
        let text = StringObject::new(&path.to_string_lossy())?;
        // SAFETY: These linked Foundation classes have process lifetime.
        let url_class = unsafe { objc_getClass(c"NSURL".as_ptr()) };
        // SAFETY: NSArray is also provided by the linked Foundation framework.
        let array_class = unsafe { objc_getClass(c"NSArray".as_ptr()) };
        let url = send!(unsafe extern "C" fn(Object, Selector, Object) -> Object,
            url_class, c"fileURLWithPath:", text.0);
        // SAFETY: NSURL resource key constants are immutable NSString objects
        // owned by Foundation for process lifetime.
        let keys = unsafe { [NSURLIsDirectoryKey, NSURLIsSymbolicLinkKey, NSURLIsRegularFileKey] };
        let array = send!(unsafe extern "C" fn(Object, Selector, *const Object, usize) -> Object,
            array_class, c"arrayWithObjects:count:", keys.as_ptr(), keys.len());
        let mut error: Object = ptr::null();
        let values = send!(unsafe extern "C" fn(Object, Selector, Object, *mut Object) -> Object,
            url, c"resourceValuesForKeys:error:", array, &mut error);
        if values.is_null() { return Err(error_text(error)); }
        let flag = |key| {
            let number = send!(unsafe extern "C" fn(Object, Selector, Object) -> Object,
                values, c"objectForKey:", key);
            // Messaging nil returns false, matching URLResourceValues' optional
            // flags compared with true in the original Swift implementation.
            send!(unsafe extern "C" fn(Object, Selector) -> Bool, number, c"boolValue") != 0
        };
        Ok((flag(keys[0]), flag(keys[1]), flag(keys[2])))
    }
    fn item_operation(manager: Object, source: Object, target: Object, copy: bool) -> crate::Result<()> {
        let mut error: Object = ptr::null();
        let success = if copy {
            send!(unsafe extern "C" fn(Object, Selector, Object, Object, *mut Object) -> Bool,
                  manager, c"copyItemAtURL:toURL:error:", source, target, &mut error)
        } else {
            send!(unsafe extern "C" fn(Object, Selector, Object, Object, *mut Object) -> Bool,
                  manager, c"moveItemAtURL:toURL:error:", source, target, &mut error)
        };
        if success != 0 { Ok(()) } else { Err(error_text(error)) }
    }
    struct RemoveStaging { manager: Object, url: Object }
    impl Drop for RemoveStaging {
        fn drop(&mut self) {
            // Exactly the original defer { try? fm.removeItem(at: staging) }.
            let _ = send!(unsafe extern "C" fn(Object, Selector, Object, *mut Object) -> Bool,
                          self.manager, c"removeItemAtURL:error:", self.url, ptr::null_mut());
        }
    }
    pub(super) fn copy_export(source: &Path, destination: &Path) -> crate::Result<()> {
        // SAFETY: Cocoa Foundation operations may run on a worker thread with
        // its own autorelease pool. No AppKit/main-thread API is used here.
        let _pool = Pool(unsafe { objc_autoreleasePoolPush() });
        // Mac host paths originate as Swift/JSON UTF-8 strings. The lossy case
        // only represents an otherwise unrepresentable non-UTF-8 Path caller.
        let source_text = StringObject::new(&source.to_string_lossy())?;
        let destination_text = StringObject::new(&destination.to_string_lossy())?;
        // SAFETY: Both names are static C strings and Foundation is linked.
        let manager_class = unsafe { objc_getClass(c"NSFileManager".as_ptr()) };
        // SAFETY: NSURL is a linked Foundation class with process lifetime.
        let url_class = unsafe { objc_getClass(c"NSURL".as_ptr()) };
        let manager = send!(unsafe extern "C" fn(Object, Selector) -> Object, manager_class, c"defaultManager");
        let source_url = send!(unsafe extern "C" fn(Object, Selector, Object) -> Object, url_class, c"fileURLWithPath:", source_text.0);
        let destination_url = send!(unsafe extern "C" fn(Object, Selector, Object) -> Object, url_class, c"fileURLWithPath:", destination_text.0);
        let parent = send!(unsafe extern "C" fn(Object, Selector) -> Object, destination_url, c"URLByDeletingLastPathComponent");
        let leaf = StringObject::new(&format!(".rbn-export-{}", uuid::Uuid::new_v4().to_string().to_uppercase()))?;
        let staging = send!(unsafe extern "C" fn(Object, Selector, Object) -> Object, parent, c"URLByAppendingPathComponent:", leaf.0);
        let _remove = RemoveStaging { manager, url: staging };
        item_operation(manager, source_url, staging, true)?;
        let path = send!(unsafe extern "C" fn(Object, Selector) -> Object, destination_url, c"path");
        let exists = send!(unsafe extern "C" fn(Object, Selector, Object) -> Bool, manager, c"fileExistsAtPath:", path);
        if exists != 0 {
            let mut error: Object = ptr::null();
            let success = send!(unsafe extern "C" fn(Object, Selector, Object, Object, Object, usize, *mut Object, *mut Object) -> Bool,
                manager, c"replaceItemAtURL:withItemAtURL:backupItemName:options:resultingItemURL:error:",
                destination_url, staging, ptr::null(), 0, ptr::null_mut(), &mut error);
            if success == 0 { return Err(error_text(error)); }
            Ok(())
        } else { item_operation(manager, staging, destination_url, false) }
    }
}

#[cfg(all(test, target_os = "macos"))]
mod tests {
    use super::copy_export;
    use serde_json::{json, Value};
    use std::{ffi::CString, fs, os::unix::{ffi::OsStrExt, fs::{PermissionsExt, symlink}}, path::{Path, PathBuf}};
    struct Area(PathBuf);
    impl Drop for Area { fn drop(&mut self) { let _ = fs::remove_dir_all(&self.0); } }
    fn attribute(path: &Path, name: &str) -> Value {
        let path = CString::new(path.as_os_str().as_bytes()).unwrap();
        let name = CString::new(name).unwrap();
        let mut bytes = [0_u8; 64];
        // SAFETY: Both C strings and the writable byte buffer cover the stated
        // lengths. This only reads metadata in the test's private fixture.
        let length = unsafe { libc::getxattr(path.as_ptr(), name.as_ptr(), bytes.as_mut_ptr().cast(), bytes.len(), 0, 0) };
        if length < 0 {
            let code = std::io::Error::last_os_error().raw_os_error().unwrap();
            assert!([libc::ENOATTR, libc::ENOENT].contains(&code), "fixture getxattr errno {code}");
            Value::Null
        } else { json!(String::from_utf8_lossy(&bytes[..length as usize])) }
    }
    fn set_attribute(path: &Path, name: &str, value: &str) {
        let path = CString::new(path.as_os_str().as_bytes()).unwrap();
        let name = CString::new(name).unwrap();
        // SAFETY: Valid C path/name and initialized value bytes remain alive
        // for the complete syscall, confined to this test-owned file.
        let result = unsafe { libc::setxattr(path.as_ptr(), name.as_ptr(), value.as_ptr().cast(), value.len(), 0, 0) };
        assert_eq!(result, 0, "fixture setxattr: {}", std::io::Error::last_os_error());
    }
    fn snapshot(path: &Path) -> Value {
        let info = match fs::symlink_metadata(path) {
            Ok(info) => info,
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Value::Null,
            Err(error) => panic!("fixture snapshot: {error}"),
        };
        let symbolic = info.file_type().is_symlink();
        json!({"mode":info.permissions().mode() & 0o777,"symlink":symbolic,
            "link":if symbolic {json!(fs::read_link(path).unwrap().to_string_lossy())} else {Value::Null},
            "contents":fs::read_to_string(path).ok(),
            "sourceAttribute":attribute(path,"org.rbn.export.source"),"destinationAttribute":attribute(path,"org.rbn.export.destination")})
    }
    fn fixture(name: &str) -> Value {
        let root = std::env::temp_dir().canonicalize().unwrap().join(format!("mac-export-rust-{}", uuid::Uuid::new_v4()));
        fs::create_dir(&root).unwrap();
        fs::set_permissions(&root, fs::Permissions::from_mode(0o700)).unwrap();
        let _area = Area(root.clone());
        let source = root.join("source");
        let target = root.join("target");
        let destination = if name == "same" { source.clone() } else { root.join("destination") };
        fs::write(&target, "Target contents").unwrap();
        fs::set_permissions(&target, fs::Permissions::from_mode(0o600)).unwrap();
        if name == "source-link" { symlink("target", &source).unwrap(); }
        else if name != "missing-source" {
            fs::write(&source, "Source contents").unwrap();
            fs::set_permissions(&source, fs::Permissions::from_mode(0o640)).unwrap();
            set_attribute(&source, "org.rbn.export.source", "source-value");
        }
        if ["existing", "missing-source"].contains(&name) {
            fs::write(&destination, "Old destination").unwrap();
            fs::set_permissions(&destination, fs::Permissions::from_mode(0o604)).unwrap();
            set_attribute(&destination, "org.rbn.export.destination", "destination-value");
        } else if ["destination-link", "dangling-destination"].contains(&name) {
            symlink(if name == "destination-link" { "target" } else { "absent" }, &destination).unwrap();
        }
        let error = copy_export(&source, &destination).err().map(|text| {
            let text = text.replace(root.to_str().unwrap(), "<ROOT>").replace(root.file_name().unwrap().to_str().unwrap(), "<ROOT>");
            regex::Regex::new(r"\.rbn-export-[0-9A-Fa-f-]{36}").unwrap().replace_all(&text, ".rbn-export-<UUID>").into_owned()
        });
        let staging = fs::read_dir(&root).unwrap().filter_map(|item| {
            let name = item.unwrap().file_name().to_string_lossy().into_owned();
            name.starts_with(".rbn-export-").then_some(name)
        }).collect::<Vec<_>>();
        json!({"name":name,"error":error,"source":snapshot(&source),"destination":snapshot(&destination),"target":snapshot(&target),"stagingNames":staging})
    }
    #[test]
    fn finder_resource_flags_and_errors_match_original_swift() {
        let captured: Value = serde_json::from_str(include_str!("../../../Tests/fixtures/mac-finder-metadata-swift.json")).unwrap();
        let root = std::env::temp_dir().canonicalize().unwrap().join(format!("mac-finder-metadata-{}", uuid::Uuid::new_v4()));
        fs::create_dir(&root).unwrap();
        fs::set_permissions(&root, fs::Permissions::from_mode(0o700)).unwrap();
        let _area = Area(root.clone());
        for name in ["regular.txt", "new\nline.txt", "café-e\u{0301}-か\u{3099}-'\".txt"] {
            fs::write(root.join(name), "Metadata fixture").unwrap();
        }
        fs::create_dir(root.join("folder")).unwrap();
        for (name, target) in [("file-link", "regular.txt"), ("folder-link", "folder"), ("broken-link", "absent")] {
            symlink(target, root.join(name)).unwrap();
        }
        let fifo = CString::new(root.join("fifo").as_os_str().as_bytes()).unwrap();
        // SAFETY: This creates only an unopened named pipe in our private test
        // root. No read/write operation is issued against the FIFO.
        assert_eq!(unsafe { libc::mkfifo(fifo.as_ptr(), 0o600) }, 0);
        let cases = captured["cases"].as_array().unwrap();
        assert_eq!(cases.len(), 9);
        for case in cases {
            let name = case["name"].as_str().unwrap();
            let actual = match super::finder_kind(&root.join(name)) {
                Ok((directory, symbolic, regular)) => json!({"name":name,"flags":[directory,symbolic,regular],"error":null}),
                Err(error) => json!({"name":name,"flags":null,"error":error.replace(root.to_str().unwrap(),"<ROOT>").replace(root.file_name().unwrap().to_str().unwrap(),"<ROOT>")}),
            };
            assert_eq!(actual, *case, "original Finder URL resource values: {name:?}");
        }
    }
    #[test]
    fn foundation_copy_replace_matches_original_swift_export() {
        let captured: Value = serde_json::from_str(include_str!("../../../Tests/fixtures/mac-export-swift.json")).unwrap();
        let cases = captured["cases"].as_array().unwrap();
        assert_eq!(cases.len(), 7);
        for case in cases {
            let name = case["name"].as_str().unwrap();
            assert_eq!(fixture(name), *case, "original Mac copyExport: {name}");
        }
    }
}
