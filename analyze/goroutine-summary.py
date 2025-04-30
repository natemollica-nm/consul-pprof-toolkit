#!/usr/bin/env python3
"""
goroutine-summary.py

Quick-look diagnostics for goroutine dumps captured via
  curl ... /debug/pprof/goroutine?debug=2   (text)
or
  curl ... /debug/pprof/goroutine           (binary)

If the input is gzip-compressed it is transparently decompressed.
"""

import sys, re, gzip, collections, io, os, subprocess, shutil

TOP_N = 15

###############################################################################
# helpers
###############################################################################
def read_profile(path: str) -> bytes:
    """Return raw bytes, transparently handling gzip."""
    with open(path, "rb") as fh:
        magic = fh.peek(2) if hasattr(fh, "peek") else fh.read(2)
        fh.seek(0)
        data = fh.read()
        if magic.startswith(b"\x1f\x8b"):  # gzip magic
            return gzip.decompress(data)
        return data

def is_text_stack(blob: bytes) -> bool:
    return b"goroutine " in blob and b"\n" in blob

def fatal(msg: str):
    print(f"[ERROR] {msg}", file=sys.stderr)
    sys.exit(1)

###############################################################################
# main
###############################################################################
if len(sys.argv) != 2:
    fatal("Usage: goroutine-summary.py <goroutine.prof>")

raw = read_profile(sys.argv[1])

if not is_text_stack(raw):
    print("[WARN ] input looks binary; falling back to `go tool pprof -top`")
    if shutil.which("go") is None:
        fatal("Go toolchain not in PATH; cannot parse binary pprof")
    # Print top of the binary profile, then exit
    subprocess.run(["go", "tool", "pprof", "-top", sys.argv[1]])
    sys.exit(0)

# --- text mode --------------------------------------------------------------
text = raw.decode(errors="replace")

# split at 'goroutine N ['   (keep state token inside bracket)
stacks = re.split(r"goroutine \d+ \[", text)[1:]

if not stacks:
    fatal("no goroutine stacks found (did you pass ?debug=2 output?)")

total = len(stacks)
state_re = re.compile(r"^([A-Za-z0-9 _,]+)\]:")
states = collections.Counter()
sigs   = collections.Counter()

for stack in stacks:
    # state = first line up to ']:'
    m = state_re.match(stack)
    if m:
        state = m.group(1).split(',')[0].strip()
        states[state] += 1
    # first frame after the blank line = unique signature
    lines = [l for l in stack.splitlines() if l]
    if len(lines) > 1:
        sigs[lines[1].strip()] += 1

###############################################################################
# output
###############################################################################
print(f"\nTotal goroutines: {total}\n")

print("By scheduler state:")
for st, cnt in states.most_common():
    pct = cnt / total * 100
    print(f"  {st:<12} {cnt:>6}  ({pct:5.1f}%)")
print()

print(f"Top {TOP_N} stack signatures:")
for sig, cnt in sigs.most_common(TOP_N):
    pct = cnt / total * 100
    print(f"{cnt:>4} ({pct:5.1f}%)  {sig}")
