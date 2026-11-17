#!/bin/bash

# SPDX-FileCopyrightText: Copyright (c) 2026, NVIDIA CORPORATION.
# SPDX-License-Identifier: Apache-2.0

# Compares the Presto native CPU worker with the native GPU worker built with
# --with-cugeo on the spatial queries in presto/cugeo_comparison/*.sql, over
# SpatialBench data from generate_spatialbench_data.sh.
#
#   run_cugeo_comparison.sh -s 10 [-r 5] [-v 0.3.0] [-q building_trips] [-o DIR]
#
# Registers the tables of presto/cugeo_comparison/tables.json in schema
# hive.spatialbench_sf<N>, with the cuGeo column declarations in the file
# metastore, then for each worker (CPU first) starts its cluster (replacing any
# running Presto), runs each query once to warm up and -r more times, and stops
# it. It prints, per query, the median elapsed time of each worker and whether
# the answers agree: every value exactly, except DOUBLEs to a relative 1e-9
# (summation order differs), and that cuGeo's operators ran on the GPU worker.
# Each run's rows and Presto's query statistics go to -o (default
# cugeo_comparison_results/sf<N>-<date> under this directory). Exits nonzero
# when an answer differs or cuGeo did not run.
#
# Needs PRESTO_DATA_DIR and the Presto CLI jar from the Presto Java build.

set -euo pipefail

SCALE=""
RUNS=5
VERSION=0.3.0
QUERIES=""
OUT=""
while getopts "s:r:v:q:o:" option; do
  case "${option}" in
    s) SCALE="${OPTARG}" ;;
    r) RUNS="${OPTARG}" ;;
    v) VERSION="${OPTARG}" ;;
    q) QUERIES="${OPTARG}" ;;
    o) OUT="${OPTARG}" ;;
    *) echo "usage: $0 -s <scale factor> [-r runs] [-v generator version] [-q query] [-o dir]" >&2; exit 1 ;;
  esac
done
[[ -n "${SCALE}" ]] || { echo "usage: $0 -s <scale factor> [-r runs] [-v generator version] [-q query] [-o dir]" >&2; exit 1; }
: "${PRESTO_DATA_DIR:?PRESTO_DATA_DIR must be set}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git -C "${SCRIPT_DIR}" rev-parse --show-toplevel)"
COMPARISON="${SCRIPT_DIR}/../cugeo_comparison"
CLI_JAR="${REPO_ROOT}/../presto/docker/presto-cli-testing-executable.jar"
METASTORE="${SCRIPT_DIR}/../docker/.hive_metastore"
SCHEMA="spatialbench_sf${SCALE//./_}"
DATA="spatialbench/v${VERSION}/sf${SCALE}"
OUT="${OUT:-${SCRIPT_DIR}/cugeo_comparison_results/sf${SCALE}-$(date +%Y%m%d-%H%M%S)}"
[[ -d "${PRESTO_DATA_DIR}/${DATA}" ]] || { echo "ERROR: ${PRESTO_DATA_DIR}/${DATA} not found" >&2; exit 1; }
[[ -f "${CLI_JAR}" ]] || { echo "ERROR: ${CLI_JAR} not found" >&2; exit 1; }
QUERIES="${QUERIES:-$(cd "${COMPARISON}" && ls *.sql | sed 's/\.sql$//' | tr '\n' ' ')}"
mkdir -p "${OUT}"

cli() {
  docker exec presto-coordinator java -jar /tmp/presto-cli.jar --server localhost:8080 --catalog hive \
    --schema "${SCHEMA}" "$@" 2>&1
}
start() {
  "${SCRIPT_DIR}/start_native_$1_presto.sh" > "${OUT}/start-$1.log" 2>&1
  docker cp "${CLI_JAR}" presto-coordinator:/tmp/presto-cli.jar > /dev/null
  for _ in $(seq 1 60); do
    [[ "$(cli --execute "SELECT count(*) FROM system.runtime.nodes WHERE coordinator = false" | tr -d '"' | tail -1)" == 1 ]] &&
      return 0
    sleep 5
  done
  echo "ERROR: no $1 worker registered" >&2
  exit 1
}
trap '"${SCRIPT_DIR}/stop_presto.sh" > /dev/null 2>&1' EXIT

start cpu
echo "Registering the tables in hive.${SCHEMA} (${PRESTO_DATA_DIR}/${DATA})"
cli --execute "CREATE SCHEMA IF NOT EXISTS hive.${SCHEMA}" > /dev/null
python3 - "${COMPARISON}/tables.json" "${DATA}" <<'PY' | while IFS= read -r statement; do cli --execute "${statement}" > /dev/null; done
import json, sys
tables, data = json.load(open(sys.argv[1])), sys.argv[2]
for table, spec in tables.items():
    columns = ", ".join(f"{name} {kind}" for name, kind in spec["columns"])
    location = f"file:/var/lib/presto/data/hive/data/user_data/{data}/{table}"
    print(f"DROP TABLE IF EXISTS {table}")
    print(f"CREATE TABLE {table} ({columns}) WITH (format = 'PARQUET', external_location = '{location}')")
PY
"${SCRIPT_DIR}/stop_presto.sh" > /dev/null 2>&1

# Presto's SQL can't set arbitrary Hive table properties, so they go into the
# file metastore's table records, which the containers own.
docker run --rm -v "${METASTORE}/${SCHEMA}:/schema" -v "${COMPARISON}/tables.json:/tables.json:ro" \
  "${DEPS_IMAGE:-presto/prestissimo-dependency:centos9-${USER:-latest}}" python3 -c '
import json, os
for table, spec in json.load(open("/tables.json")).items():
    record = f"/schema/{table}/.prestoSchema"
    data = json.load(open(record))
    data["parameters"] = {k: v for k, v in data["parameters"].items() if not k.startswith("cugeo.")}
    data["parameters"].update(spec["properties"])
    json.dump(data, open(record, "w"), indent=2)
    checksum = f"/schema/{table}/..prestoSchema.crc"
    if os.path.exists(checksum):
        os.remove(checksum)
'

export -f cli
export SCHEMA
for worker in cpu gpu; do
  start "${worker}"
  for query in ${QUERIES}; do
    for run in $(seq 0 "${RUNS}"); do
      # The CLI exits nonzero on a failed query; the report records the failure.
      output="$(cli --debug --execute "$(cat "${COMPARISON}/${query}.sql")" || true)"
      id="$(echo "${output}" | grep -oE '[0-9]{8}_[0-9]{6}_[0-9]{5}_[a-z0-9]{5}' | head -1)"
      echo "${output}" | grep '^"' > "${OUT}/${worker}-${query}-${run}.csv" || true
      docker exec presto-coordinator curl -s "localhost:8080/v1/query/${id}" > "${OUT}/${worker}-${query}-${run}.json"
      echo "${worker} ${query} run ${run}: $(python3 -c "
import json, sys
info = json.load(open(sys.argv[1]))
error = info.get('failureInfo') or {}
print(info['queryStats']['elapsedTime'], info['state'], error.get('message', ''))" "${OUT}/${worker}-${query}-${run}.json")"
    done
  done
  "${SCRIPT_DIR}/stop_presto.sh" > /dev/null 2>&1
done

python3 - "${OUT}" "${RUNS}" ${QUERIES} <<'PY'
import csv, json, math, re, statistics, sys
out, runs, queries = sys.argv[1], int(sys.argv[2]), sys.argv[3:]
units = {"ns": 1e-9, "us": 1e-6, "ms": 1e-3, "s": 1, "m": 60, "h": 3600, "d": 86400}
def seconds(text):
    number, unit = re.fullmatch(r"([\d.]+)([a-z]+)", text).groups()
    return float(number) * units[unit]
def rows(worker, query, run):
    return [row for row in csv.reader(open(f"{out}/{worker}-{query}-{run}.csv"))]
def same(a, b):
    if a == b:
        return True
    try:
        x, y = float(a), float(b)
    except ValueError:
        return False
    return math.isclose(x, y, rel_tol=1e-9, abs_tol=0.0) or (math.isnan(x) and math.isnan(y))
report, failed = {}, False
print(f"\n{'query':18} {'CPU median s':>13} {'GPU median s':>13} {'speedup':>8}  answers  cuGeo")
for query in queries:
    entry = {}
    for worker in ("cpu", "gpu"):
        info = [json.load(open(f"{out}/{worker}-{query}-{run}.json")) for run in range(1, runs + 1)]
        entry[worker] = {"state": sorted({i["state"] for i in info}),
                         "elapsed_s": [seconds(i["queryStats"]["elapsedTime"]) for i in info]}
        entry[worker]["median_s"] = statistics.median(entry[worker]["elapsed_s"])
    cpu, gpu = rows("cpu", query, 1), rows("gpu", query, 1)
    agree = len(cpu) == len(gpu) and all(len(a) == len(b) and all(same(x, y) for x, y in zip(a, b)) for a, b in zip(cpu, gpu))
    agree = agree and len(cpu) > 0
    operators = {o["operatorType"] for o in json.load(open(f"{out}/gpu-{query}-1.json"))["queryStats"]["operatorSummaries"]}
    cugeo = sorted(o for o in operators if o.startswith("CuGeo"))
    states_ok = entry["cpu"]["state"] == ["FINISHED"] and entry["gpu"]["state"] == ["FINISHED"]
    entry.update(answers_agree=agree, cugeo_operators=cugeo, rows=len(cpu),
                 gpu_errors=sorted({(json.load(open(f"{out}/gpu-{query}-{run}.json")).get("failureInfo") or {}).get("message", "")
                                    for run in range(1, runs + 1)} - {""}))
    failed = failed or not (agree and cugeo and states_ok)
    report[query] = entry
    print(f"{query:18} {entry['cpu']['median_s']:13.3f} {entry['gpu']['median_s']:13.3f} "
          f"{entry['cpu']['median_s'] / entry['gpu']['median_s']:7.1f}x  {'agree' if agree else 'DIFFER':7}  "
          f"{', '.join(cugeo) if cugeo else 'NONE'}{'' if states_ok else '  (a run failed: ' + '; '.join(entry['gpu_errors']) + ')'}")
json.dump(report, open(f"{out}/report.json", "w"), indent=1)
print(f"\nDetails in {out}")
sys.exit(1 if failed else 0)
PY
