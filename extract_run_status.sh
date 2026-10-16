#!/bin/bash
# Classify each <bench-name>/<aws-instance> directory as success or failure
# by analyzing incisor_report.log and run.log.
#
# Writes <bench-name>/<aws-instance>/status.json with:
#   { "result": "<status>", "rationale": "<explanation>" }
#
# Status is one of: success, fail_out_of_memory, fail_platform_mismatch,
#                    fail_missing_library, fail_other
#
# Usage:
#   ./classify_run_status.sh --all [--overwrite]   Process all run.log files
#   ./classify_run_status.sh --dir <dir>           Process a single directory

npar=64

mode=""
overwrite=false
single_dir=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --all)       mode="all"; shift ;;
    --overwrite) overwrite=true; shift ;;
    --dir)       mode="single"; single_dir="$2"; shift 2 ;;
    *)           echo "Unknown argument: $1" >&2; exit 1 ;;
  esac
done

if [ -z "$mode" ]; then
  echo "Usage: $0 --all [--overwrite] | --dir <dir>" >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

classify_one() {
  local dir="$1"

  runlog="${dir}/run.log"
  incisorlog="${dir}/incisor_report.log"

  result=""
  rationale=""

  # Check incisor_report.log
  incisor_ok=false
  if [ -f "$incisorlog" ]; then
    last_line=$(tail -1 "$incisorlog")
    if echo "$last_line" | grep -qE "^Has TLP:"; then
      incisor_ok=true
    fi
  fi

  # Check run.log for failure indicators
  has_oom=false
  has_illegal=false
  has_missing_lib=false
  has_killed=false
  has_segfault=false
  has_no_instance=false
  has_skypilot_success=false
  has_job_failed=false

  if [ -f "$runlog" ]; then
    if grep -qE "std::bad_alloc|OutOfMemoryError|Cannot allocate memory|enomem|out of memory|Error encountered in allocating space|MemoryError|Unable to allocate" "$runlog"; then
      has_oom=true
    fi
    if grep -qE "line [0-9]+:.*Killed" "$runlog"; then
      has_killed=true
    fi
    if grep -qE "Segmentation fault" "$runlog"; then
      has_segfault=true
    fi
    if grep -qiE "Illegal instruction|SIGILL|illegal hardware instruction" "$runlog"; then
      has_illegal=true
    fi
    if grep -qE "error while loading shared libraries|cannot open shared object" "$runlog"; then
      has_missing_lib=true
    fi
    if grep -qE "No instance type .* found|InsufficientInstanceCapacity|VcpuLimitExceeded|ResourcesUnavailableError" "$runlog"; then
      has_no_instance=true
    fi
    if grep -q "Job finished (status: SUCCEEDED)" "$runlog"; then
      has_skypilot_success=true
    fi
    if grep -qE "Job finished \(status: FAILED\)|status: FAILED_SETUP" "$runlog"; then
      has_job_failed=true
    fi
  fi

  # Classification
  if $incisor_ok && ! $has_oom && ! $has_illegal && ! $has_missing_lib && ! $has_killed && ! $has_segfault; then
    result="success"
    rationale="incisor_report.log completed successfully with Has TLP line"
  elif $incisor_ok && $has_killed && ! $has_oom && ! $has_illegal; then
    result="success"
    rationale="incisor_report.log completed successfully with Has TLP line despite subprocess kill signal"
  elif $has_oom; then
    result="fail_out_of_memory"
    if $has_killed; then
      rationale="Out of memory: allocation failure and process killed"
    else
      rationale="Out of memory: std::bad_alloc or Ray OutOfMemoryError detected in run.log"
    fi
  elif $has_killed && ! $incisor_ok; then
    result="fail_out_of_memory"
    rationale="Process killed (likely OOM) and incisor_report.log missing or incomplete"
  elif $has_segfault; then
    result="fail_segfault"
    rationale="Segmentation fault detected in run.log"
  elif $has_illegal; then
    result="fail_platform_mismatch"
    rationale="Illegal instruction detected - binary incompatible with CPU architecture"
  elif $has_missing_lib; then
    result="fail_missing_library"
    rationale="Missing shared library detected in run.log"
  elif $has_no_instance; then
    result="fail_instance_unavailable"
    rationale="Instance type not found, insufficient capacity, or vCPU limit exceeded"
  elif ! $incisor_ok && $has_skypilot_success; then
    result="fail_other"
    rationale="Skypilot reported success but incisor_report.log missing or incomplete"
  elif $has_job_failed; then
    result="fail_other"
    rationale="Skypilot reported job failure"
  elif ! [ -f "$incisorlog" ] && [ -f "$runlog" ]; then
    result="fail_other"
    rationale="incisor_report.log missing; run.log present but no specific error pattern matched"
  elif [ -f "$incisorlog" ] && ! $incisor_ok; then
    result="fail_other"
    last=$(tail -1 "$incisorlog" | tr '"' "'" | tr '\n' ' ')
    rationale="incisor_report.log incomplete. Last line: ${last}"
  else
    result="fail_other"
    rationale="Unable to determine status"
  fi

  printf '{ "result": "%s", "rationale": "%s" }\n' "$result" "$rationale" > "${dir}/status.json"
  echo "${result}: ${dir}"
}

if [ "$mode" = "single" ]; then
  if [ ! -d "$single_dir" ]; then
    echo "Error: directory not found: $single_dir" >&2
    exit 1
  fi
  classify_one "$single_dir"
else
  cd "$SCRIPT_DIR"

  # Collect directories to process
  dirs=$(find . -name "run.log" | sed 's|/run.log$||' | sed 's|^\./||' \
    | grep -vE '/agentic-|/TEST_|/expert' | sort -u)

  if ! $overwrite; then
    dirs=$(echo "$dirs" | while IFS= read -r d; do
      [ ! -f "${d}/status.json" ] && echo "$d"
    done)
  fi

  if [ -z "$dirs" ]; then
    echo "Nothing to process."
    exit 0
  fi

  export SCRIPT_DIR
  export -f classify_one
  echo "$dirs" | parallel -j ${npar} classify_one
fi
