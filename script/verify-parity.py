#!/usr/bin/env python3
"""verify-parity.py -- prove a locally-built contract matches a deployed one.

A raw codehash comparison DOES NOT WORK here and reports a mismatch on correct
source: immutables (constructor args, EIP-712 caches) and library link addresses
are written into the runtime at deploy/link time. This masks exactly those
regions -- taken from the Foundry artifact, not guessed -- and compares the rest.
PASS = every differing byte lies inside a declared immutable or link span.
FAIL = a byte differs outside them; that is real and must be explained.

Usage: ./verify-parity.py <artifact.json> <deployed_address> [--rpc URL]

Build first, in the check-pool-size.sh BUILD_PATHS unit, under the DEFAULT
profile (an unlinked build is required so linkReferences is populated).
"""
import json, subprocess, sys
DEFAULT_RPC = "https://ethereum-rpc.publicnode.com"

def fail(msg):
    print(f"  ERROR: {msg}"); sys.exit(2)

def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    rpc = DEFAULT_RPC
    for i, a in enumerate(sys.argv):
        if a == "--rpc" and i + 1 < len(sys.argv): rpc = sys.argv[i + 1]
    if len(args) != 2:
        print(__doc__); sys.exit(2)
    artifact_path, address = args
    try:
        artifact = json.load(open(artifact_path))
    except Exception as e:
        fail(f"cannot read artifact {artifact_path}: {e}")
    db = artifact.get("deployedBytecode") or {}
    built = (db.get("object") or "")[2:]
    if not built:
        fail("artifact has no deployedBytecode.object -- did the build succeed?")
    try:
        out = subprocess.run(["cast", "code", address, "--rpc-url", rpc],
                             capture_output=True, text=True, timeout=120)
    except Exception as e:
        fail(f"cast code failed: {e}")
    if out.returncode != 0:
        fail(f"cast code failed: {out.stderr.strip()}")
    deployed = out.stdout.strip()[2:]
    if not deployed:
        fail(f"no code at {address} -- wrong address or wrong chain?")
    spans = []
    for refs in (db.get("immutableReferences") or {}).values():
        for r in refs:
            spans.append((r["start"], r["length"], "immutable"))
    for source_file, libs in (db.get("linkReferences") or {}).items():
        for lib, refs in libs.items():
            for r in refs:
                spans.append((r["start"], r["length"], f"link:{lib}"))
    spans.sort()
    n_imm = sum(1 for s in spans if s[2] == "immutable")
    print(f"  artifact : {artifact_path}")
    print(f"  deployed : {address}")
    print(f"  built    : {len(built)//2} bytes")
    print(f"  on-chain : {len(deployed)//2} bytes")
    print(f"  masking  : {len(spans)} spans ({n_imm} immutable, {len(spans)-n_imm} link)")
    if len(built) != len(deployed):
        print("  RESULT: FAIL -- length differs. Different source, settings, or")
        print("          compilation unit. Masking cannot explain a length change.")
        sys.exit(1)
    diffs, run = [], None
    for i in range(0, len(built), 2):
        if built[i:i+2] != deployed[i:i+2]:
            b = i // 2
            if run and b == run[1] + 1:
                run = (run[0], b)
            else:
                if run: diffs.append(run)
                run = (b, b)
        elif run:
            diffs.append(run); run = None
    if run: diffs.append(run)
    def inside(d0, d1):
        return any(s <= d0 and d1 < s + ln for s, ln, _ in spans)
    unexplained = [d for d in diffs if not inside(*d)]
    print(f"  differing ranges: {len(diffs)}   outside masked spans: {len(unexplained)}")
    if unexplained:
        print("  RESULT: FAIL -- real differences outside immutables/links:")
        for d0, d1 in unexplained[:20]:
            print(f"    bytes {d0}..{d1}  built={built[d0*2:(d1+1)*2]}  deployed={deployed[d0*2:(d1+1)*2]}")
        if len(unexplained) > 20:
            print(f"    ... and {len(unexplained)-20} more")
        sys.exit(1)
    if not spans and diffs:
        print("  RESULT: FAIL -- differences with no maskable spans declared.")
        sys.exit(1)
    print("  RESULT: PASS -- every difference lies inside a declared immutable or")
    print("          link span. Non-deploy-specific bytecode is identical.")
    sys.exit(0)

if __name__ == "__main__":
    main()
