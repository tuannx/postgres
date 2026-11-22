# Perf baseline — pgbench

Framework: `pgbench` (`src/bin/pgbench`, built-in TPC-B-like script) against a locally built `postgres` server.

- Baseline: `perf/baseline.json` — real run 2026-11-21, commit `59d1ada`, scale 1, `-c 1 -j 1 -t 1000`: **2091.34 TPS, 0.478 ms avg latency** (repeat run same config: 1612.14 TPS — shared-VM noise ~23%, see caveat in baseline.json).
- Rerun: `./perf/run-perf.sh` — builds (minimal configure, `make -j2`) if needed, inits a throwaway cluster (Unix socket only, fsync off — bench-only), runs the identical pgbench config, prints TPS delta % vs baseline. Verdict: regression >10% = `warn`, >25% = `block`.
- Hot path: builtin TPC-B transaction (UPDATE accounts/tellers/branches, SELECT abalance, INSERT history) through parser/executor/storage.
