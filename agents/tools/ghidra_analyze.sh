#!/usr/bin/env bash
# Wrapper for headless Ghidra analysis, called by constraint_analysis.sh.
# Usage: ghidra_analyze.sh <bench> <outdir> <script_dir>
set -euo pipefail

bench="$1"
outdir="$2"
script_dir="$3"

ghidra_root="${script_dir}/tools/ghidra"
scripts="${script_dir}/tools"
proj_dir="${outdir}/ghidra_proj"
proj_name="proj"

# Release zip layout (install.sh) puts analyzeHeadless under support/;
# a source checkout keeps it under Ghidra/RuntimeScripts/Linux/support/.
if [ -x "${ghidra_root}/support/analyzeHeadless" ]; then
    analyze="${ghidra_root}/support/analyzeHeadless"
elif [ -x "${ghidra_root}/Ghidra/RuntimeScripts/Linux/support/analyzeHeadless" ]; then
    analyze="${ghidra_root}/Ghidra/RuntimeScripts/Linux/support/analyzeHeadless"
else
    echo "ghidra_analyze.sh: no analyzeHeadless under ${ghidra_root}; run ./install.sh --only ghidra,jdk" >&2
    exit 1
fi

# Ghidra needs JDK 21+. Prefer GHIDRA_JAVA_HOME, then the JDK from install.sh,
# then whatever JAVA_HOME/PATH provides.
if [ -n "${GHIDRA_JAVA_HOME:-}" ]; then
    export JAVA_HOME="${GHIDRA_JAVA_HOME}"
elif [ -x "${script_dir}/tools/jdk21/bin/java" ]; then
    export JAVA_HOME="${script_dir}/tools/jdk21"
fi

mkdir -p "${proj_dir}"
rm -rf "${proj_dir:?}"/*

"${analyze}" "${proj_dir}" "${proj_name}" \
    -import "${bench}" \
    -analysisTimeoutPerFile 600 \
    -scriptPath "${scripts}" \
    -postScript export_runtime_features.py "${outdir}" \
    -deleteProject \
    > "${outdir}/ghidra.txt" 2>&1
