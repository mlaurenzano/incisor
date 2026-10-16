#!/usr/bin/env bash
set -euo pipefail

tool_timeout=20   # seconds; tools exceeding this are killed, logged as TIMEOUT, and excluded from the manifest

# ---------------------------------------------------------------------------
# Read LLM configuration from llm_config.json
llm_config="$(cd "$(dirname "$0")" && pwd)/llm_config.json"
[[ -f "${llm_config}" ]] || { printf 'LLM config not found: %s\n' "${llm_config}" >&2; exit 1; }

tool_level=$(jq -r '.analysis_level' "${llm_config}")
llm_model_key=$(jq -r '.model' "${llm_config}")
use_source=$(jq -r '.use_source' "${llm_config}")
use_run=$(jq -r '.use_run' "${llm_config}")

# Clear source dir if config says not to use it
if [ "${use_source}" != "true" ]; then
    INCISOR_SOURCE_DIR=""
fi

# Clear prior runs dir if use_run is 0 (or non-numeric)
if [[ "${use_run}" =~ ^[0-9]+$ ]] && [[ "${use_run}" -gt 0 ]]; then
    use_run_count="${use_run}"
else
    use_run_count=0
    INCISOR_PRIOR_RUNS=""
fi

if [ "${INCISOR_RUN_COMMAND:-}" == "" ]; then
    echo "you must define INCISOR_RUN_COMMAND"
    exit 1
fi
if [ "${INCISOR_BENCH_FILE:-}" == "" ]; then
    echo "you must define INCISOR_BENCH_FILE"
    exit 1
fi

run_command="${INCISOR_RUN_COMMAND}"
bench="$(realpath "${INCISOR_BENCH_FILE}")"
bench_dir="$(dirname "${bench}")"
script_dir="$(cd "$(dirname "$0")" && pwd)"

INCISOR_EXTRA_FILES=${INCISOR_EXTRA_FILES:-}
INCISOR_SOURCE_DIR=${INCISOR_SOURCE_DIR:-}
INCISOR_PRIOR_RUNS=${INCISOR_PRIOR_RUNS:-}

# ---------------------------------------------------------------------------
# Resolve top-N prior-run instances when use_run > 0
_run_instances=()
if [[ "${use_run_count}" -gt 0 && -n "${INCISOR_PRIOR_RUNS}" && -d "${INCISOR_PRIOR_RUNS}" ]]; then
    _run_real="$(realpath "${INCISOR_PRIOR_RUNS}")"
    _instances_json="${_run_real}/../../agentic-L4bin-${llm_model_key}/instances.json"
    if [[ -f "${_instances_json}" ]]; then
        while IFS= read -r _inst; do
            [[ -n "${_inst}" ]] || continue
            if [[ -e "${_run_real}/${_inst}" ]]; then
                _run_instances+=("${_inst}")
            fi
            [[ ${#_run_instances[@]} -lt ${use_run_count} ]] || break
        done < <("${script_dir}/../list_instances.py" "${_instances_json}")
    fi
    if [[ ${#_run_instances[@]} -eq 0 ]]; then
        INCISOR_PRIOR_RUNS=""
    fi
fi

# ---------------------------------------------------------------------------
# Argument parsing

tools_file="${script_dir}/tools_${tool_level}.json"
while [[ $# -gt 0 ]]; do
    case "$1" in
        --tools) tools_file="$2"; shift 2 ;;
        *) printf 'Unknown argument: %s\n' "$1" >&2; exit 1 ;;
    esac
done

[[ -f "${tools_file}" ]] || { printf 'Tools config not found: %s\n' "${tools_file}" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Persistent output directory: ./<binary>_<cmd4>_<bin4>/

bin_name="$(basename "${bench}")"
cmd_hash=$(printf '%s' "${run_command}" | sha256sum | awk '{print $1}')
bin_hash=$(sha256sum "${bench}" | awk '{print $1}')
outdir="${bin_name}_${cmd_hash: -4}_${bin_hash: -4}"
mkdir -p "${outdir}"
outdir="$(realpath "${outdir}")"
printf 'INCISOR_RUN_COMMAND=%s\nINCISOR_BENCH_FILE=%s\n' "${run_command}" "${INCISOR_BENCH_FILE}" > "${outdir}/inputs.txt"
[[ -n "${INCISOR_EXTRA_FILES}" ]] && printf 'INCISOR_EXTRA_FILES=%s\n' "${INCISOR_EXTRA_FILES}" >> "${outdir}/inputs.txt"
[[ -n "${INCISOR_SOURCE_DIR}" ]] && printf 'INCISOR_SOURCE_DIR=%s\n' "${INCISOR_SOURCE_DIR}" >> "${outdir}/inputs.txt"
[[ -n "${INCISOR_PRIOR_RUNS}" ]] && printf 'INCISOR_PRIOR_RUNS=%s\n' "${INCISOR_PRIOR_RUNS}" >> "${outdir}/inputs.txt"
if [[ -n "${INCISOR_EXTRA_FILES}" ]]; then
    IFS=',' read -ra _extra <<< "${INCISOR_EXTRA_FILES}"
    for _f in "${_extra[@]}"; do
        cp "${_f}" "${outdir}/"
    done
fi

# ---------------------------------------------------------------------------
# Load tool definitions from JSON in one pass

declare -A _tool_action _tool_has_outputs
_tool_keys=()

while IFS=$'\t' read -r _key _has_outputs _action; do
    _tool_keys+=("${_key}")
    _tool_action["${_key}"]="${_action}"
    _tool_has_outputs["${_key}"]="${_has_outputs}"
done < <(jq -r '
    to_entries[]
    | select(.value.enabled == true)
    | [
        .key,
        (if .value.outputs then "true" else "false" end),
        .value.action
      ]
    | @tsv
' "${tools_file}")

# ---------------------------------------------------------------------------
# run_action: execute one tool, capture output, log timing
#
# Single-output tools (no "outputs" array): stdout+stderr captured to <key>.txt
# Multi-output tools (has "outputs" array): action writes its own files;
#   stdout is discarded (multi-output scripts write directly to {OUTDIR}/*)

run_action() {
    local key="$1" action="$2" has_outputs="$3"
    local t0 t1 rc=0

    local p_bench='{INCISOR_BENCH_FILE}' p_outdir='{OUTDIR}' p_scriptdir='{SCRIPT_DIR}'
    local cmd="${action//$p_bench/$bench}"
    cmd="${cmd//$p_outdir/$outdir}"
    cmd="${cmd//$p_scriptdir/$script_dir}"

    local label="${key}"
    [[ "${has_outputs}" == "false" ]] && label="${key}.txt"

    t0=$(date +%s%3N)
    if [[ "${has_outputs}" == "false" ]]; then
        timeout -k 10 "${tool_timeout}" bash -c "${cmd}" > "${outdir}/${key}.txt" 2>&1 || rc=$?
    else
        timeout -k 10 "${tool_timeout}" bash -c "${cmd}" > /dev/null 2>&1 || rc=$?
    fi
    t1=$(date +%s%3N)

    if [[ "${rc}" -eq 124 ]]; then
        [[ "${has_outputs}" == "false" ]] && rm -f "${outdir}/${key}.txt"
        printf '%s\tTIMEOUT (>%ds)\n' "${label}" "${tool_timeout}" >> "${outdir}/tool-timing.log"
    else
        printf '%s\t%d ms\n' "${label}" "$((t1 - t0))" >> "${outdir}/tool-timing.log"
    fi
}

# ---------------------------------------------------------------------------
# Launch all enabled tools in parallel
# Kill the entire process group on interrupt so no orphan tools linger
# across runs and pollute the timing log.
trap 'trap - INT TERM; kill 0 2>/dev/null; true' INT TERM

printf '' > "${outdir}/tool-timing.log"

for _key in "${_tool_keys[@]}"; do
    run_action "${_key}" "${_tool_action[${_key}]}" "${_tool_has_outputs[${_key}]}" &
done

wait

# ---------------------------------------------------------------------------
# Render prompt: substitute @@-style and @SECTION@ placeholders, write to outdir

declare -A _section_files    # section_tag → TAB-delimited list of existing full file paths
declare -A _section_display  # section_tag → resolved display string (filenames or "(unavailable)")

# Single-output tools
while IFS=$'\t' read -r _key _sec; do
    _f="${outdir}/${_key}.txt"
    [[ -s "${_f}" ]] && _section_files["${_sec}"]+="${_f}"$'\t'
done < <(jq -r '
    to_entries[]
    | select(.value.enabled == true and (.value.outputs | not))
    | .key as $k
    | .value.prompt_sections[]?
    | [$k, .]
    | @tsv
' "${tools_file}")

# Multi-output tools (per-output prompt_sections)
while IFS=$'\t' read -r _ofile _sec; do
    _f="${outdir}/${_ofile}"
    [[ -s "${_f}" ]] && _section_files["${_sec}"]+="${_f}"$'\t'
done < <(jq -r '
    to_entries[]
    | select(.value.enabled == true and .value.outputs)
    | .value.outputs[]
    | select(.prompt_sections)
    | .file as $f
    | .prompt_sections[]
    | [$f, .]
    | @tsv
' "${tools_file}")

# Collect all section tags referenced by enabled tools
mapfile -t _all_sections < <(jq -r '
    [
        to_entries[]
        | select(.value.enabled == true)
        | if .value.outputs then
            .value.outputs[].prompt_sections?[]?
          else
            .value.prompt_sections?[]?
          end
    ] | unique[]
' "${tools_file}")

# Resolve each section tag to a display string (filenames or "(unavailable)")
for _sec in "${_all_sections[@]}"; do
    _raw="${_section_files[${_sec}]:-}"
    if [[ -n "${_raw}" ]]; then
        _display=''
        while IFS= read -r _f; do
            [[ -n "${_f}" ]] || continue
            [[ -n "${_display}" ]] && _display+=' / '
            _display+="$(basename "${_f}")"
        done < <(printf '%s' "${_raw}" | tr '\t' '\n')
    else
        _display='(unavailable)'
    fi
    _section_display["${_sec}"]="${_display}"
done

# Build optional SOURCE_DIR_SECTION and RUN_DIR_SECTION
if [[ -n "${INCISOR_SOURCE_DIR}" ]]; then
    _src_real="$(realpath "${INCISOR_SOURCE_DIR}")"
    _source_dir_section="SOURCE CODE
  ${_src_real} — the precompiled source code used to build the binary.
  Use Glob, Grep, and Read to browse it for variable names, data structures,
  algorithm parameters, problem-size constants, Makefiles, build scripts,
  and any documentation (README, comments) that clarifies the program's behavior.
  Prefer source evidence over decompiler output when both are available."
else
    _source_dir_section=""
fi

if [[ ${#_run_instances[@]} -gt 0 && -n "${INCISOR_PRIOR_RUNS}" && -d "${INCISOR_PRIOR_RUNS}" ]]; then
    _run_real="$(realpath "${INCISOR_PRIOR_RUNS}")"
    _run_dir_section="PRIOR RUN DATA
  ${_run_real} — directory containing summary data collected from runtime monitors on a prior run of this benchmark.
  Each file is named after the instance the program ran on during data collection.
  Available instance data:"
    for _rname in "${_run_instances[@]}"; do
        _run_dir_section+=$'\n'"    ${_rname}"
    done
    _run_dir_section+=$'\n'"  Use Read and Grep to examine these files for observed runtime behavior, resource utilization,"
    _run_dir_section+=$'\n'"  and performance characteristics that can inform your estimates."
else
    _run_dir_section=""
fi

# Render the unified prompt: @@-style, then @@SOURCE_DIR_SECTION@@/@@RUN_DIR_SECTION@@,
# then @SECTION@ tags, then fallback unresolved @X@ to <unavailable>
_prompt=$(sed \
    -e "s|@@RUN_COMMAND@@|${run_command}|g" \
    -e "s|@@BENCH_FILE@@|${bench}|g" \
    -e "s|@@MANIFEST@@|${outdir}/MANIFEST.txt|g" \
    "${script_dir}/analysis_prompt.txt")
_prompt="${_prompt//"@@SOURCE_DIR_SECTION@@"/${_source_dir_section}}"
_prompt="${_prompt//"@@RUN_DIR_SECTION@@"/${_run_dir_section}}"
for _sec in "${_all_sections[@]}"; do
    _p="@${_sec}@"
    _prompt="${_prompt//$_p/${_section_display[${_sec}]}}"
done
_prompt=$(printf '%s' "${_prompt}" | sed 's/@[A-Z_][A-Z_0-9]*@/<unavailable>/g')
printf '%s\n' "${_prompt}" > "${outdir}/prompt.txt"

# ---------------------------------------------------------------------------
# Write manifest listing all non-empty output files

allowed_files=()
allowed_files+=("${outdir}/MANIFEST.txt")

{
    printf 'Binary:     %s\n' "${bench}"
    printf 'Invocation: %s\n\n' "${run_command}"
    printf 'Analysis output files (read each one):\n\n'

    add() {
        local f="${outdir}/$1" desc="$2"
        if [ -s "${f}" ]; then printf '  %s\n    %s\n\n' "${f}" "${desc}"; allowed_files+=("${f}"); fi
    }

    for _key in "${_tool_keys[@]}"; do
        if [[ "${_tool_has_outputs[${_key}]}" == "false" ]]; then
            _desc=$(jq -r ".\"${_key}\".description" "${tools_file}")
            add "${_key}.txt" "${_desc}"
        else
            while IFS=$'\t' read -r _file _desc; do
                add "${_file}" "${_desc}"
            done < <(jq -r ".\"${_key}\".outputs[] | [.file, .description] | @tsv" "${tools_file}")
        fi
    done

    if [[ -n "${INCISOR_SOURCE_DIR}" ]]; then
        printf 'Source directory (use Read, Grep, and Glob to explore):\n\n'
        printf '  %s\n' "$(realpath "${INCISOR_SOURCE_DIR}")"
        printf '    Source code for the benchmark — consult for variable names,\n'
        printf '    data structures, algorithm intent, and kernel launch parameters.\n\n'
    fi

    if [[ ${#_run_instances[@]} -gt 0 && -n "${INCISOR_PRIOR_RUNS}" && -d "${INCISOR_PRIOR_RUNS}" ]]; then
        _run_real="$(realpath "${INCISOR_PRIOR_RUNS}")"
        printf 'Prior run data (each file is named after the instance it was collected on):\n\n'
        for _rname in "${_run_instances[@]}"; do
            printf '  %s\n' "$(realpath "${_run_real}/${_rname}")"
        done
        printf '\n'
    fi

    if [[ -n "${INCISOR_EXTRA_FILES}" ]]; then
        printf 'Extra reference files (read and grep these too):\n\n'
        IFS=',' read -ra _extra <<< "${INCISOR_EXTRA_FILES}"
        for _f in "${_extra[@]}"; do
            _f="$(realpath "${_f}")"
            [ -f "${_f}" ] && printf '  %s\n\n' "${_f}"
        done
    fi

} > "${outdir}/MANIFEST.txt"

# Add extra reference files to the allow list (for the local agent file-level allowlist)
if [[ -n "${INCISOR_EXTRA_FILES}" ]]; then
    IFS=',' read -ra _extra <<< "${INCISOR_EXTRA_FILES}"
    for _f in "${_extra[@]}"; do
        _f="$(realpath "${_f}")"
        [ -f "${_f}" ] && allowed_files+=("${_f}")
    done
fi

# Add prior run files to the allow list
if [[ ${#_run_instances[@]} -gt 0 && -n "${INCISOR_PRIOR_RUNS}" && -d "${INCISOR_PRIOR_RUNS}" ]]; then
    _run_real="$(realpath "${INCISOR_PRIOR_RUNS}")"
    for _rname in "${_run_instances[@]}"; do
        _rf="$(realpath "${_run_real}/${_rname}")"
        [[ -f "${_rf}" ]] && allowed_files+=("${_rf}")
    done
fi

# Build --allow-file args from the accumulated list
allow_file_args=()
for _f in "${allowed_files[@]}"; do
    allow_file_args+=(--allow-file "${_f}")
done

# ---------------------------------------------------------------------------

# Build --add-dir flag for the optional source directory
source_dir_args=()
if [[ -n "${INCISOR_SOURCE_DIR}" ]]; then
    source_dir_args+=(--tools Glob --add-dir "$(realpath "${INCISOR_SOURCE_DIR}")")
fi

# Build --add-dir flags for the optional prior runs directory (resolve symlinks
# so we add the directories that actually contain the target files)
run_dir_args=()
if [[ ${#_run_instances[@]} -gt 0 && -n "${INCISOR_PRIOR_RUNS}" && -d "${INCISOR_PRIOR_RUNS}" ]]; then
    _run_real="$(realpath "${INCISOR_PRIOR_RUNS}")"
    declare -A _run_seen_dirs
    for _rname in "${_run_instances[@]}"; do
        _rf="$(realpath "${_run_real}/${_rname}")"
        [[ -f "${_rf}" ]] || continue
        _rd="$(dirname "${_rf}")"
        if [[ -z "${_run_seen_dirs[${_rd}]+_}" ]]; then
            run_dir_args+=(--add-dir "${_rd}")
            _run_seen_dirs["${_rd}"]=1
        fi
    done
fi

# Build --add-dir flags for any extra files passed in via INCISOR_EXTRA_FILES
extra_dir_args=()
if [[ -n "${INCISOR_EXTRA_FILES}" ]]; then
    IFS=',' read -ra _extra <<< "${INCISOR_EXTRA_FILES}"
    declare -A _seen_dirs
    for _f in "${_extra[@]}"; do
        _d="$(dirname "$(realpath "${_f}")")"
        if [[ -z "${_seen_dirs[${_d}]+_}" ]]; then
            extra_dir_args+=(--add-dir "${_d}")
            _seen_dirs["${_d}"]=1
        fi
    done
fi

answer_schema=$(cat "${script_dir}/analysis_schema.json")

# ---------------------------------------------------------------------------
# Model dispatch based on llm_config.json

declare -A vllm_models=(
    [qwen]="Qwen/Qwen3.5-35B-A3B"
    [llama]="meta-llama/Llama-3.3-70B-Instruct"
    [ministral]="mistralai/Ministral-3-14B-Instruct-2512"
    [nemo]="nvidia/Llama-3_3-Nemotron-Super-49B-v1_5"
)

declare -A claude_models=(
    [claudesonnet]="claude-sonnet-4-6"
    [claudeopus]="claude-opus-4-6"
)

if [[ -n "${claude_models[${llm_model_key}]+_}" ]]; then
# claude / commercial version
(
    cd "${bench_dir}"
    claude --model "${claude_models[${llm_model_key}]}" \
           --tools Read --tools Grep \
           "${source_dir_args[@]}" \
           "${run_dir_args[@]}" \
           --add-dir "${outdir}" \
           "${extra_dir_args[@]}" \
           --output-format stream-json --verbose \
           --json-schema "${answer_schema}" \
           -p "$(cat "${outdir}/prompt.txt")" < /dev/null
)
else
(
    export VLLM_BASE_URL="http://localhost:8000/v1"
    export VLLM_MODEL="${vllm_models[${llm_model_key}]}"
    export VLLM_API_KEY="dummy"
    cd "${bench_dir}"
    echo $(pwd)
    ${script_dir}/agent_local.py --think --tools ReadSlice --tools Head --tools Grep \
           "${source_dir_args[@]}" \
           "${run_dir_args[@]}" \
           "${allow_file_args[@]}" \
           --tool-budget 200 \
           --output-format stream-json --verbose \
           --json-schema "${answer_schema}" \
           -p "$(cat "${outdir}/prompt.txt")" < /dev/null
)
fi
