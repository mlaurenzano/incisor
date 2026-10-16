#!/usr/bin/env bash
# instance_recommender.sh — recommend the top 10 EC2 instances for a binary workload.
#
# Usage:
#   ./instance_recommender.sh <analysis.json>
#
# <analysis.json> is the output file produced by constraint_analysis.sh.
# The script reads the final schema-verified JSON answer from the last line of that file,
# pairs it with the instance catalog, and asks Claude to pick the cheapest 10 instances
# that satisfy the program's needs.
#
# The LLM is restricted to Read tool access on exactly two files:
#   - the extracted binary analysis JSON
#   - ../static_aws_useast1.csv (the instance catalog)

set -euo pipefail

# ---------------------------------------------------------------------------
# Validate input

analysis_json="${1:?Usage: $0 <analysis.json>}"
analysis_json="$(realpath "${analysis_json}")"
[[ -f "${analysis_json}" ]] || { printf 'File not found: %s\n' "${analysis_json}" >&2; exit 1; }

script_dir="$(cd "$(dirname "$0")" && pwd)"

# Read model from llm_config.json
llm_config="${script_dir}/llm_config.json"
[[ -f "${llm_config}" ]] || { printf 'LLM config not found: %s\n' "${llm_config}" >&2; exit 1; }
llm_model_key=$(jq -r '.model' "${llm_config}")

declare -A claude_models=(
    [claudesonnet]="claude-sonnet-4-6"
    [claudeopus]="claude-opus-4-6"
)
claude_model="${claude_models[${llm_model_key}]:-claude-sonnet-4-6}"

csv_file="${script_dir}/../static_aws_useast1.csv"
[[ -f "${csv_file}" ]] || { printf 'Instance catalog not found: %s\n' "${csv_file}" >&2; exit 1; }
csv_file="$(realpath "${csv_file}")"

prompt_template="${script_dir}/recommender_prompt.txt"
[[ -f "${prompt_template}" ]] || { printf 'Prompt template not found: %s\n' "${prompt_template}" >&2; exit 1; }

answer_schema="${script_dir}/recommender_schema.json"
[[ -f "${answer_schema}" ]] || { printf 'Answer schema not found: %s\n' "${answer_schema}" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Extract the binary analysis JSON from the output file.
# agent_local.py writes the final schema-verified answer as the last
# non-empty line of analysis.json.

constraint_analysis=$(python3 - "${analysis_json}" <<'PYEOF'
import json, sys

path = sys.argv[1]
last_line = None
with open(path) as fh:
    for raw in fh:
        raw = raw.strip()
        if raw:
            last_line = raw

if last_line is None:
    sys.exit("ERROR: " + path + " is empty")

try:
    obj = json.loads(last_line)
except json.JSONDecodeError as e:
    sys.exit("ERROR: last line of " + path + " is not valid JSON: " + str(e))

print(json.dumps(obj, indent=2))
PYEOF
)

# ---------------------------------------------------------------------------
# Stage exactly the two input files in a temporary directory so that the
# --add-dir restriction limits Claude to reading only those files.
#
# The full catalog is ~825 KB which exceeds the LLM Read tool's 256 KB limit.
# We pre-filter it to the columns needed for selection and drop obviously
# ineligible rows (non-x86, and GPU-only instances when no GPU is required).

tmpdir=$(mktemp -d)
trap 'rm -rf "${tmpdir}"' EXIT

printf '%s\n' "${constraint_analysis}" > "${tmpdir}/constraint_analysis.json"

# MCP server config — exposes tools/query_instances.py as the FilterInstances tool.
# Surfaced to the model as mcp__instances__FilterInstances.
mcp_config="${tmpdir}/mcp.json"
cat >"${mcp_config}" <<EOF
{
  "mcpServers": {
    "instances": {
      "command": "python3",
      "args": ["${script_dir}/tools/query_instances_mcp.py"]
    }
  }
}
EOF

# ---------------------------------------------------------------------------
# Build prior run status section from top-N instances (if use_run > 0)

use_run=$(jq -r '.use_run' "${llm_config}")
prior_run_status=""
if [[ "${use_run}" =~ ^[0-9]+$ ]] && [[ "${use_run}" -gt 0 ]]; then
    bench_dir="$(dirname "${analysis_json}")"
    prior_instances_json="${bench_dir}/../agentic-L4bin-${llm_model_key}/instances.json"
    if [[ -f "${prior_instances_json}" ]]; then
        _count=0
        _rows=()
        _max_inst=0
        _max_mem=0
        _max_result=0
        while IFS= read -r _inst; do
            [[ -n "${_inst}" ]] || continue
            _status_file="${bench_dir}/../${_inst}/status.json"
            if [[ -f "${_status_file}" ]]; then
                _result=$(python3 -c "import json; print(json.load(open('${_status_file}')).get('result','unknown'))" 2>/dev/null || echo "unknown")
                _rationale=$(python3 -c "import json; print(json.load(open('${_status_file}')).get('rationale',''))" 2>/dev/null || echo "")
            else
                _result="(no data)"
                _rationale="(no data)"
            fi
            _mem=$(python3 -c "
import csv
with open('${csv_file}') as f:
    for row in csv.DictReader(f):
        if row.get('API Name') == '${_inst}':
            print(row.get('Instance Memory','?'))
            break
" 2>/dev/null || echo "?")
            _rows+=("${_inst}|${_mem}|${_result}|${_rationale}")
            (( ${#_inst} > _max_inst )) && _max_inst=${#_inst}
            (( ${#_mem} > _max_mem )) && _max_mem=${#_mem}
            (( ${#_result} > _max_result )) && _max_result=${#_result}
            _count=$((_count + 1))
            [[ ${_count} -lt ${use_run} ]] || break
        done < <("${script_dir}/../list_instances.py" "${prior_instances_json}")
        if [[ ${#_rows[@]} -gt 0 ]]; then
            prior_run_status="PRIOR RUN STATUS — the following instances were previously recommended and run for this
workload. Use these results to inform your recommendations. Generalize from failure modes:
  - out_of_memory on an N GiB instance → exclude all instances with ≤ N GiB memory
  - platform_mismatch (illegal instruction) → exclude instances with the same or older
    processor generation (the binary requires a newer ISA extension)
  - instance_unavailable → skip that specific instance, but similar sizes are fine

"
            (( ${#_mem} < 6 )) && _max_mem=6
            printf -v _hdr "  %-${_max_inst}s  %-${_max_mem}s  %-${_max_result}s  %s" "Instance" "Memory" "Result" "Rationale"
            prior_run_status+="${_hdr}"$'\n'
            printf -v _sep "  %${_max_inst}s  %${_max_mem}s  %${_max_result}s  %s" "" "" "" ""
            _sep="${_sep// /-}"
            prior_run_status+="${_sep}"$'\n'
            for _row in "${_rows[@]}"; do
                IFS='|' read -r _ri _rm _rr _rd <<< "${_row}"
                printf -v _line "  %-${_max_inst}s  %-${_max_mem}s  %-${_max_result}s  %s" "${_ri}" "${_rm}" "${_rr}" "${_rd}"
                prior_run_status+="${_line}"$'\n'
            done
        fi
    fi
fi

# ---------------------------------------------------------------------------
# Build the prompt by substituting file path placeholders

prompt=$(sed \
    -e "s|@@ANALYSIS_FILE@@|${tmpdir}/constraint_analysis.json|g" \
    -e "s|@@CSV_FILE@@|[use the FilterInstances tool]|g" \
    "${prompt_template}")
prompt="${prompt//"@@PRIOR_RUN_STATUS@@"/${prior_run_status}}"
prompt+="

Note: To access the instance catalog, call FilterInstances with your filter parameters (e.g. min_memory_gib, max_memory_gib, min_vcpus, arch, needs_gpu). The tool returns a filtered CSV directly. Call it before making recommendations.

FILTERING STRATEGY: Always pass limit=50. Burstable and flex instances are excluded by default — do not pass include_burstable or include_flex unless no non-burstable instance satisfies the hard requirements. Your FIRST FilterInstances call MUST use min_gen_number=8. Only drop to min_gen_number=7 in a follow-up call if the first call returned fewer than 15 rows. Always supply both a lower AND upper bound for memory to keep result sets manageable: start with max_memory_gib = 2× min_memory_gib (e.g. min_memory_gib=80, max_memory_gib=160 when you need at least 80 GiB). If FilterInstances returns 0 rows, double the upper bound and retry (e.g. max_memory_gib=320, then 640, etc.). Apply the same back-off for vCPUs: start with max_vcpus = 2× min_vcpus and double if needed.

IMPORTANT — MINIMIZE TOOL CALLS: Each FilterInstances call is expensive. Make ONE call with broad-enough bounds to cover all relevant instance families (c, m, r, x, hpc, etc.) in a single query. If your first call returns 10 or more qualifying rows, do NOT make additional calls — select your recommendations from those results. Only make a follow-up call if the first returned fewer than 10 usable rows and you need to widen bounds (lower min_gen_number or increase memory/vCPU range). Never make speculative calls to check for niche families — the catalog is organized so a single query with appropriate memory/vCPU bounds already spans all families."
printf '%s\n' "${prompt}" > "$(dirname "${analysis_json}")/recommender_prompt.txt"

# ---------------------------------------------------------------------------
# Invoke Claude with Read tool only, restricted to the staging directory

answer_schema_content=$(cat "${answer_schema}")

claude --model "${claude_model}" \
       --mcp-config "${mcp_config}" \
       --tools Read \
       --allowedTools "mcp__instances__FilterInstances" \
       --add-dir "${tmpdir}" \
       --output-format stream-json --verbose \
       --json-schema "${answer_schema_content}" \
       -p "${prompt}" < /dev/null
