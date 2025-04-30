#!/usr/bin/env python3
"""
compare-heaps.py  old_path  new_path  [--allocs]

* old_path / new_path can each be:
      • a heap.prof file
      • a directory containing one (first match is used)

* Shows functions with the largest positive delta (growth) between profiles.

Options
-------
  --allocs   compare cumulative allocation bytes (default = live in-use heap)
"""

import argparse, collections, pathlib, shutil, subprocess, sys, re

###############################################################################
# helpers
###############################################################################
def fatal(msg: str):
    print("[ERROR]", msg, file=sys.stderr); sys.exit(1)

def resolve_heap(path: pathlib.Path) -> pathlib.Path:
    if path.is_file():
        return path
    if path.is_dir():
        matches = sorted(path.glob("**/*heap.prof"))
        if not matches:
            fatal(f"No *heap.prof in {path}")
        if len(matches) > 1:
            print("[INFO ] multiple heaps in", path, "— using", matches[0])
        return matches[0]
    fatal(f"{path} is neither file nor directory")

def call_pprof(profile: pathlib.Path, metric: str) -> str:
    """Return `go tool pprof -top` output sorted by metric."""
    if shutil.which("go") is None:
        fatal("Go toolchain not in PATH")
    cmd = [
        "go","tool","pprof",
        "-top",
        f"-{metric}",
        "--nodecount=99999",
        profile
    ]
    try:
        return subprocess.check_output(cmd, text=True, stderr=subprocess.PIPE)
    except subprocess.CalledProcessError as exc:
        fatal(f"go tool pprof failed on {profile}:\n{exc.stderr}")

# extract "bytes  func" rows
row_re = re.compile(r"^\s*([0-9.]+)([kMG]?B)\s+.*\s+(\S+)$")
unit_mult = {"kB":1024,"MB":1024**2,"GB":1024**3}

def to_bytes(num: str, unit: str) -> int:
    return int(float(num)*unit_mult.get(unit,1))

def parse_pprof(text: str) -> dict[str,int]:
    m = {}
    for line in text.splitlines():
        r = row_re.match(line)
        if not r: continue
        b = to_bytes(r.group(1), r.group(2))
        func = r.group(3)
        m[func] = b
    return m

def fmt(b): return f"{b/1024/1024:8.2f} MB"

###############################################################################
# CLI
###############################################################################
parser = argparse.ArgumentParser()
parser.add_argument("old", type=pathlib.Path)
parser.add_argument("new", type=pathlib.Path)
parser.add_argument("--allocs", action="store_true",
                    help="compare allocation bytes instead of live heap")
parser.add_argument("--top", type=int, default=20,
                    help="rows to show (default 20)")
args = parser.parse_args()

metric = "alloc_space" if args.allocs else "inuse_space"
old_heap = resolve_heap(args.old)
new_heap = resolve_heap(args.new)

print("[INFO ] comparing", old_heap, "→", new_heap,
      f"using metric {metric}")

old_map = parse_pprof(call_pprof(old_heap, metric))
new_map = parse_pprof(call_pprof(new_heap, metric))

delta = collections.Counter()
for fn, new_b in new_map.items():
    delta[fn] = new_b - old_map.get(fn, 0)

print("\nTop growth:")
for fn, diff in delta.most_common(args.top):
    if diff <= 0: break
    print(f"  +{fmt(diff)}  {fn}")

print("\nTop shrink:")
for fn, diff in delta.most_common()[:args.top][::-1]:
    if diff >= 0: continue
    print(f"  {fmt(diff)}  {fn}")
