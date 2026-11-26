// Comparison schedule from Swift 6.1.2 stdlib/public/core/Sort.swift.
// Copyright Apple Inc. and Swift project authors. See ../../../../Compat/licenses/Swift-LICENSE.txt.
// Foundation's numeric comparator can be non-transitive; preserving the sequence of
// comparisons also preserves the old result when the enumeration order is identical.
use std::cmp::Ordering;
use std::ops::Range;

fn insertion(
    order: &mut [usize],
    first: usize,
    sorted: usize,
    limit: usize,
    less: &mut impl FnMut(usize, usize) -> bool,
) {
    for index in sorted..limit {
        let mut i = index;
        while i > first && less(order[i], order[i - 1]) {
            order.swap(i, i - 1);
            i -= 1;
        }
    }
}

fn merge(
    order: &mut [usize],
    runs: &mut Vec<Range<usize>>,
    idx: usize,
    buf: &mut Vec<usize>,
    less: &mut impl FnMut(usize, usize) -> bool,
) {
    let (lo, mid, hi) = (runs[idx - 1].start, runs[idx].start, runs[idx].end);
    buf.clear();
    if mid - lo < hi - mid {
        buf.extend_from_slice(&order[lo..mid]);
        let (mut target, mut left, mut right) = (lo, 0, mid);
        while left < buf.len() && right < hi {
            if less(order[right], buf[left]) {
                order[target] = order[right];
                right += 1;
            } else {
                order[target] = buf[left];
                left += 1;
            }
            target += 1;
        }
        order[target..target + buf.len() - left].copy_from_slice(&buf[left..]);
    } else {
        buf.extend_from_slice(&order[mid..hi]);
        let (mut target, mut left, mut right) = (hi, mid, buf.len());
        while right > 0 && left > lo {
            target -= 1;
            if less(buf[right - 1], order[left - 1]) {
                left -= 1;
                order[target] = order[left];
            } else {
                right -= 1;
                order[target] = buf[right];
            }
        }
        order[target - right..target].copy_from_slice(&buf[..right]);
    }
    runs[idx - 1].end = hi;
    runs.remove(idx);
}

pub fn swift_order(n: usize, mut less: impl FnMut(usize, usize) -> bool) -> Vec<usize> {
    let mut order: Vec<usize> = (0..n).collect();
    if n < 2 {
        return order;
    }
    let shift = (usize::BITS - n.leading_zeros()).saturating_sub(6);
    let minimum = (n >> shift) + usize::from(n & ((1 << shift) - 1) != 0);
    if n <= minimum {
        insertion(&mut order, 0, 1, n, &mut less);
        return order;
    }
    let mut buf = Vec::with_capacity(n / 2);
    let mut runs: Vec<Range<usize>> = Vec::new();
    let mut start = 0;
    while start < n {
        let mut end = start + 1;
        if end < n {
            let descending = less(order[end], order[start]);
            end += 1;
            while end < n && less(order[end], order[end - 1]) == descending {
                end += 1;
            }
            if descending {
                order[start..end].reverse();
            }
        }
        if end < n && end - start < minimum {
            let next = (start + minimum).min(n);
            insertion(&mut order, start, end, next, &mut less);
            end = next;
        }
        runs.push(start..end);
        while runs.len() > 1 {
            let i = runs.len() - 1;
            let old_three = i >= 3 && runs[i - 3].len() <= runs[i - 2].len() + runs[i - 1].len();
            let top_three = i >= 2 && runs[i - 2].len() <= runs[i - 1].len() + runs[i].len();
            let idx = if old_three || top_three {
                if runs[i - 2].len() < runs[i].len() {
                    i - 1
                } else {
                    i
                }
            } else if runs[i - 1].len() <= runs[i].len() {
                i
            } else {
                break;
            };
            merge(&mut order, &mut runs, idx, &mut buf, &mut less);
        }
        start = end;
    }
    while runs.len() > 1 {
        let i = runs.len() - 1;
        merge(&mut order, &mut runs, i, &mut buf, &mut less);
    }
    order
}

pub fn swift_sort_by<T>(values: &mut [T], mut compare: impl FnMut(&T, &T) -> Ordering) {
    let order = swift_order(values.len(), |i, j| {
        compare(&values[i], &values[j]) == Ordering::Less
    });
    let mut destination = vec![0; values.len()];
    for (new, old) in order.into_iter().enumerate() {
        destination[old] = new;
    }
    for i in 0..values.len() {
        while destination[i] != i {
            let j = destination[i];
            values.swap(i, j);
            destination.swap(i, j);
        }
    }
}
