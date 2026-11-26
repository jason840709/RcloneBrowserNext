// Derived from Swift 6.1.2 CoreFoundation Unicode data. See ../../../../Compat/licenses/Foundation-LICENSE.txt.
const DATA: &[u8] = include_bytes!("foundation-data.bin");
pub const NON_BASE: u8 = 1;
pub const ALNUM: u8 = 2;
pub const PUNCT: u8 = 4;
pub const CONTROL_FORMAT: u8 = 8;
pub const EXTEND: u8 = 16;
pub const CANON: u8 = 32;
pub const CASEMAP: u8 = 64 | 128;

fn word(index: usize) -> usize {
    u32::from_le_bytes(DATA[index..index + 4].try_into().unwrap()) as usize
}
fn lookup(section: usize, scalar: u32, range: bool) -> Option<(usize, usize)> {
    let base = word(section * 4);
    let mut end = (word((section + 1) * 4) - base) / 12;
    let mut first = 0;
    let scalar = scalar as usize;
    while first < end {
        let middle = first + (end - first) / 2;
        let at = base + 12 * middle;
        let key = word(at);
        let value = word(at + 4);
        if scalar < key {
            end = middle;
        } else if scalar > if range { value } else { key } {
            first = middle + 1;
        } else {
            return Some((value, word(at + 8)));
        }
    }
    None
}
pub fn has(scalar: u32, mask: u8) -> bool {
    lookup(0, scalar, true).is_some_and(|(_, v)| v as u8 & mask != 0)
}
pub fn priority(scalar: u32) -> u8 {
    lookup(1, scalar, true).map_or(0, |(_, v)| v as u8)
}
fn sequence(section: usize, scalar: u32, capacity: usize) -> Option<Vec<u32>> {
    let (start, lens) = lookup(section, scalar, false)?;
    if lens >> 8 > capacity {
        return Some(Vec::new());
    }
    let data = word(5 * 4);
    Some(
        (start..start + (lens & 255))
            .map(|i| word(data + 4 * i) as u32)
            .collect(),
    )
}
pub fn canonical(cp: u32, cap: usize) -> Option<Vec<u32>> {
    if !has(cp, CANON) {
        return None;
    }
    if (0xac00..0xac00 + 11172).contains(&cp) {
        let i = cp - 0xac00;
        let last = i % 28;
        let mut parts = vec![0x1100 + i / 588, 0x1161 + i % 588 / 28];
        if last != 0 {
            parts.push(0x11a7 + last);
        }
        if parts.len() > cap {
            parts.clear();
        }
        return Some(parts);
    }
    sequence(2, cp, cap)
}
pub fn width(cp: u32) -> u32 {
    sequence(3, cp, 1)
        .and_then(|s| s.first().copied())
        .unwrap_or(cp)
}
pub fn casefold(cp: u32) -> Option<Vec<u32>> {
    if !has(cp, CASEMAP) {
        return None;
    }
    Some(sequence(4, cp, 8).unwrap_or_else(|| vec![cp]))
}
