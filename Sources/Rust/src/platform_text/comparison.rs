// Adapted from Swift 6.1.2 CoreFoundation, CFString.c and CFStringUtilities.c.
// Copyright Apple Inc. and the Swift project authors. See ../../../../Compat/licenses/Foundation-LICENSE.txt.
#[path = "cluster.rs"]
mod cluster;
#[path = "tables.rs"]
mod tables;
use self::tables::*;
pub use cluster::end as cluster_end;
use std::cmp::Ordering::{self, Equal, Greater, Less};

const INLINE: usize = 64;

#[derive(Copy, Clone)]
pub enum Level {
    Primary,
    Secondary,
    Tertiary,
}

/// en_001, numeric ON, NON_IGNORABLE. Primary has normalization and case level
/// OFF. Secondary has normalization ON. Tertiary has normalization + case level ON.
pub trait Collation {
    fn compare(&self, level: Level, a: &[u16], b: &[u16]) -> Ordering;
}

fn scalar_at(text: &[u16], i: usize) -> (u32, usize) {
    let Some(&ch) = text.get(i) else {
        return (0, 0);
    };
    if (0xd800..=0xdbff).contains(&ch) {
        if let Some(&lo @ 0xdc00..=0xdfff) = text.get(i + 1) {
            return (
                0x10000 + ((ch as u32 - 0xd800) << 10) + lo as u32 - 0xdc00,
                2,
            );
        }
    }
    (ch as u32, 1)
}

fn extend_back(text: &[u16], from: usize) -> usize {
    let mut i = from.saturating_sub(1);
    while i > 0 {
        let u = text[i];
        if (0xdc00..=0xdfff).contains(&u) && (0xd800..=0xdbff).contains(&text[i - 1]) {
            // The frozen source calls GetLongCharacterForSurrogatePair(low, high).
            let pair = ((u as u32 - 0xd800) << 10) + text[i - 1] as u32 + 0x2400;
            if pair >> 16 > 1 || !has(pair, NON_BASE | PUNCT) {
                break;
            }
            i = i.saturating_sub(2);
        } else if (0x2e80..0xac00).contains(&u) || !has(u as u32, NON_BASE | PUNCT) {
            break;
        } else {
            i -= 1;
        }
    }
    i
}
fn extend_forward(text: &[u16], mut i: usize) -> usize {
    while i < text.len() {
        let (cp, n) = scalar_at(text, i);
        i += n;
        if (0x2e80..0xac00).contains(&cp) || !has(cp, ALNUM | PUNCT | CONTROL_FORMAT) {
            break;
        }
    }
    i
}

fn segment(icu: &impl Collation, a: &[u16], b: &[u16]) -> (Ordering, bool, bool) {
    // (order, equivalent, primary difference)
    let p = icu.compare(Level::Primary, a, b);
    if p != Equal {
        return (p, false, true);
    }
    let s = icu.compare(Level::Secondary, a, b);
    if s != Equal {
        return (s, false, false);
    }
    let t = icu.compare(Level::Tertiary, a, b);
    (if t == Equal { a.cmp(b) } else { t }, true, false)
}
fn localized(icu: &impl Collation, a: &[u16], i: usize, b: &[u16], j: usize) -> Ordering {
    let (mut left, mut right) = (extend_back(a, i), extend_back(b, j));
    // NSString._fastContents is nil in the Swift 6.1.2 non-Darwin bridge.
    // CF checks the original remaining length before extending the actual span.
    if a.len() - i <= INLINE && b.len() - j <= INLINE {
        return segment(icu, &a[left..], &b[right..]).0;
    }
    let (mut end_a, mut end_b) = (i, j);
    let mut weak = Equal;
    let (mut previous_a, mut previous_b) = (&a[left..left], &b[right..right]);
    loop {
        // CF updates a side's comparison buffer only while that side has input.
        // Once exhausted, the pointer and length from its previous pass remain.
        if end_a < a.len() {
            end_a = extend_forward(a, end_a);
            previous_a = &a[left..end_a];
        }
        if end_b < b.len() {
            end_b = extend_forward(b, end_b);
            previous_b = &b[right..end_b];
        }
        let (ord, equivalent, primary) = segment(icu, previous_a, previous_b);
        if primary {
            return ord;
        }
        if equivalent {
            if weak == Equal {
                weak = ord;
            }
            left = end_a;
            right = end_b;
        }
        if end_a == a.len() && end_b == b.len() {
            return if equivalent { weak } else { ord };
        }
    }
}

struct Cursor<'a> {
    s: &'a [u16],
    i: usize,
    used: usize,
    folded: Vec<u32>,
    next: usize,
    prevent: usize,
}
impl<'a> Cursor<'a> {
    fn new(s: &'a [u16]) -> Self {
        Self {
            s,
            i: 0,
            used: 0,
            folded: vec![],
            next: 0,
            prevent: 0,
        }
    }
    fn read(&mut self, forced: bool) -> u32 {
        if self.folded.is_empty() {
            self.used = 1;
            let mut c = self.s[self.i] as u32;
            if forced && (65..=90).contains(&c) {
                c += 32;
            }
            c
        } else {
            let c = self.folded[self.next];
            self.next += 1;
            c
        }
    }
    fn merge_surrogate(&mut self, ch: u32) -> u32 {
        if (0xd800..=0xdbff).contains(&ch) {
            if let Some(&lo @ 0xdc00..=0xdfff) = self.s.get(self.i + 1) {
                self.used = 2;
                return 0x10000 + ((ch - 0xd800) << 10) + lo as u32 - 0xdc00;
            }
        }
        ch
    }
    fn can_fold(&self) -> bool {
        self.folded.is_empty() && (self.prevent == 0 || self.prevent == self.i)
    }
    fn fold(&mut self, ch: u32) -> u32 {
        self.prevent = 0;
        if ch == 0 {
            return ch;
        }
        let mut current = self.i + if ch > 0xffff { 2 } else { 1 };
        let mut first = ch;
        let mut out = Vec::<u32>::new();
        if ch < 128 {
            if (65..=90).contains(&ch) {
                first = ch + 32;
                out.push(first);
            }
        } else {
            if (0xff00..=0xffef).contains(&first) {
                first = width(first);
                out.push(first);
            }
            if let Some(d) = canonical(first, INLINE) {
                out = d;
                if let Some(&p) = out.first() {
                    first = p;
                }
            }
            if let Some(mapped) = casefold(first) {
                let tail = out.get(1..).unwrap_or(&[]).to_vec();
                out = mapped;
                out.extend(tail);
            }
        }
        let mut overflow = false;
        while let (cp, n @ 1..=2) = scalar_at(self.s, current) {
            if !has(cp, EXTEND) {
                break;
            }
            if out.is_empty() {
                out.push(first);
            }
            let avail = INLINE - out.len();
            let d = canonical(cp, avail);
            if avail == 0 || d.as_ref().is_some_and(Vec::is_empty) {
                overflow = true;
                break;
            }
            if let Some(d) = d {
                out.extend(d);
            } else {
                out.push(cp);
            }
            current += n;
            if out.len() == INLINE {
                overflow = true;
                break;
            }
        }
        if overflow {
            self.prevent = cluster_end(self.s, self.i);
        }
        if out.is_empty() {
            return ch;
        }
        let mut k = out.len() - 1;
        while k > 0 && has(out[k], EXTEND) {
            k -= 1;
        }
        while k < out.len() && priority(out[k]) == 0 {
            k += 1;
        }
        out[k..].sort_by_key(|cp| priority(*cp));
        self.used = current - self.i;
        self.folded = out;
        self.next = 1;
        self.folded[0]
    }
    fn step(&mut self) {
        if self.next == self.folded.len() {
            self.folded.clear();
            self.next = 0;
        }
        if self.folded.is_empty() {
            self.i += self.used;
        }
    }
    fn number(&mut self) -> (u64, usize) {
        let start = self.i;
        let mut n = 0u64;
        while let Some(&digit @ 48..=57) = self.s.get(self.i) {
            n = n.wrapping_mul(10).wrapping_add(u64::from(digit - 48));
            self.i += 1;
        }
        (n, self.i - start)
    }
}

pub fn compare_utf16(icu: &impl Collation, a: &[u16], b: &[u16]) -> Ordering {
    if a == b {
        return Equal;
    }
    let (mut x, mut y) = (Cursor::new(a), Cursor::new(b));
    let mut clean = (0, 0);
    let mut forced = None;
    let mut numeric_equivalence = false;
    while x.i < a.len() && y.i < b.len() {
        let (mut l, mut r) = (x.read(forced.is_some()), y.read(forced.is_some()));
        if x.folded.is_empty()
            && y.folded.is_empty()
            && (48..=57).contains(&l)
            && (48..=57).contains(&r)
        {
            let pos = (x.i, y.i);
            let (nx, lenx) = x.number();
            let (ny, leny) = y.number();
            if nx != ny {
                return nx.cmp(&ny);
            }
            if forced.is_none() && lenx != leny {
                forced = Some((lenx.cmp(&leny), pos));
                numeric_equivalence = true;
            }
            continue;
        }
        if l != r {
            if forced.is_none() {
                forced = Some((l.cmp(&r), clean));
            }
            if l < 128 && r < 128 {
                return localized(icu, a, x.i, b, y.i);
            }
            l = x.merge_surrogate(l);
            r = y.merge_surrogate(r);
            if l != r {
                if x.can_fold() {
                    l = x.fold(l);
                }
                if x.folded.is_empty() && !y.folded.is_empty() {
                    return localized(icu, a, clean.0, b, clean.1);
                }
                if y.can_fold() && (x.folded.is_empty() || l != r) {
                    r = y.fold(r);
                    if y.folded.is_empty() || l != r {
                        return localized(icu, a, clean.0, b, clean.1);
                    }
                }
                while x.next < x.folded.len() && y.next < y.folded.len() {
                    if x.folded[x.next] != y.folded[y.next] {
                        return localized(icu, a, clean.0, b, clean.1);
                    }
                    x.next += 1;
                    y.next += 1;
                }
            }
        }
        x.step();
        y.step();
        if x.folded.is_empty() && y.folded.is_empty() {
            clean = (x.i, y.i);
        }
    }
    if x.i < a.len() {
        return Greater;
    }
    if y.i < b.len() {
        return Less;
    }
    match forced {
        None => Equal,
        Some((order, _)) if numeric_equivalence => order,
        Some((_, (i, j))) => localized(icu, a, i, b, j),
    }
}
