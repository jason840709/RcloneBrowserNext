#!/usr/bin/env python3
"""Extract only properties read by the frozen grapheme routine, using UCD 15.1."""
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
from urllib.request import urlopen
from hashlib import sha256
import json, re, struct
import argparse
PROJECT=Path(__file__).resolve().parents[1]
parser=argparse.ArgumentParser(description=__doc__)
parser.add_argument("--output-dir", type=Path, default=PROJECT / "Sources/Rust/src/platform_text")
args=parser.parse_args()
HERE=args.output_dir.resolve()
HERE.mkdir(parents=True, exist_ok=True)
EXPECTED={'https://raw.githubusercontent.com/swiftlang/swift-corelibs-foundation/swift-6.1.2-RELEASE/Sources/CoreFoundation/internalInclude/CFUniCharBitmapData.inc.h': 'd24a9e5fb1124d1c532c2cd25f96ee4a430d74ef9d179e5b837bbed1e790a1bf', 'https://www.unicode.org/Public/15.1.0/ucd/DerivedCoreProperties.txt': 'f55d0db69123431a7317868725b1fcbf1eab6b265d756d1bd7f0f6d9f9ee108b', 'https://www.unicode.org/Public/15.1.0/ucd/emoji/emoji-data.txt': 'd7aef489c8fe4c14f09ea5695200277c6b93ac82ac60845cdd2161b0d6835cc1', 'https://www.unicode.org/Public/15.1.0/ucd/auxiliary/GraphemeBreakProperty.txt': 'a7e52eee647e52dc210b8719b4d7037276f4b353810293d69377fc46374cec3f', 'https://raw.githubusercontent.com/unicode-org/icu/release-74-2/LICENSE': '17510cf7a58b4879b887ec05a45d72cf1b73544dd9ec7e72f20110ed104229ee'}
ROOT="https://www.unicode.org/Public/15.1.0/ucd/"
SOURCES={"letters":"https://raw.githubusercontent.com/swiftlang/swift-corelibs-foundation/swift-6.1.2-RELEASE/Sources/CoreFoundation/internalInclude/CFUniCharBitmapData.inc.h",
         "grapheme":ROOT+"DerivedCoreProperties.txt","emoji":ROOT+"emoji/emoji-data.txt",
         "boundaries":ROOT+"auxiliary/GraphemeBreakProperty.txt",
         "unicodeLicense":"https://raw.githubusercontent.com/unicode-org/icu/release-74-2/LICENSE"}
def fetch(url):
    with urlopen(url,timeout=40) as r: content=r.read()
    if sha256(content).hexdigest()!=EXPECTED[url]:
        raise ValueError("Pinned Unicode input changed: "+url)
    return content
with ThreadPoolExecutor(5) as pool: data=dict(zip(SOURCES,pool.map(fetch,SOURCES.values())))
props=bytearray(0x110000)
for plane,text in re.findall(r'__CFUniCharLetterCharacterSetBitmapPlane(\d+)\[\]\s*=\s*\{([^}]+)\}',data["letters"].decode(),re.S):
    row=bytes(int(v,16) for v in re.findall(r'0x([0-9a-fA-F]+)',text));assert len(row)==8192
    for i,octet in enumerate(row):
        for bit in range(8):
            if octet & (1<<bit):props[int(plane)*65536+i*8+bit] |= 1
flags={"Grapheme_Extend":2,"Emoji_Modifier":4,"Extended_Pictographic":8,"Prepend":16,"SpacingMark":32}
for name in ["grapheme","emoji","boundaries"]:
    for raw in data[name].decode().splitlines():
        fields=raw.partition("#")[0].strip().split(";")
        if len(fields)!=2 or (key:=fields[1].strip()) not in flags:continue
        lo,*hi=fields[0].strip().split(".."); a=int(lo,16); b=int(hi[0],16) if hi else a
        for i in range(a,b+1):props[i] |= flags[key]
assert props[ord("A")]==1 and props[0x0308]&2 and props[0x1f3fb]&4 and props[0x1f600]&8 and props[0x0600]&16 and props[0x0903]&32
out=bytearray();prev=0;start=0
for i,v in enumerate(props+b'\0'):
    if v!=prev:
        if prev:out.extend(struct.pack("<IIB",start,i-1,prev))
        prev=v;start=i
(HERE/"cluster-data.bin").write_bytes(out)
license_path=PROJECT/"Compat/licenses/ICU-LICENSE.txt"
if not license_path.is_file() or license_path.read_bytes()!=data["unicodeLicense"]:
    raise ValueError("Retain the pinned original Unicode license before regenerating data")
(HERE/"cluster-data-sources.json").write_text(json.dumps({"dataVersion":"15.1.0","files":{k:{"url":u,"sha256":sha256(data[k]).hexdigest()} for k,u in SOURCES.items()},"bytes":len(out),"generatedSha256":sha256(out).hexdigest()},indent=2)+"\n")
