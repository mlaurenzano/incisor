#!/usr/bin/env bash

scrape_interval_s=10

function print_usage(){
    echo "usage: $0 <binary_or_py_file>"
}

if [ "$1" == "" ]; then
    echo "error: no input file supplied"
    print_usage
    exit 1
fi

if [ ! -f "$1" ]; then
    echo "error: input file not found"
    print_usage
    exit 2
fi

infile="$1"
sha1=$(sha1sum "${infile}" | awk '{ print $1 }')
timest=$(date +%F-%H-%M-%S)
bname=$(basename "$1")
mondir="incisor/${bname}_${sha1}_${timest}"
mkdir -p ${mondir}
adir="${mondir}/incisor_env"
mkdir -p ${adir}
ifile="${mondir}/incisor_pyimports"

function info(){
    echo "***** $1 ***** $2"
}

function str_to_fname(){
    echo $1 | tr '[:upper:]' '[:lower:]' | tr -cs 'a-z0-9._-' '_' | tr '.' '_'
}

function analyze_impl(){
    echo "##### cmd=\"${2}\""
    bash -c "$1"
    echo "##### ret=${?}"
}

function analyze(){
    if [ "${OMPI_COMM_WORLD_RANK}" == "" -o "${OMPI_COMM_WORLD_RANK}" == "0" ]; then
	if [ "${2}" != "" ]; then
	    name="${2}"
	else
	    name="${1}"
	fi
	info "SA PASS=${1}" "$1"
	fname=$(str_to_fname "${name}")
	analyze_impl "$1" "$1" > "${adir}/pass_${fname}" 2>&1
    fi
}

function analyze_infile(){
    analyze "$1 $(realpath ${infile})" "$1"
}

function emit_py_runner(){
    fname=$(mktemp --suffix .py)
    cat > ${fname} <<EOF
import os
import sys
import importlib.util
save_argv = sys.argv.copy()
sys.argv = sys.argv[1:]
spec = importlib.util.spec_from_file_location("__main__", sys.argv[0])
module = importlib.util.module_from_spec(spec)
module.__name__ = "__main__"
sys.modules["__main__"] = module
spec.loader.exec_module(module)
sys.argv = save_argv
def save_imports(fname):
    print(f"***** Writing py import list to {fname}")
    with open(fname, "w") as fh:
        for k, v in sys.modules.items():
            fh.write(f"{k} {v}\n")
save_imports("${ifile}")
EOF
    echo ${fname}
}

function detect_exec_class(){
    file $(realpath $1) | grep "Python script" > /dev/null 2>&1 
    if [ "$?" == "0" ]; then
	echo "python" && return
    fi
    file $(realpath $1) | grep "ELF 64-bit LSB" > /dev/null 2>&1
    if [ "$?" == "0" ]; then
	echo "elf-exec" && return
    fi
    file $(realpath $1) | grep "Bourne-Again shell script" > /dev/null 2>&1
    if [ "$?" == "0" ]; then
	echo "bash" && return
    fi
    echo "unknown"
}

info "ENVIRONMENT" ""
analyze "uname -a"
analyze "whoami"
analyze "systemd-detect-virt"
analyze "lscpu"
analyze "cat /proc/meminfo"
analyze "nproc --all"
analyze "cat /proc/cpuinfo"
analyze "getconf -a"
analyze "nvidia-smi"
analyze "cat /usr/local/cuda/version.json"
analyze "perf list --raw-dump"
analyze "env"
analyze "echo $*"

class=$(detect_exec_class ${infile})
info "PROGRAM class=${class}"
analyze_infile "file"

if [ "${class}" == "elf-exec" ]; then
    analyze_infile "readelf -h"
    analyze_infile "readelf -s"
    analyze_infile "objdump -d"
    analyze_infile "ldd"
elif [ "${class}" == "python" ]; then
    analyze "pip3 freeze"
else
    info "Unhandled exec class found for ${infile}: ${class}"
fi


analyze "df --sync -a"
analyze "date +before=%s"


scrape_ms=$[${scrape_interval_s}*1000]
if [ "${class}" == "python" ]; then
    runner=$(emit_py_runner)
    python3 ${runner} $* || true
    rm -f ${runner}
else
    bash -c "$*" || true
fi
analyze "date +after=%s"
analyze "df --sync -aa"
analyze "du -s incisor"

myrank=0
if [ "${ADVISER_NODE_RANK}" != "" ]; then
    myrank="${ADVISER_NODE_RANK}"
fi

if [ "${OMPI_COMM_WORLD_RANK}" == "" -o "${OMPI_COMM_WORLD_RANK}" == "0" ]; then
    mv ${mondir} ${mondir}_r${myrank}
    mondir="${mondir}_r${myrank}"
    info "Analysis on ${infile} can be found in ${mondir}"
fi
