# Consul PPROF Toolkit

POSIX‑compliant shell scripts for **capturing** and **diagnosing** runtime profiles on Consul agents/servers.

## Quick start

```bash
git clone https://github.com/natemollica-nm/consul-pprof-toolkit.git
cd consul-pprof-toolkit
./consul-pprof.sh --addr https://server:8500 --token <ACL> --label customerA
# → consul-pprof-2025-04-29T16-31-45Z-customerA.tar.gz
```

## Analyze

```bash
./analyze/pprof-report.sh consul-pprof-*.tar.gz
```

For deeper dives:

```bash
cd analyze
python heap-summary.py PATH/heap.prof
python goroutine-summary.py PATH/goroutine.prof
python compare-heaps.py OLD/heap.prof NEW/heap.prof
```
