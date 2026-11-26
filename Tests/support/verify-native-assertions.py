#!/usr/bin/env python3
"""Keep the original native assertions; launch-adapter edits are exact allowlists."""
from pathlib import Path
import argparse, collections, hashlib, json, sys
ROOT=Path(__file__).resolve().parents[2]
def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--partial-log',type=Path)
    p.add_argument('--output',type=Path)
    args=p.parse_args()
    receipt=json.loads((ROOT/'Tests/fixtures/mac-native-assertion-source.json').read_text())
    verified=[]
    for name,row in receipt['files'].items():
        text=(ROOT/name).read_text()
        for edit in row['normalizations']:
            if text.count(edit['new']) != 1: raise RuntimeError(f'Launch adapter changed outside its reviewable allowlist: {name}')
            text=text.replace(edit['new'],edit['baseline'],1)
        if hashlib.sha256(text.encode()).hexdigest() != row['baselineSHA256']:
            raise RuntimeError(f'Original test source/assertion changed: {name}')
        verified.append(name)
    evidence={'originalSourcesVerified':verified,'partialRuntimePassed':False}
    if args.partial_log:
        mapping=json.loads((ROOT/'Tests/fixtures/mac-partial-assertion-map.json').read_text())
        source=ROOT/mapping['source']
        if hashlib.sha256(source.read_bytes()).hexdigest()!=mapping['sourceSHA256']: raise RuntimeError('Partial source checksum differs from its case map')
        wanted=collections.Counter(row['name'] for row in mapping['cases'])
        lines=args.partial_log.read_text().splitlines()
        passed=collections.Counter(line[5:] for line in lines if line.startswith('PASS '))
        failures=[line for line in lines if line.startswith('FAIL ')]
        if failures or passed!=wanted:
            raise RuntimeError(f'Original partial assertions incomplete: failures={failures}; missing={list((wanted-passed).elements())}; unexpected={list((passed-wanted).elements())}')
        evidence.update(partialRuntimePassed=True,partialCasesPassed=sum(passed.values()))
    if args.output: args.output.write_text(json.dumps(evidence,indent=2)+'\n')
    print(f"Verified unchanged assertions in {len(verified)} native/local test sources" + ('; all 29 original partial cases passed' if args.partial_log else '; runtime results are separate'))
if __name__=='__main__':
    try: main()
    except Exception as error: print(f'FAIL assertion source gate: {error}',file=sys.stderr);sys.exit(1)
