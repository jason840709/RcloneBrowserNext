#!/usr/bin/env python3
"""Reproduce the Swift 6.1.2 CoreFoundation Unicode tables used by the Rust string comparison."""
from concurrent.futures import ThreadPoolExecutor
from functools import lru_cache
from pathlib import Path
from urllib.request import urlopen
import hashlib
import json
import re
import struct

import argparse
ROOT = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--output-dir", type=Path, default=ROOT / "Sources/Rust/src/platform_text")
args = parser.parse_args()
HERE = args.output_dir.resolve()
HERE.mkdir(parents=True, exist_ok=True)
EXPECTED = {'CFUniCharBitmapData.inc.h': 'd24a9e5fb1124d1c532c2cd25f96ee4a430d74ef9d179e5b837bbed1e790a1bf', 'CFUniCharDecompositionData.inc.h': 'f8929fa45c51db54cc5860f822801f8135ce2fedfb90463875367e5e2bf8994a', 'CFUniCharCompatibilityDecompositionData.inc.h': '1b82b69a99f6f2c9f8daa1481679ec76d2a70e4d73a10bb94222852c854faf70', 'CFUnicodeCaseMapping-L.inc.h': '78c4e87cfea2ade6d2a3ffb15b508334b6d6d09a490bf5fc8aca6a1eb44e67e2', 'CFUniCharPropertyDatabase.inc.h': 'a441a3fa5a7883d629c9463784e19533e26b576c6ceb71cf725646c2ba7239ad'}
BASE = "https://raw.githubusercontent.com/swiftlang/swift-corelibs-foundation/swift-6.1.2-RELEASE/Sources/CoreFoundation/internalInclude/"
FILES = ["CFUniCharBitmapData.inc.h", "CFUniCharDecompositionData.inc.h", "CFUniCharCompatibilityDecompositionData.inc.h",
         "CFUnicodeCaseMapping-L.inc.h", "CFUniCharPropertyDatabase.inc.h"]
def fetch(name):
    with urlopen(BASE + name, timeout=30) as response:
        content = response.read()
    if hashlib.sha256(content).hexdigest() != EXPECTED[name]:
        raise ValueError("Pinned CoreFoundation input changed: " + name)
    return content
with ThreadPoolExecutor(5) as pool:
    sources = dict(zip(FILES, pool.map(fetch, FILES)))
def array(source, name):
    raw = sources[source].decode()
    m = re.search(r'\b__CFUniChar'+name+r'\[\]\s*=\s*\{([^}]+)\}', raw, re.S)
    assert m, name
    return [int(n,16) for n in re.findall(r'0x([0-9a-fA-F]+)', m[1])]
def mapping(file, table, extra):
    data = array(file, table)
    extras = array(file, extra)
    result = {}
    for cp, v in zip(data[::2], data[1::2]):
        count = (v >> 24) & 31
        low = v & 0xffffff
        vals = [low] if count == 1 else extras[low:low+count]
        assert len(vals) == count and count
        result[cp] = (vals, bool(v & 0x40000000))
    return result

props = bytearray(0x110000)
names = ["NonBaseCharacterSet","AlphanumericCharacterSet","PunctuationCharacterSet","ControlAndFormatter","GraphemeExtendCharacterSet",
         "CanonicalDecomposableCharacterSet","HasNonSelfLowercaseMapping","HasNonSelfCaseFoldingMapping"]
all_sets = sources[FILES[0]].decode()
for flag,name in enumerate(names):
    planes = re.findall(r'__CFUniChar'+name+r'BitmapPlane(\d+)\[\]', all_sets)
    assert planes, name
    for plane in planes:
        raw = array(FILES[0], name+'BitmapPlane'+plane)
        assert len(raw)==8192
        base = int(plane)*65536
        for idx, octet in enumerate(raw):
            for bit in range(8):
                if octet & (1<<bit): props[base+idx*8+bit] |= (1<<flag)
def ranges(values):
    prev=0; start=0; out=[]
    for i,cur in enumerate(values):
        if cur != prev:
            if prev: out.append((start,i-1,prev))
            start=i; prev=cur
    if prev: out.append((start,len(values)-1,prev))
    return out
classes=bytearray(0x110000)
for plane in [0,1]:
    data=array(FILES[4],'CombiningPriorityTablePlane'+str(plane))
    for idx in range(65536):
        page=data[idx>>8]
        if page: classes[plane*65536+idx]=data[256+(page-1)*256+(idx&255)]
canon=mapping(FILES[1],'DecompositionTable','MultipleDecompositionTable')
compat=mapping(FILES[2],'CompatibilityDecompositionTable','CompatibilityMultipleDecompositionTable')
fold=mapping(FILES[3],'ToLowercaseMappingTable','ToLowercaseMappingExtraTable')
fold.update(mapping(FILES[3],'CaseFoldMappingTable','CaseFoldMappingExtraTable'))
@lru_cache(None)
def canonical(cp):
    seq, recursive=canon[cp]
    if recursive:
        first, required=canonical(seq[0])
        return first + seq[1:], required+len(seq)
    return seq, len(seq)
@lru_cache(None)
def width(cp):
    out=[]
    for scalar in compat.get(cp,([cp],False))[0]:
        if scalar in canon: out.extend(canonical(scalar)[0])
        elif scalar != cp and scalar in compat: out.extend(width(scalar))
        else: out.append(scalar)
    return out
def triples(rows):
    return b''.join(struct.pack('<III',*r) for r in rows)
scalars=[]; indices=[]
def mapindex(items):
    rows=[]
    for k,(seq,minimum) in sorted(items):
        rows.append((k,len(scalars),len(seq)|(minimum<<8)))
        scalars.extend(seq)
    return triples(rows)
sections=[triples(ranges(props)),triples(ranges(classes)),
          mapindex((k,canonical(k)) for k in canon),
          mapindex((k,(v,1)) for k in range(0xff00,0xfff0) if (v:=width(k))!=[k] and len(v)==1),
          mapindex((k,(v,1)) for k,(v,_) in fold.items()),
          b''.join(struct.pack('<I',n) for n in scalars)]
offsets=[4*(len(sections)+1)]
for s in sections: offsets.append(offsets[-1]+len(s))
out=struct.pack('<7I',*offsets)+b''.join(sections)
(HERE/'foundation-data.bin').write_bytes(out)
(HERE/'foundation-data-sources.json').write_text(json.dumps({'upstream':BASE,'files':{k:hashlib.sha256(v).hexdigest() for k,v in sources.items()},'generatedSha256':hashlib.sha256(out).hexdigest(),'bytes':len(out)},indent=2)+'\n')

