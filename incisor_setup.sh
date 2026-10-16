#!/usr/bin/env bash

arch=$(uname -m)
if [ "${arch}" == "aarch64" ]; then
    prom_platform="arm64"
else
    prom_platform="amd64"
fi

install_prereq="true"
install_mpi="true"
install_prom="true"
launch_prom="true"
kill_prom="false"
scrape_interval_s=10
logname=service.log

mondir="incisor/prometheus"
mkdir -p ${mondir}

function service_run(){
    $* > ${logname} 2>&1 &
    pid=${!}
    echo "${pid}"
}

function node_export(){
    mkdir $1 && cd $1
    wget https://github.com/prometheus/node_exporter/releases/download/v1.10.2/node_exporter-1.10.2.linux-${prom_platform}.tar.gz
    tar xf node_exporter-1.10.2.linux-${prom_platform}.tar.gz
    echo $(service_run ./node_exporter-1.10.2.linux-${prom_platform}/node_exporter)
}

function gpu_export(){
    if [ "$(which nvidia-smi)" == "" ]; then
	return
    fi
    g_platform="${prom_platform}"
    if [ "${g_platform}" == "amd64" ]; then
	g_platform="x86_64"
    fi
    mkdir $1 && cd $1
    wget https://github.com/utkuozdemir/nvidia_gpu_exporter/releases/download/v1.4.1/nvidia_gpu_exporter_1.4.1_linux_${g_platform}.tar.gz
    tar xf nvidia_gpu_exporter_1.4.1_linux_${g_platform}.tar.gz
    echo $(service_run ./nvidia_gpu_exporter)
}

function prom_collect(){
    mkdir $1 && cd $1
    wget https://github.com/prometheus/prometheus/releases/download/v3.9.1/prometheus-3.9.1.linux-${prom_platform}.tar.gz
    tar xf prometheus-3.9.1.linux-${prom_platform}.tar.gz
    scrape="${scrape_interval_s}s"
    cat <<EOF > prometheus-local.yml
global:
  scrape_interval: $scrape

scrape_configs:
- job_name: node
  static_configs:
  - targets: ['localhost:9100']
- job_name: nvidia_gpu
  static_configs:
  - targets: ['localhost:9835']
EOF
    echo $(service_run ./prometheus-3.9.1.linux-${prom_platform}/prometheus --config.file=prometheus-local.yml --storage.tsdb.path=../incisor_tsdb)
}

function launch_collectors(){
    (
	cd ${mondir}
	tn=$(node_export node_exporter)
	tg=$(gpu_export gpu_exporter)
	tp=$(prom_collect prometheus_collector)
	echo "${tn} ${tg} ${tp}"
    )
}



if [ "${install_prereq}" == "true" ]; then
    sudo apt update
    sudo apt-get install -y gfortran linux-headers-$(uname -r) linux-modules-extra-$(uname -r)
fi

if [ "${install_mpi}" == "true" ]; then
    sudo apt update
    sudo apt-get install -y openmpi-bin openmpi-common libopenmpi-dev
fi

if [ "${install_prom}" == "true" ]; then
    sudo apt update
    sudo apt-get install -y linux-tools-generic linux-tools-common
    sudo setcap cap_perfmon=+ep /usr/bin/perf
    sudo sysctl kernel.perf_event_paranoid=0
fi

tlist=""
if [ "${launch_prom}" == "true" ]; then
    tlist=$(launch_collectors)
    echo "Collection Tasks: ${tlist}"
fi

if [ "${kill_prom}" == "true" ]; then
    kill -9 ${tlist}
fi

sleep "$[${scrape_interval_s}+1]"
echo "Prometheus artifacts can be found in $(pwd)/${mondir}"
