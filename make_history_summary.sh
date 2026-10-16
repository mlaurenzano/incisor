#!/bin/bash
set -euo pipefail

# Produce a history summary from an incisor_report.log by keeping only the
# information useful for LLM-based instance predictions:
#   - Instance identity, cost, runtime, ranks
#   - Per-rank static characteristics (libraries, symbols, registers, env, hardware)
#   - Pre-computed summary sections (utilization, CPU breakdown, scheduler, GPU, static needs)
#
# Strips raw memory byte counts, per-rank CPU/pressure/schedstat breakdowns
# (redundant with summaries), epoch timestamps, CPU flags, and internal IDs.
# When used with incisor_report.log, the Utilized memory is already
# application-only (max-min MemAvailable delta), so no OS baseline subtraction is needed.

if [[ -z "${1:-}" ]]; then
    echo "Usage: $0 <incisor_report.log>" >&2
    exit 1
fi

if [[ ! -f "$1" ]]; then
    echo "Error: $1 not found" >&2
    exit 1
fi

grep -vE \
    -e '^Rank [0-9]+ (MemTotal|MemAvailable|min MemAvailable|max MemAvailable):' \
    -e '^Rank [0-9]+ (date_before|date_after):' \
    -e '^Rank [0-9]+ node_pressure_' \
    -e '^Rank [0-9]+ total: ' \
    -e '^Rank [0-9]+ utilized CPUs:' \
    -e '^Rank [0-9]+ Flags:' \
    -e '^Slug:' \
    -e '^App SHA1:' \
    -e '^Run timestamp:' \
    -e '^Warning:' \
    "$1" \
| awk '{ print }'
