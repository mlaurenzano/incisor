#!/usr/bin/env bash
# radare2: combined analysis — runs once, writes afl, agCj, and pseudo-C decompilation.
# Usage: r2_analyze.sh <binary> <afl_out> <callgraph_out> <decomp_out>
set -euo pipefail

binary="$1"
afl_out="$2"
callgraph_out="$3"
decomp_out="$4"

r2_dir="$(cd "$(dirname "$0")/radare2" && pwd)"
r2="${r2_dir}/bin/r2"
export LD_LIBRARY_PATH="${r2_dir}/lib${LD_LIBRARY_PATH:+:${LD_LIBRARY_PATH}}"

# -A: full analysis (required for agCj; also covers afl).
# Each -c runs sequentially; r2's > redirects that command's output to a file.
# pdc @@=`afl~[0]`: decompile every function whose address appears in afl output.
#   The backticks are r2 subcommand substitution (not shell); use single quotes to
#   prevent the shell from expanding them, then append the shell-expanded path.
decomp_cmd='pdc @@=`afl~[0]` > '"${decomp_out}"

"${r2}" -A -Q -q -e scr.color=0 -e bin.demangle=true \
    -c "afl > ${afl_out}" \
    -c "agCj > ${callgraph_out}" \
    -c "${decomp_cmd}" \
    "${binary}" 2>/dev/null

python3 -m json.tool "${callgraph_out}" > "${callgraph_out}.pretty" && mv "${callgraph_out}.pretty" "${callgraph_out}"
