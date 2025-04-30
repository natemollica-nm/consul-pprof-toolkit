#!/usr/bin/env python3
"""
Enhanced heap-summary.py
  • Accepts a heap.prof file *or* a directory containing one
  • Informs you when go tool pprof fails and shows stderr
  • Retains --allocs, --top, --json features
"""
import argparse, json, shutil, subprocess, tempfile, pathlib, sys, re, collections, os, glob, textwrap

TOP_DEFAULT = 15

def fatal(msg):
    print(f"[ERROR] {msg}", file=sys.stderr)
    sys.exit(1)

def resolve_profile(path: pathlib.Path) -> pathlib.Path:
    """Return a concrete heap.prof file, searching inside directories."""
    if path.is_file():
        return path
    if path.is_dir():
        matches = sorted(path.glob("**/*heap.prof"))
        if not matches:
            fatal(f"No *heap.prof found inside {path}")
        if len(matches) > 1:
            print("[INFO ] multiple heap profiles found, using first. "
                  "Pass the exact file if you need a different one.")
            for m in matches:
                print("    •", m)
        return matches[0]
    fatal(f"{path} is neither file nor directory")

def run_pprof(profile: pathlib.Path, metric: str) -> str:
    """
    metric = "inuse_space" | "alloc_space"
    Uses only one output format (-top) so Go ≤1.21 is happy.
    """
    if shutil.which("go") is None:
        fatal("Go toolchain not in PATH (`go` command missing)")

    cmd = [
        "go", "tool", "pprof",
        "-top",
        f"-{metric}",          # -inuse_space or -alloc_space
        "--nodecount=99999",
        profile
    ]
    try:
        return subprocess.check_output(cmd, text=True, stderr=subprocess.PIPE)
    except subprocess.CalledProcessError as exc:
        print("[ERROR] go tool pprof failed:")
        print(exc.stderr.strip())
        sys.exit(1)

size_re = re.compile(r"([0-9.]+)([kMG]?B)")

def to_bytes(val: str) -> int:
    num, unit = size_re.match(val).groups()
    mult = {"kB":1024,"MB":1024**2,"GB":1024**3}.get(unit,1)
    return int(float(num)*mult)

# ────────────────────────────────────────────────────────────────────────────
parser = argparse.ArgumentParser(
    formatter_class=argparse.RawTextHelpFormatter,
    description=textwrap.dedent("""
    Heap profile quick summary.
    Examples:
        heap-summary.py ../heap.prof
        heap-summary.py --allocs --top 25 ./consul-pprof-run/
    """))
parser.add_argument("profile", type=pathlib.Path,
                    help="heap.prof file OR directory containing one")
parser.add_argument("--allocs", action="store_true",
                    help="sort by allocation bytes instead of live heap")
parser.add_argument("--top", type=int, default=TOP_DEFAULT,
                    help=f"rows to show (default {TOP_DEFAULT})")
parser.add_argument("--json", action="store_true",
                    help="emit JSON instead of text")
args = parser.parse_args()

profile_file = resolve_profile(args.profile)
metric = "alloc_space" if args.allocs else "inuse_space"
pprof_txt = run_pprof(profile_file, metric)

# parse totals from header
total_live = total_idle = None
for line in pprof_txt.splitlines():
    if line.startswith("Total:"):
        nums = size_re.findall(line)
        if len(nums) >= 2:
            total_live, total_idle = (to_bytes("".join(n)) for n in nums[:2])
        break

func_rows, pkg_rows = [], collections.Counter()
table_re = re.compile(r"^\s*([0-9.]+[kMG]?B).*\s+(\S+)$")

for row in pprof_txt.splitlines():
    m = table_re.match(row)
    if not m: continue
    bytes_ = to_bytes(m.group(1))
    fn = m.group(2)
    func_rows.append((bytes_, fn))
    pkg = fn.split("/")[0] if "/" in fn else fn.split(".")[0]
    pkg_rows[pkg] += bytes_

func_rows.sort(reverse=True)
func_rows = func_rows[:args.top]
pkg_rows  = pkg_rows.most_common(args.top)

# ─────────────────────────────── output ────────────────────────────────────
if args.json:
    out = {
        "profile": str(profile_file),
        "mode": "allocs" if args.allocs else "inuse",
        "total_inuse_bytes": total_live,
        "total_idle_bytes":  total_idle,
        "top_functions":[{"bytes":b,"function":f} for b,f in func_rows],
        "top_packages":[{"bytes":b,"package":p} for p,b in pkg_rows],
    }
    json.dump(out, sys.stdout, indent=2)
    sys.exit(0)

def fmt(b): return f"{b/1024/1024:8.2f} MB"

print(f"\nHeap profile: {profile_file}")
print(" Mode :", "allocation bytes" if args.allocs else "live in-use heap")
if total_live:
    print(" Heap :", fmt(total_live), "in-use  (idle ignored)")
print("\nTop functions:")
for b, fn in func_rows:
    print(f"  {fmt(b)}  {fn}")
print("\nTop packages:")
for p, b in pkg_rows:
    print(f"  {fmt(b)}  {p}")
