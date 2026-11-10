#!/bin/bash

# SPDX-FileCopyrightText: Copyright (c) 2026, NVIDIA CORPORATION.
# SPDX-License-Identifier: Apache-2.0

# Runs cuGeo's Presto end-to-end check on the native GPU worker built with
# --with-cugeo. cuGeo's backends/cugeo-presto/tools/presto-end-to-end.py writes
# the dataset, and its tests/fixtures/presto-end-to-end.json holds the tables'
# properties, the queries, the PostGIS reference's rows and the queries that must
# fail. The script starts the GPU cluster (replacing any running Presto),
# registers the tables in schema hive.cugeo_end_to_end, writes the properties into
# the file metastore, runs the queries, and stops the cluster. It exits 0 when
# every query returns the fixture's rows through cuGeo's operators and every
# failure fails with its message.
#
# Needs PRESTO_DATA_DIR, the cuGeo clone (CUGEO_DIR, default ../cugeo beside this
# repository) with uv, and the Presto CLI jar from the Presto Java build.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git -C "${SCRIPT_DIR}" rev-parse --show-toplevel)"
CUGEO_DIR="${CUGEO_DIR:-${REPO_ROOT}/../cugeo}"
SCHEMA=cugeo_end_to_end
COMPONENT="${CUGEO_DIR}/cugeo-geometry/backends/cugeo-presto"
FIXTURE="${COMPONENT}/tests/fixtures/presto-end-to-end.json"
CLI_JAR="${REPO_ROOT}/../presto/docker/presto-cli-testing-executable.jar"
METASTORE="${SCRIPT_DIR}/../docker/.hive_metastore"
: "${PRESTO_DATA_DIR:?PRESTO_DATA_DIR must be set}"
for file in "${FIXTURE}" "${CLI_JAR}"; do
  [[ -f "${file}" ]] || { echo "ERROR: ${file} not found" >&2; exit 1; }
done

echo "Writing the dataset to ${PRESTO_DATA_DIR}/${SCHEMA}"
(cd "${CUGEO_DIR}/cugeo-geometry" &&
  uv run --frozen python "${COMPONENT}/tools/presto-end-to-end.py" parquet "${PRESTO_DATA_DIR}/${SCHEMA}")

start() {
  "${SCRIPT_DIR}/start_native_gpu_presto.sh" > /dev/null 2>&1
  docker cp "${CLI_JAR}" presto-coordinator:/tmp/presto-cli.jar > /dev/null
  for _ in $(seq 1 60); do
    [[ "$(cli --execute "SELECT count(*) FROM system.runtime.nodes WHERE coordinator = false" | tr -d '"' | tail -1)" == 1 ]] &&
      return 0
    sleep 5
  done
  echo "ERROR: no worker registered" >&2
  exit 1
}
cli() {
  docker exec presto-coordinator java -jar /tmp/presto-cli.jar --server localhost:8080 --catalog hive \
    --schema "${SCHEMA}" "$@" 2>&1
}
trap '"${SCRIPT_DIR}/stop_presto.sh" > /dev/null 2>&1' EXIT

start
echo "Registering the tables in hive.${SCHEMA}"
cli --execute "CREATE SCHEMA IF NOT EXISTS hive.${SCHEMA}" > /dev/null
python3 - "${FIXTURE}" "${SCHEMA}" <<'PY' | while IFS= read -r statement; do cli --execute "${statement}" > /dev/null; done
import json, sys
fixture, schema = json.load(open(sys.argv[1])), sys.argv[2]
types = {"bigint": "bigint", "text": "varchar", "bytea": "varbinary"}
for table, spec in fixture["tables"].items():
    columns = ", ".join(f"{name} {types[kind]}" for name, kind in spec["columns"])
    location = f"file:/var/lib/presto/data/hive/data/user_data/{schema}/{table}"
    print(f"DROP TABLE IF EXISTS {table}")
    print(f"CREATE TABLE {table} ({columns}) WITH (format = 'PARQUET', external_location = '{location}')")
PY
"${SCRIPT_DIR}/stop_presto.sh" > /dev/null 2>&1

# Presto's SQL can't set arbitrary Hive table properties, so they go into the
# file metastore's table records, which the containers own.
echo "Writing the tables' properties into the metastore"
docker run --rm -v "${METASTORE}/${SCHEMA}:/schema" -v "${FIXTURE}:/fixture.json:ro" "${DEPS_IMAGE:-presto/prestissimo-dependency:centos9-${USER:-latest}}" \
  python3 -c '
import json, os
fixture = json.load(open("/fixture.json"))
for table, spec in fixture["tables"].items():
    record = f"/schema/{table}/.prestoSchema"
    data = json.load(open(record))
    data["parameters"] = {k: v for k, v in data["parameters"].items() if not k.startswith("cugeo.")}
    data["parameters"].update(spec["properties"])
    json.dump(data, open(record, "w"), indent=2)
    checksum = f"/schema/{table}/..prestoSchema.crc"
    if os.path.exists(checksum):
        os.remove(checksum)
'

start
echo "Running the queries"
export -f cli
export SCHEMA
python3 - "${FIXTURE}" <<'PY'
import csv, io, json, re, subprocess, sys
fixture = json.load(open(sys.argv[1]))

def run(sql):
    return subprocess.run(["bash", "-c", 'cli --debug --execute "$0"', sql], capture_output=True, text=True).stdout

def operators(output):
    query = re.search(r"\d{8}_\d{6}_\d{5}_\w{5}", output)
    if not query:
        return set()
    info = subprocess.run(["docker", "exec", "presto-coordinator", "curl", "-s",
                           f"localhost:8080/v1/query/{query.group(0)}"], capture_output=True, text=True).stdout
    return {o["operatorType"] for o in json.loads(info)["queryStats"]["operatorSummaries"]}

def value(text, kind):
    return None if text == "" else {"bigint": int, "double": float, "varchar": str}[kind](text)

expected_operator = {"join": "CuGeoSpatialProbe", "within": "CuGeoSpatialProbe", "group": "CuGeoSpatialProbe",
                     "area": "CuGeoSpatialFunction"}
failed = 0
for name, query in fixture["queries"].items():
    output = run(query["presto"])
    lines = [line for line in output.splitlines() if line.startswith('"')]
    rows = sorted(([value(v, k) for v, k in zip(row, query["types"])] for row in csv.reader(io.StringIO("\n".join(lines)))),
                  key=json.dumps)
    ran = operators(output)
    ok = rows == query["rows"] and expected_operator.get(name, "") in ran
    failed += not ok
    print(f"{'PASS' if ok else 'FAIL'} {name}: {len(rows)} rows" + ("" if ok else f"\n  got {rows}\n  expected {query['rows']}\n  operators {sorted(ran)}"))
for name, failure in fixture["failures"].items():
    output = run(failure["presto"])
    ok = "failed" in output and failure["message"] in output
    failed += not ok
    print(f"{'PASS' if ok else 'FAIL'} {name} fails" + ("" if ok else f"\n  {output.strip()[-400:]}"))
sys.exit(1 if failed else 0)
PY
