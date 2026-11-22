#!/bin/bash
# Rerun pgbench baseline for tuannx/postgres and compare TPS to perf/baseline.json
# Config (must match baseline): pgbench -i -s 1, then pgbench -c 1 -j 1 -t 1000
# Verdict: regression >10% = warn, >25% = block, otherwise pass (improvement reported as %)
# Caveat: shared VM noise is high (~23% observed between identical runs) - re-run before acting on a warn.
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$REPO_ROOT/perf/.work"
BUILD="$WORK/build"; INSTALL="$WORK/install"
export TMPDIR="$WORK/tmp"; mkdir -p "$BUILD" "$TMPDIR"

if [ ! -x "$INSTALL/bin/pgbench" ]; then
  echo "== building postgres (minimal configure, make -j2) =="
  command -v bison >/dev/null && command -v flex >/dev/null || { echo "need bison+flex: apt-get install -y bison flex libreadline-dev"; exit 2; }
  (cd "$BUILD" && "$REPO_ROOT/configure" --prefix="$INSTALL" --without-icu --without-zstd --without-lz4 \
    --without-openssl --without-libxml --without-libxslt --without-perl --without-python --without-tcl \
    --disable-cassert --disable-debug CFLAGS="-O2" >/dev/null)
  make -j2 -s -C "$BUILD" && make -s -C "$BUILD" install
fi

# postgres refuses to run as root: if root, stage install+data under unprivileged user pgperf
RUNNER=""; BIN="$INSTALL/bin"; DATA="$WORK/pgdata"; SOCK="$WORK/sock"
if [ "$(id -u)" = "0" ]; then
  id pgperf >/dev/null 2>&1 || useradd -m -s /bin/bash pgperf
  rm -rf /home/pgperf/install; cp -a "$INSTALL" /home/pgperf/install; chown -R pgperf:pgperf /home/pgperf/install
  cat > /home/pgperf/inner.sh <<'INNER'
#!/bin/bash
set -e; export LD_LIBRARY_PATH=/home/pgperf/install/lib TMPDIR=/home/pgperf/tmp
BIN=/home/pgperf/install/bin; DATA=/home/pgperf/pgdata; SOCK=/home/pgperf/run; PORT=55433
rm -rf "$DATA"; mkdir -p "$DATA" "$SOCK" "$TMPDIR"; chmod 700 "$DATA"
$BIN/initdb -D "$DATA" -U postgres --no-instructions >/dev/null 2>&1
$BIN/pg_ctl -D "$DATA" -l /home/pgperf/server.log -o "-k $SOCK -p $PORT -c listen_addresses='' -c fsync=off -c synchronous_commit=off -c shared_buffers=128MB -c max_connections=20" start >/dev/null
trap "$BIN/pg_ctl -D $DATA stop >/dev/null 2>&1 || true" EXIT
$BIN/pgbench -h "$SOCK" -p $PORT -U postgres -i -s 1 postgres >/dev/null 2>&1
$BIN/pgbench -h "$SOCK" -p $PORT -U postgres -c 1 -j 1 -t 1000 postgres 2>&1 | tee /home/pgperf/bench.log
INNER
  chmod +x /home/pgperf/inner.sh; chown pgperf:pgperf /home/pgperf/inner.sh
  su pgperf -c /home/pgperf/inner.sh | tee "$WORK/last-run.log"
else
  mkdir -p "$DATA" "$SOCK"; chmod 700 "$DATA"
  "$BIN/initdb" -D "$DATA" -U postgres --no-instructions >/dev/null 2>&1 || true
  "$BIN/pg_ctl" -D "$DATA" -l "$WORK/server.log" -o "-k $SOCK -p 55433 -c listen_addresses='' -c fsync=off -c synchronous_commit=off -c shared_buffers=128MB -c max_connections=20" start
  trap '"$BIN/pg_ctl" -D "$DATA" stop >/dev/null 2>&1 || true' EXIT
  "$BIN/pgbench" -h "$SOCK" -p 55433 -U postgres -i -s 1 postgres >/dev/null 2>&1
  "$BIN/pgbench" -h "$SOCK" -p 55433 -U postgres -c 1 -j 1 -t 1000 postgres 2>&1 | tee "$WORK/last-run.log"
fi

python3 - "$REPO_ROOT/perf/baseline.json" "$WORK/last-run.log" <<'PY'
import json, re, sys
base = json.load(open(sys.argv[1])); log = open(sys.argv[2]).read()
m = re.search(r"tps = ([0-9.]+)", log); lat = re.search(r"latency average = ([0-9.]+) ms", log)
if not m: print("verdict: block (no tps in pgbench output)"); sys.exit(1)
tps, b = float(m.group(1)), float(base["results"]["baseline_tps"])
delta = (tps - b) / b * 100
verdict = "block" if delta < -25 else "warn" if delta < -10 else "pass"
print(f"tps: {tps:.3f}  baseline: {b:.3f}  delta: {delta:+.2f}%  latency_avg_ms: {lat.group(1) if lat else '?'}")
print(f"verdict: {verdict}" + (" (improvement)" if delta > 0 else ""))
PY
