// Swift 6.1.2 CFString.c:3642–4558, specialized to kCFStringGraphemeCluster.
// Copyright Apple Inc. and the Swift project authors. See ../../../../Compat/licenses/Foundation-LICENSE.txt.
use super::tables::{EXTEND, has, priority};

const PROPERTIES: &[u8] = include_bytes!("cluster-data.bin");
fn properties(cp: u32) -> u8 {
    let (mut lo, mut hi) = (0, PROPERTIES.len() / 9);
    while lo < hi {
        let m = (lo + hi) / 2;
        let p = m * 9;
        let from = u32::from_le_bytes(PROPERTIES[p..p + 4].try_into().unwrap());
        let to = u32::from_le_bytes(PROPERTIES[p + 4..p + 8].try_into().unwrap());
        if cp < from {
            hi = m;
        } else if cp > to {
            lo = m + 1;
        } else {
            return PROPERTIES[p + 8];
        }
    }
    0
}
const ZWJ: u32 = 0x200d;
const EXT_OR_MOD: u8 = 2 | 4;
const PICT: u8 = 8;
const PRE: u8 = 16;
fn post(c: u32) -> bool {
    c == ZWJ || properties(c) & (EXT_OR_MOD | 32) != 0
}
#[derive(Clone, Copy, Default, Debug)]
struct R {
    p: isize,
    n: isize,
}
impl R {
    fn new(p: isize, n: isize) -> Self {
        Self { p, n }
    }
    fn end(self) -> isize {
        self.p + self.n
    }
}
fn raw(s: &[u16], i: isize) -> u32 {
    if i < 0 {
        0
    } else {
        s.get(i as usize).copied().unwrap_or(0) as u32
    }
}
fn read(s: &[u16], i: isize) -> (u32, R) {
    if i < 0 || i >= s.len() as isize {
        return (0, R::new(-1, 0));
    }
    let c = raw(s, i);
    let (start, hi, lo) = if (0xd800..=0xdbff).contains(&c) {
        (i, c, raw(s, i + 1))
    } else if (0xdc00..=0xdfff).contains(&c) {
        (i - 1, raw(s, i - 1), c)
    } else {
        return (c, R::new(i, 1));
    };
    if (0xd800..=0xdbff).contains(&hi) && (0xdc00..=0xdfff).contains(&lo) {
        (
            0x10000 + ((hi - 0xd800) << 10) + lo - 0xdc00,
            R::new(start, 2),
        )
    } else {
        (c, R::new(i, 1))
    }
}
#[derive(Clone, Copy)]
struct Component {
    r: R,
    extend: isize,
    zwj: isize,
    pic: isize,
}
fn component(s: &[u16], index: isize) -> Option<Component> {
    if index < 0 || index >= s.len() as isize {
        return None;
    }
    let mut m = Component {
        r: R::new(-1, 0),
        extend: -1,
        zwj: -1,
        pic: -1,
    };
    let mut i = index;
    while i >= 0 {
        let (c, r) = read(s, i);
        let prop = properties(c);
        if prop & EXT_OR_MOD != 0 {
            m.extend = r.p;
        } else if c == ZWJ {
            if m.extend != -1 || m.zwj != -1 {
                break;
            }
            m.zwj = r.p;
        } else if prop & PICT != 0 {
            if m.pic != -1 || m.zwj != -1 || m.extend != -1 {
                break;
            }
            m.pic = r.p;
        } else {
            break;
        }
        m.r.p = r.p;
        m.r.n += r.n;
        i = r.p - 1;
    }
    if m.pic != -1 {
        if m.extend != -1 && m.zwj == -1 {
            m.r.p = m.pic;
            m.r.n -= m.pic - m.extend;
        }
        return Some(m);
    }
    if m.zwj == -1 && m.extend == -1 {
        return None;
    }
    i = m.r.end();
    while m.pic == -1 && i < s.len() as isize {
        let (c, r) = read(s, i);
        let prop = properties(c);
        if prop & EXT_OR_MOD != 0 {
            if m.zwj != -1 {
                break;
            }
        } else if c == ZWJ {
            if m.zwj != -1 {
                break;
            }
            m.zwj = r.p;
        } else if prop & PICT != 0 {
            m.pic = r.p;
        } else {
            break;
        }
        m.r.n += r.n;
        i = r.end();
    }
    (m.pic != -1).then_some(m)
}
fn pictographic(s: &[u16], index: isize) -> Option<R> {
    let size = s.len() as isize;
    let (mut c, mut r) = read(s, index);
    if r.n == 0 {
        return None;
    }
    let mut tail = R::new(r.n, 0);
    while post(c) {
        tail.p = r.p;
        tail.n += r.n;
        if tail.p == 0 {
            return None;
        }
        (c, r) = read(s, tail.p - 1);
    }
    let mut core = R::new(r.p, 0);
    let mut last = None;
    while let Some(m) = component(s, r.p) {
        core.p = m.r.p;
        core.n += m.r.n;
        r = R::new(m.r.p - 1, 0);
        last = Some(m);
        if m.zwj == -1 {
            break;
        }
    }
    let mut expand_pre = true;
    if let Some(m) = last.filter(|m| m.extend != -1 || m.zwj != -1) {
        core.p = m.pic;
        core.n -= m.pic - m.r.p;
        r = R::new(m.pic + 1, 0);
        expand_pre = false;
    }
    if tail.n > 0 && core.n == 0 {
        return None;
    }
    let mut pre = R::new(r.p, 0);
    if expand_pre {
        if r.p >= 0 {
            (c, r) = read(s, r.p);
            while properties(c) & PRE != 0 {
                pre.p = r.p;
                pre.n += r.n;
                if pre.p == 0 {
                    break;
                }
                (c, r) = read(s, pre.p - 1);
            }
        }
        let mut i = pre.end();
        while i < size {
            let (c, r) = read(s, i);
            if properties(c) & PRE == 0 {
                break;
            }
            pre.n += r.n;
            i = r.end();
        }
    }
    if pre.n == 0 && core.n == 0 {
        return None;
    }
    if core.n == 0 {
        core = R::new(pre.end(), 0);
    }
    let mut i = core.end();
    while let Some(m) = component(s, i) {
        if core.n > 0 && m.zwj == -1 {
            break;
        }
        core.n += m.r.n;
        i += m.r.n;
    }
    if tail.n > 0 {
        if core.end() >= tail.end() {
            tail = R::new(core.end(), 0);
        }
        i = tail.end();
    } else {
        tail = R::new(i, 0);
    }
    while i < size {
        let (c, r) = read(s, i);
        if !post(c) {
            break;
        }
        tail.n += r.n;
        i = r.end();
    }
    if core.n == 0 {
        return None;
    }
    if pre.n > 0 {
        core.p = pre.p;
        core.n += pre.n;
    }
    core.n += tail.n;
    Some(core)
}

fn mark(c: u32) -> bool {
    has(c, EXTEND)
        || (0x1f3fb..=0x1f3ff).contains(&c)
        || (0xe0020..=0xe007f).contains(&c)
        || c == 0xff9e
        || c == 0xff9f
        || (c & 0x1ffff0) == 0xf870
}
fn hangul(c: u32) -> bool {
    (0x1100..=0x11f9).contains(&c) || (0xac00..=0xd7af).contains(&c)
}
fn hstate(c: u32) -> u8 {
    if c < 0x1160 {
        0
    } else if c < 0x11a8 {
        1
    } else if c < 0xac00 {
        2
    } else if (c - 0xac00) % 28 == 0 {
        3
    } else {
        4
    }
}
fn composed(s: &[u16], at: isize) -> R {
    let (mut c, mut v) = read(s, at);
    let mut end = v.end();
    while v.p > 0 && mark(c) {
        (c, v) = read(s, v.p - 1);
    }
    let mut start = v.p;
    if hangul(c) {
        let initial = hstate(c);
        let mut state = initial;
        while hangul(raw(s, start - 1)) {
            c = raw(s, start - 1);
            let next = match state {
                1 if c <= 0x115f => 0,
                1 if c >= 0xac00 && hstate(c) == 3 => 3,
                1 if c <= 0x11a2 => 1,
                2 if (0x1160..=0x11a2).contains(&c) => 1,
                2 if c >= 0xac00 => hstate(c),
                2 if c >= 0x1160 => 2,
                0 | 3 | 4 if c < 0x1160 => 0,
                _ => break,
            };
            state = next;
            start -= 1;
        }
        state = initial;
        while hangul(raw(s, end)) {
            c = raw(s, end);
            let next = match state {
                1 | 3 if (0x1160..=0x11f9).contains(&c) => {
                    if c < 0x11a8 {
                        1
                    } else {
                        2
                    }
                }
                2 | 4 if (0x11a8..=0x11f9).contains(&c) => 2,
                0 if c < 0x11a8 || c >= 0xac00 => hstate(c),
                _ => break,
            };
            state = next;
            end += 1;
        }
    }
    while end < s.len() as isize {
        let (c, v) = read(s, end);
        if c == 0 || !mark(c) {
            break;
        }
        end = v.end();
    }
    R::new(start, end - start)
}
fn virama(c: u32) -> bool {
    c == 0x034f || priority(c) == 9
}
fn letter(c: u32) -> bool {
    properties(c) & 1 != 0
}
fn regional(s: &[u16], p: isize) -> bool {
    raw(s, p) == 0xd83c && (0xdde6..=0xddff).contains(&raw(s, p + 1))
}

/// CFStringGetRangeOfCharacterClusterAtIndex(kind=1). The old Swift strings
/// do not use CF's native eight-bit storage shortcut.
pub fn end(s: &[u16], at: usize) -> usize {
    let size = s.len() as isize;
    let mut r = composed(s, at as isize);
    let (c, _) = read(s, r.p);
    if c == ZWJ || letter(c) {
        let old_end = r.end();
        let mut i = r.p;
        while i > 1 {
            i -= 1;
            let c = raw(s, i);
            let joins = virama(c)
                || (c == ZWJ && {
                    i -= 1;
                    virama(raw(s, i))
                });
            if !joins || i == 0 {
                break;
            }
            i = composed(s, i - 1).p;
            // Mirror the original BMP read and its reversed-argument low-surrogate branch.
            let mut ch = raw(s, i);
            if (0xdc00..=0xdfff).contains(&ch) && (0xd800..=0xdbff).contains(&raw(s, i - 1)) {
                ch = ((ch - 0xd800) << 10) + raw(s, i - 1) + 0x2400;
                i -= 1;
            }
            if !letter(ch) {
                break;
            }
            r.p = i;
        }
        r.n = old_end - r.p;
        if r.n > 1 && old_end < size {
            let mut i = old_end;
            while i < size {
                let prev = raw(s, i - 1);
                if prev != ZWJ && !virama(prev) {
                    break;
                }
                if raw(s, i) == ZWJ {
                    i += 1;
                }
                let (next, _) = read(s, i);
                if !letter(next) {
                    break;
                }
                i = composed(s, i).end();
            }
            r.n = i - r.p;
        }
    }
    let mut p = (r.end() - 5).max(0);
    const LENGTHS: [isize; 16] = [2, 3, 4, 4, 4, 4, 4, 2, 2, 2, 2, 4, 0, 0, 0, 0];
    while p <= r.p {
        let c = raw(s, p);
        if c & 0x1ffff0 == 0xf860 {
            let mut candidate = p + LENGTHS[(c - 0xf860) as usize] + 1;
            if candidate >= r.end() {
                if candidate <= size {
                    let mut i = p + 1;
                    while i < candidate {
                        let other = composed(s, i);
                        i = other.end();
                        if i > candidate {
                            candidate = other.p;
                            break;
                        }
                    }
                    r = R::new(p, candidate - p);
                }
                break;
            }
        }
        p += 1;
    }
    if r.n == 2 && regional(s, r.p) {
        let mut i = r.p;
        while i > 1 && regional(s, i - 2) {
            i -= 2;
        }
        if r.p > i && (r.p - i) % 4 != 0 {
            r.p -= 2;
            r.n += 2;
        }
        if r.n == 2 && r.end() + 2 <= size && regional(s, r.end()) {
            r.n += 2;
        }
    }
    if let Some(cluster) = pictographic(s, r.p) {
        if r.p >= cluster.p && r.end() <= cluster.end() {
            r = cluster;
        }
    }
    if r.p > 0 && r.n == 1 && raw(s, r.p) == ZWJ {
        let prev = composed(s, r.p - 1);
        if r.p == prev.end() {
            r = prev;
            r.n += 1;
        }
    }
    if r.end() < size && raw(s, r.end()) == ZWJ {
        r.n += 1;
    }
    r.end() as usize
}
