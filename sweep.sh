#!/usr/bin/env bash

npar=1
runtyp="$1"
cli=./incisor_run

if [ "${runtyp}" != "rank1" -a "${runtyp}" != "expsky" -a "${runtyp}" != "sky" -a "${runtyp}" != "" ]; then
    echo "invalid runtyp: ${runtyp}"
    exit 1
fi

bench=$(cat <<EOF
hec_omp_n16_bezier
EOF
)

llm_config="$(cd "$(dirname "$0")" && pwd)/agents/llm_config.json"
analysis_dir=$(jq -r '.analysis_dir' "${llm_config}")

run_analysis_if_needed() {
    local b="$1"
    if [ "${runtyp}" == "expsky" ]; then
	inst=$(cat "${b}/expert/skypilot_expert.txt" | head -1)
	${cli} "${b}" "${inst}"
    elif [ "${runtyp}" == "sky" ]; then
	inst=$(cat "${b}/expert/skypilot_only.txt" | head -1)
	${cli} "${b}" "${inst}"
    else
	if [ ! -d "${b}/${analysis_dir}" ]; then
            echo "####### Running ${b}"
            ${cli} "${b}"
	else
            echo "####### Skipping analysis of ${b} (${analysis_dir} exists)"
	fi
	if [ "${runtyp}" == "rank1" ]; then
	    if [ ! -s "${b}/${analysis_dir}/instances.json" ]; then
		echo "####### No instances.json for ${b}; cannot launch"
		return 1
	    fi
	    inst=$(./list_instances.py "${b}/${analysis_dir}/instances.json" | head -1)
	    if [ -d "${b}/${inst}" ]; then
		echo "####### Skipping launch of ${b} on ${inst} (run directory exists)"
	    else
		echo "####### Launching ${b} on ${inst}"
		${cli} "${b}" "${inst}"
	    fi
	fi
    fi
}
export -f run_analysis_if_needed
run_instances_if_needed() {
    local b="$1"
    if [ ! -f "${b}/${analysis_dir}/instances.json" ]; then
        echo "####### Running ${b}"
        ./just_instances.sh "${b}"
    else
        echo "####### Skipping ${b} (${analysis_dir}/instances.json exists)"
    fi
}
export -f run_instances_if_needed
export analysis_dir
export runtyp
export cli

parallel -j ${npar} run_analysis_if_needed ::: ${bench}
