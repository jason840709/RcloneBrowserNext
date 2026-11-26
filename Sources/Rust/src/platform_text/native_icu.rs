//! ICU C ABI provider for the translated Foundation comparison.
//! The comparison, character tables and folding policy are Rust. This module
//! supplies only Unicode collation. Cluster boundaries use frozen Rust data.
use super::comparison::{Collation, Level};
use std::{
    cmp::Ordering,
    ffi::{c_char, c_void, CString},
    marker::PhantomData,
    ptr,
    rc::Rc,
    sync::OnceLock,
};

type Open = unsafe extern "C" fn(*const c_char, *mut i32) -> *mut c_void;
type Close = unsafe extern "C" fn(*mut c_void);
type Attribute = unsafe extern "C" fn(*mut c_void, i32, i32, *mut i32);
type Compare = unsafe extern "C" fn(*const c_void, *const u16, i32, *const u16, i32) -> i32;
type GetVersion = unsafe extern "C" fn(*mut u8);
type GetDataVersion = unsafe extern "C" fn(*mut u8, *mut i32);
type GetCollatorVersion = unsafe extern "C" fn(*const c_void, *mut u8);

struct Api {
    open: Open,
    close: Close,
    attribute: Attribute,
    compare: Compare,
    version: Option<GetVersion>,
    data_version: Option<GetDataVersion>,
    collator_version: Option<GetCollatorVersion>,
    uca_version: Option<GetCollatorVersion>,
    libraries: Vec<String>,
    legacy_com: bool,
}
static API: OnceLock<Result<Api, String>> = OnceLock::new();

struct Libraries { handles: Vec<usize>, names: Vec<String>, suffix: String, legacy_com: bool }
impl Libraries {
    fn symbol(&self, name: &str) -> Option<usize> {
        let name = CString::new(format!("{name}{}", self.suffix)).ok()?;
        self.handles.iter().rev().find_map(|h| {
            // SAFETY: Handles were opened by the platform loader and remain
            // owned here. The symbol name is NUL terminated and immutable.
            let symbol = unsafe { platform::symbol(*h, name.as_ptr()) };
            (symbol != 0).then_some(symbol)
        })
    }
}
impl Drop for Libraries {
    fn drop(&mut self) {
        for h in self.handles.iter().rev() {
            // SAFETY: Every handle is one successful loader acquisition and
            // is released once. On successful Api initialization we pin it.
            unsafe { platform::close(*h) };
        }
    }
}
impl Api {
    fn load() -> Result<Self, String> {
        let libraries = platform::open()?;
        macro_rules! required {
            ($name:literal, $ty:ty) => {{
                let address = libraries.symbol($name)
                    .ok_or_else(|| format!("System ICU is missing {}", $name))?;
                // SAFETY: ICU's public C ABI specifies this exact signature.
                // The concrete transmute also checks pointer sizes.
                unsafe { std::mem::transmute::<usize, $ty>(address) }
            }};
        }
        macro_rules! optional {
            ($name:literal, $ty:ty) => {
                libraries.symbol($name).map(|address| {
                    // SAFETY: This optional diagnostic uses the documented
                    // ICU C signature and has the same pinned module lifetime.
                    unsafe { std::mem::transmute::<usize, $ty>(address) }
                })
            };
        }
        let api = Self {
            open: required!("ucol_open", Open),
            close: required!("ucol_close", Close),
            attribute: required!("ucol_setAttribute", Attribute),
            compare: required!("ucol_strcoll", Compare),
            version: optional!("u_getVersion", GetVersion),
            data_version: optional!("u_getDataVersion", GetDataVersion),
            collator_version: optional!("ucol_getVersion", GetCollatorVersion),
            uca_version: optional!("ucol_getUCAVersion", GetCollatorVersion),
            libraries: libraries.names.clone(),
            legacy_com: libraries.legacy_com,
        };
        // Api is a process-lifetime OnceLock. Pin the successful loader
        // acquisitions so no collator or function pointer can outlive them.
        std::mem::forget(libraries);
        Ok(api)
    }
}

pub struct Icu {
    api: &'static Api,
    collators: [*mut c_void; 3],
    _com: platform::Com,
    // ICU collators and any COM initialization belong to this thread.
    _thread: PhantomData<Rc<()>>,
}
impl Icu {
    pub fn new() -> Result<Self, String> {
        let api = API.get_or_init(Api::load).as_ref().map_err(Clone::clone)?;
        let com = platform::Com::new(api.legacy_com)?;
        let mut result = Self {
            api, collators: [ptr::null_mut(); 3], _com: com, _thread: PhantomData,
        };
        for level in 0..3 {
            let mut status = 0;
            // SAFETY: The static locale is NUL terminated; status is writable.
            // Foundation 6.1.2's non-Apple Locale.current is en_001.
            let collator = unsafe { (api.open)(c"en_001".as_ptr(), &mut status) };
            if status > 0 || collator.is_null() {
                if !collator.is_null() {
                    // SAFETY: This failed open still returned an owned handle.
                    unsafe { (api.close)(collator) };
                }
                return Err(format!("System ICU could not create a collator ({status})"));
            }
            result.collators[level] = collator;
            // Primary, secondary and tertiary match __CompareTextDefault.
            // NORMALIZATION(4), ALTERNATE(1), STRENGTH(5), CASE_LEVEL(3),
            // NUMERIC_COLLATION(7); UCOL_OFF=16, ON=17, NON_IGNORABLE=21.
            let attributes = [
                (4, if level == 0 { 16 } else { 17 }),
                (1, 21), (5, level as i32),
                (3, if level == 2 { 17 } else { 16 }), (7, 17),
            ];
            for (key, value) in attributes {
                status = 0;
                // SAFETY: This thread owns the live collator. Attribute keys
                // and values are the stable ICU C enum constants above.
                unsafe { (api.attribute)(collator, key, value, &mut status) };
                if status > 0 {
                    return Err(format!("System ICU could not configure collation ({status})"));
                }
            }
        }
        Ok(result)
    }
    pub fn versions(&self) -> String {
        let mut fields = vec![format!("libraries={}", self.api.libraries.join(","))];
        if let Some(f) = self.api.version {
            let mut v = [0u8; 4];
            // SAFETY: u_getVersion writes exactly four bytes.
            unsafe { f(v.as_mut_ptr()) };
            fields.push(format!("code={v:?}"));
        }
        if let Some(f) = self.api.data_version {
            let mut v = [0u8; 4]; let mut status = 0;
            // SAFETY: Both fixed output buffers are live for this call.
            unsafe { f(v.as_mut_ptr(), &mut status) };
            fields.push(format!("data={v:?};status={status}"));
        }
        for (name, function) in [("collator", self.api.collator_version), ("uca", self.api.uca_version)] {
            if let Some(f) = function {
                let mut v = [0u8; 4];
                // SAFETY: The collator is live and the output has four bytes.
                unsafe { f(self.collators[0], v.as_mut_ptr()) };
                fields.push(format!("{name}={v:?}"));
            }
        }
        fields.join(";")
    }
}
impl Collation for Icu {
    fn compare(&self, level: Level, a: &[u16], b: &[u16]) -> Ordering {
        let index = match level { Level::Primary => 0, Level::Secondary => 1, Level::Tertiary => 2 };
        let alen = i32::try_from(a.len()).expect("bounded filename UTF-16 length");
        let blen = i32::try_from(b.len()).expect("bounded filename UTF-16 length");
        // SAFETY: Both slices are immutable and valid for their explicit
        // lengths. The current thread exclusively owns this configured handle.
        unsafe { (self.api.compare)(self.collators[index], a.as_ptr(), alen, b.as_ptr(), blen) }.cmp(&0)
    }

}
impl Drop for Icu {
    fn drop(&mut self) {
        for &c in &self.collators {
            if !c.is_null() {
                // SAFETY: Each handle came from open and is owned by this
                // instance on the originating thread; close before COM drops.
                unsafe { (self.api.close)(c) };
            }
        }
    }
}

#[cfg(unix)]
mod platform {
    use super::*;
    unsafe extern "C" {
        fn dlopen(name: *const c_char, flags: i32) -> *mut c_void;
        fn dlsym(handle: *mut c_void, name: *const c_char) -> *mut c_void;
        fn dlclose(handle: *mut c_void) -> i32;
    }
    pub unsafe fn symbol(h: usize, name: *const c_char) -> usize {
        // SAFETY: Caller owns the live handle and NUL-terminated symbol.
        unsafe { dlsym(h as *mut c_void, name) as usize }
    }
    pub unsafe fn close(h: usize) {
        // SAFETY: Caller transfers one live loader acquisition.
        unsafe { dlclose(h as *mut c_void) };
    }
    fn library(name: &str) -> Option<usize> {
        let name = CString::new(name).ok()?;
        #[cfg(target_os="macos")] let flags = 2 | 4; // RTLD_NOW | RTLD_LOCAL
        #[cfg(not(target_os="macos"))] let flags = 2; // RTLD_NOW | RTLD_LOCAL
        // SAFETY: The immutable library name is NUL terminated.
        let handle = unsafe { dlopen(name.as_ptr(), flags) };
        (!handle.is_null()).then_some(handle as usize)
    }
    pub fn open() -> Result<Libraries, String> {
        #[cfg(target_os="macos")]
        {
            let name = "/usr/lib/libicucore.A.dylib";
            let handle = library(name).ok_or("Test ICU could not be loaded")?;
            return Ok(Libraries { handles: vec![handle], names: vec![name.into()], suffix: String::new(), legacy_com: false });
        }
        #[cfg(not(target_os="macos"))]
        {
            // The published Ubuntu 24.04 package declares libicu74.
            // Match that existing dependency instead of choosing a newer ABI.
            for major in [74] {
                let names = [format!("libicuuc.so.{major}"), format!("libicui18n.so.{major}")];
                if let Some(common) = library(&names[0]) {
                    if let Some(i18n) = library(&names[1]) {
                        return Ok(Libraries { handles:vec![common,i18n], names: names.to_vec(), suffix:format!("_{major}"), legacy_com:false });
                    }
                    // SAFETY: The second acquisition failed, so release the
                    // otherwise-unused first acquisition before trying next.
                    unsafe { close(common) };
                }
            }
            Err("System ICU collation libraries could not be loaded".into())
        }
    }
    pub struct Com;
    impl Com { pub fn new(_: bool) -> Result<Self,String> { Ok(Self) } }
}

#[cfg(windows)]
mod platform {
    use super::*;
    #[link(name="kernel32")]
    unsafe extern "system" {
        fn LoadLibraryExW(path:*const u16, file:*mut c_void, flags:u32)->*mut c_void;
        fn GetProcAddress(module:*mut c_void, name:*const c_char)->*mut c_void;
        fn FreeLibrary(module:*mut c_void)->i32;
    }
    #[link(name="ole32")]
    unsafe extern "system" {
        fn CoInitializeEx(reserved:*mut c_void, flags:u32)->i32;
        fn CoUninitialize();
    }
    pub unsafe fn symbol(h:usize,name:*const c_char)->usize {
        // SAFETY: Caller owns this live system module and NUL-terminated name.
        unsafe { GetProcAddress(h as *mut c_void,name) as usize }
    }
    pub unsafe fn close(h:usize) {
        // SAFETY: Caller transfers exactly one live module acquisition.
        unsafe { FreeLibrary(h as *mut c_void) };
    }
    fn library(name:&str)->Option<usize> {
        let name:Vec<u16> = name.encode_utf16().chain(Some(0)).collect();
        // SAFETY: Only fixed OS library names are passed; SYSTEM32 prevents
        // loading a same-named DLL from a directory being browsed by the user.
        let handle=unsafe { LoadLibraryExW(name.as_ptr(),ptr::null_mut(),0x0000_0800) };
        (!handle.is_null()).then_some(handle as usize)
    }
    pub fn open()->Result<Libraries,String> {
        if let Some(handle)=library("icu.dll") {
            return Ok(Libraries {handles:vec![handle],names:vec!["System32/icu.dll".into()],suffix:String::new(),legacy_com:false});
        }
        let common=library("icuuc.dll").ok_or("System ICU common library could not be loaded")?;
        if let Some(i18n)=library("icuin.dll") {
            Ok(Libraries {handles:vec![common,i18n],names:vec!["System32/icuuc.dll".into(),"System32/icuin.dll".into()],suffix:String::new(),legacy_com:true})
        } else {
            // SAFETY: No API instance uses this otherwise-unused acquisition.
            unsafe { close(common) };
            Err("System ICU collation library could not be loaded".into())
        }
    }
    pub struct Com(bool);
    impl Com {
        pub fn new(needed:bool)->Result<Self,String> {
            if !needed { return Ok(Self(false)); }
            // SAFETY: Null reserved argument, multi-threaded apartment. This
            // thread-bound guard balances only its own successful acquisition.
            let result=unsafe { CoInitializeEx(ptr::null_mut(),0) };
            if result>=0 { Ok(Self(true)) }
            else if result==0x8001_0106u32 as i32 { Ok(Self(false)) } // existing STA
            else { Err(format!("System ICU COM initialization failed ({result})")) }
        }
    }
    impl Drop for Com {
        fn drop(&mut self) {
            if self.0 {
                // SAFETY: This guard cannot move across threads and balances
                // exactly one S_OK/S_FALSE call to CoInitializeEx.
                unsafe { CoUninitialize() };
            }
        }
    }
}
