#!/bin/bash

# SPDX-FileCopyrightText: Copyright (c) 2026, NVIDIA CORPORATION.
# SPDX-License-Identifier: Apache-2.0

# Generates SpatialBench data at a scale factor for cuGeo's CPU/GPU comparison
# (run_cugeo_comparison.sh), with Apache Sedona SpatialBench's spatialbench-cli,
# into ${PRESTO_DATA_DIR}/spatialbench/v<generator version>/sf<N>/<table>/, one
# directory per table, where the Presto containers can read it. The trip table
# is written as one file per 6M rows, -j files at a time (default 8): one
# spatialbench-cli process keeps only about three cores busy.
#
#   generate_spatialbench_data.sh -s 10 [-t "trip building"] [-j 8]
#
# Needs PRESTO_DATA_DIR and a SpatialBench clone (SEDONA_SPATIALBENCH, default
# ../sedona-spatialbench beside the velox-geo tree); builds spatialbench-cli
# with cargo when it is missing. Refuses a scale factor whose directory exists.

set -euo pipefail

SCALE=""
TABLES="trip building customer driver vehicle zone"
JOBS=8
while getopts "s:t:j:" option; do
  case "${option}" in
    s) SCALE="${OPTARG}" ;;
    t) TABLES="${OPTARG}" ;;
    j) JOBS="${OPTARG}" ;;
    *) echo "usage: $0 -s <scale factor> [-t \"<tables>\"] [-j jobs]" >&2; exit 1 ;;
  esac
done
[[ -n "${SCALE}" ]] || { echo "usage: $0 -s <scale factor> [-t \"<tables>\"] [-j jobs]" >&2; exit 1; }
: "${PRESTO_DATA_DIR:?PRESTO_DATA_DIR must be set}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git -C "${SCRIPT_DIR}" rev-parse --show-toplevel)"
SEDONA_SPATIALBENCH="${SEDONA_SPATIALBENCH:-${REPO_ROOT}/../../sedona-spatialbench}"
CLI="${SEDONA_SPATIALBENCH}/target/release/spatialbench-cli"
if [[ ! -x "${CLI}" ]]; then
  echo "Building spatialbench-cli in ${SEDONA_SPATIALBENCH}"
  (cd "${SEDONA_SPATIALBENCH}" && cargo build --release -p spatialbench-cli)
fi
VERSION="$(grep -m1 '^version' "${SEDONA_SPATIALBENCH}/spatialbench-cli/Cargo.toml" | cut -d'"' -f2)"
OUT="${PRESTO_DATA_DIR}/spatialbench/v${VERSION}/sf${SCALE}"
[[ ! -e "${OUT}" ]] || { echo "ERROR: ${OUT} exists" >&2; exit 1; }
mkdir -p "${OUT}"

for table in ${TABLES}; do
  parts=1
  if [[ "${table}" == trip ]]; then
    parts=$(python3 -c "import math; print(max(1, math.ceil(${SCALE})))")
  fi
  start=$(date +%s)
  # With -p, spatialbench-cli writes <table>/<table>.<part>.parquet under -o,
  # except the zone table in one part, which it writes as <table>.parquet.
  if (( parts > 1 )); then
    seq 1 "${parts}" | xargs -P "${JOBS}" -I{} "${CLI}" -s "${SCALE}" -T "${table}" -p "${parts}" --part {} -o "${OUT}"
  else
    "${CLI}" -s "${SCALE}" -T "${table}" -p "${parts}" -o "${OUT}"
  fi
  if [[ -f "${OUT}/${table}.parquet" ]]; then
    mkdir -p "${OUT}/${table}"
    mv "${OUT}/${table}.parquet" "${OUT}/${table}/${table}.1.parquet"
  fi
  echo "${table}: $(ls "${OUT}/${table}" | wc -l) files, $(du -sh "${OUT}/${table}" | cut -f1), $(( $(date +%s) - start ))s"
done
echo "Wrote ${OUT}"
