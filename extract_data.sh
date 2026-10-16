#!/bin/bash
set -e

script_dir="$(cd "$(dirname "$0")" && pwd)"

# Extract job ID from run.log in the specified directory

if [[ -z "$1" ]]; then
    echo "Usage: $0 <directory>" >&2
    exit 1
fi

run_log="$1/run.log"

if [[ ! -f "$run_log" ]]; then
    echo "Error: $run_log not found" >&2
    exit 1
fi

job_id=0001

# Extract and display infrastructure details from run.log
infra_table=$(grep -A 5 "^Considered resources" "$run_log" | sed 's/\x1b\[[0-9;]*m//g')

# Parse the data line (contains cloud provider like AWS, GCP, Azure)
infra_line=$(echo "$infra_table" | grep -E '^\s*(AWS|GCP|Azure)' | head -1)
cloud_provider=$(echo "$infra_line" | awk '{print $1}')
cloud_region=$(echo "$infra_line" | awk '{print $2}' | tr -d '()')
instance_type=$(echo "$infra_line" | awk '{print $3}')
vcpus=$(echo "$infra_line" | awk '{print $4}')
mem_gb=$(echo "$infra_line" | awk '{print $5}')
gpus=$(echo "$infra_line" | awk '{print $6}')
cost_per_hour=$(echo "$infra_line" | awk '{print $7}')

echo "Incisor Job ID: $job_id"
echo "Cloud provider: $cloud_provider"
echo "Region: $cloud_region"
echo "Instance type: $instance_type"
echo "vCPUs: $vcpus"
echo "Memory: ${mem_gb} GB"
echo "GPUs: $gpus"
echo "Cost per hour: \$${cost_per_hour}"
echo ""

# Export for use in subshell
export cost_per_hour

(
    cd "$1"
    output_dir="incisor_output/$job_id"

    if [[ ! -d "$output_dir" ]]; then
        echo "Error: $output_dir directory not found" >&2
        exit 1
    fi

    # Find the slug from a rank-0 directory in incisor/
    slug_dir=$(find "$output_dir/incisor" -maxdepth 1 -type d -name '*_r0' | head -1)
    if [[ -z "$slug_dir" ]]; then
        echo "Error: No slug directories found in $output_dir/incisor" >&2
        exit 1
    fi

    # Extract slug by removing _r<rank> suffix
    filename=$(basename "$slug_dir")
    slug=$(echo "$filename" | sed 's/_r[0-9]*$//')

    # Count ranks by counting slug directories
    num_ranks=$(find "$output_dir/incisor" -maxdepth 1 -type d -name "${slug}_r*" | wc -l)

    # Initialize accumulators for infrastructure requirements
    total_utilized_cpus=0
    total_cpu_count=0
    total_mem_total=0
    total_min_mem_avail=0
    total_max_mem_avail=0
    total_xmm_count=0
    total_zmm_count=0
    total_neon_count=0
    total_sve_count=0
    requires_gpu=false
    requires_mpi=false
    has_openmp_indicators=false
    has_omp_num_threads_gt1=false
    has_python_math=false
    has_python_parallel=false
    static_architecture=""
    # CPU mode accumulators (total seconds across all ranks)
    total_idle_seconds=0
    total_user_seconds=0
    total_system_seconds=0
    total_iowait_seconds=0
    total_steal_seconds=0
    total_irq_seconds=0
    total_softirq_seconds=0
    total_nice_seconds=0
    total_elapsed_seconds=0
    # Scheduler stats accumulators
    total_schedstat_running_seconds=0
    total_schedstat_waiting_seconds=0
    # Memory pressure (PSI) accumulators
    total_mem_pressure_stalled_seconds=0
    total_mem_pressure_waiting_seconds=0
    # CPU pressure (PSI) accumulator
    total_cpu_pressure_waiting_seconds=0
    # I/O pressure (PSI) accumulators
    total_io_pressure_stalled_seconds=0
    total_io_pressure_waiting_seconds=0
    # GPU utilization accumulator (collected lines across all ranks)
    all_gpu_utilization=""

    if [[ ! -d "$output_dir/incisor" ]]; then
        echo "Error: incisor/ directory not found" >&2
        exit 1
    fi

    echo "Number of ranks: $num_ranks"
    echo "Slug: $slug"

    # Decompose slug: <app_name>_<sha1sum>_<timestamp>
    # sha1sum is exactly 40 hex characters
    if [[ $slug =~ ^(.+)_([0-9a-f]{40})_([^_]+)$ ]]; then
        app_name="${BASH_REMATCH[1]}"
        app_sha1sum="${BASH_REMATCH[2]}"
        run_timestamp="${BASH_REMATCH[3]}"
        echo "App name: $app_name"
        echo "App SHA1: $app_sha1sum"
        echo "Run timestamp: $run_timestamp"
    else
        echo "Error: Could not parse slug format" >&2
        exit 1
    fi

    # Calculate run cost from rank 0 timestamps
    rank0_slug_dir="$output_dir/incisor/${slug}_r0"
    rank0_date_before=$(sed -n '2p' "$rank0_slug_dir/incisor_env/pass_date_before_s_" | cut -d= -f2)
    rank0_date_after=$(sed -n '2p' "$rank0_slug_dir/incisor_env/pass_date_after_s_" | cut -d= -f2)
    run_runtime_s=$((rank0_date_after - rank0_date_before))
    run_hours=$(awk "BEGIN {printf \"%.6f\", $run_runtime_s / 3600}")
    run_cost=$(awk "BEGIN {printf \"%.4f\", $run_hours * $cost_per_hour}")
    echo ""
    echo "Run cost: \$${run_cost} ${run_runtime_s} Runtime(s) at \$${cost_per_hour} price (\$/hr)"
    echo ""

    # Verify extracted directory structure for each rank
    for ((i=0; i<num_ranks; i++)); do
        slug_dir="$output_dir/incisor/${slug}_r${i}"
        prom_dir="$output_dir/incisor/prometheus"

        if [[ ! -d "$slug_dir" ]]; then
            echo "Error: Missing $slug_dir" >&2
            exit 1
        fi
        if [[ ! -d "$prom_dir" ]]; then
            echo "Error: Missing $prom_dir" >&2
            exit 1
        fi

        # Verify slug directory contents
        if [[ ! -d "$slug_dir/incisor_env" ]]; then
            echo "Error: Missing $slug_dir/incisor_env/" >&2
            exit 1
        fi
        if [[ ! -f "$slug_dir/perf.txt" ]]; then
            echo "Warning: Missing $slug_dir/perf.txt" >&2
        fi

        # Verify incisor_env files (common to both python and executable runs)
        incisor_env_files=(
            "pass_cat_proc_cpuinfo_"
            "pass_cat_proc_meminfo_"
            "pass_cat_usr_local_cuda_version_json_"
            "pass_date_after_s_"
            "pass_date_before_s_"
            "pass_df_--sync_-a_"
            "pass_df_--sync_-aa_"
            "pass_du_-s_incisor_"
            "pass_env_"
            "pass_file_"
            "pass_getconf_-a_"
            "pass_lscpu_"
            "pass_nproc_--all_"
            "pass_nvidia-smi_"
            "pass_perf_list_--raw-dump_"
            "pass_systemd-detect-virt_"
            "pass_uname_-a_"
            "pass_whoami_"
        )
        for env_file in "${incisor_env_files[@]}"; do
            if [[ ! -f "$slug_dir/incisor_env/$env_file" ]]; then
                echo "Error: Missing $slug_dir/incisor_env/$env_file" >&2
                exit 1
            fi
        done

        # Executable-only files in incisor_env/
        exec_env_files=(
            "pass_ldd_"
            "pass_objdump_-d_"
            "pass_readelf_-h_"
            "pass_readelf_-s_"
        )

        # Check for python run indicators
        has_pyimports=false
        if [[ -f "$slug_dir/incisor_pyimports" ]]; then
            has_pyimports=true
        fi

        # Check for executable run indicators
        exec_file_count=0
        for exec_file in "${exec_env_files[@]}"; do
            if [[ -f "$slug_dir/incisor_env/$exec_file" ]]; then
                ((++exec_file_count))
            fi
        done

        # Determine run type and validate
        if [[ "$has_pyimports" == true && "$exec_file_count" -gt 0 ]]; then
            echo "Error: Both python and executable indicators found for rank $i" >&2
            exit 1
        elif [[ "$has_pyimports" == true ]]; then
            echo "Rank $i: python run"
            static_architecture="Python/any"

            # Check for GPU/CUDA-related packages in pyimports
            pyimports_file="$slug_dir/incisor_pyimports"
            for pkg in torch tensorflow cuda cupy pycuda numba jax mxnet; do
                if grep -q "^${pkg} " "$pyimports_file"; then
                    echo "Rank $i python GPU package $pkg: yes"
                    requires_gpu=true
                else
                    echo "Rank $i python GPU package $pkg: no"
                fi
            done

            # Check for MPI packages
            for pkg in mpi4py petsc4py; do
                if grep -q "^${pkg} " "$pyimports_file"; then
                    echo "Rank $i python MPI package $pkg: yes"
                    requires_mpi=true
                else
                    echo "Rank $i python MPI package $pkg: no"
                fi
            done

            # Check for thread/process parallelism packages (non-MPI)
            for pkg in multiprocessing threading concurrent asyncio joblib dask ray celery; do
                if grep -q "^${pkg} " "$pyimports_file"; then
                    echo "Rank $i python parallel package $pkg: yes"
                    has_python_parallel=true
                else
                    echo "Rank $i python parallel package $pkg: no"
                fi
            done

            # Check for math/numerical libraries (may use SSE/AVX)
            for pkg in numpy scipy pandas sklearn numexpr mkl openblas bottleneck; do
                if grep -q "^${pkg} " "$pyimports_file"; then
                    echo "Rank $i python math package $pkg: yes"
                    has_python_math=true
                else
                    echo "Rank $i python math package $pkg: no"
                fi
            done
        elif [[ "$exec_file_count" -eq 4 ]]; then
            echo "Rank $i: executable run"

            # Extract architecture from readelf -h
            readelf_h_file="$slug_dir/incisor_env/pass_readelf_-h_"
            static_architecture=$(grep '^\s*Machine:' "$readelf_h_file" | sed 's/^\s*Machine:\s*//')

            # Extract executable-specific details
            ldd_file="$slug_dir/incisor_env/pass_ldd_"
            readelf_s_file="$slug_dir/incisor_env/pass_readelf_-s_"
            objdump_d_file="$slug_dir/incisor_env/pass_objdump_-d_"

            # Check for library dependencies
            for lib in libgomp libcuda libcublas libnvidia libmpi libpthread libevent_pthreads; do
                if grep -q "$lib" "$ldd_file"; then
                    echo "Rank $i $lib dependency: yes"
                    # Track GPU-related dependencies
                    if [[ "$lib" == "libcuda" || "$lib" == "libcublas" || "$lib" == "libnvidia" ]]; then
                        requires_gpu=true
                    fi
                    # Track MPI dependency
                    if [[ "$lib" == "libmpi" ]]; then
                        requires_mpi=true
                    fi
                    # Track OpenMP dependency
                    if [[ "$lib" == "libgomp" ]]; then
                        has_openmp_indicators=true
                    fi
                else
                    echo "Rank $i $lib dependency: no"
                fi
            done

            # Count symbols in readelf -s
            omp_symbol_count=$(grep -c 'OMP_' "$readelf_s_file" || true)
            echo "Rank $i OMP_ symbols: $omp_symbol_count"
            if [[ $omp_symbol_count -gt 0 ]]; then
                has_openmp_indicators=true
            fi
            mpi_symbol_count=$(grep -c 'MPI_' "$readelf_s_file" || true)
            echo "Rank $i MPI_ symbols: $mpi_symbol_count"
            if [[ $mpi_symbol_count -gt 0 ]]; then
                requires_mpi=true
            fi
            nvml_symbol_count=$(grep -c 'nvml' "$readelf_s_file" || true)
            echo "Rank $i nvml symbols: $nvml_symbol_count"
            if [[ $nvml_symbol_count -gt 0 ]]; then
                requires_gpu=true
            fi

            # Count xmm register usage in objdump -d
            xmm_count=$(grep -cE '%xmm[0-9]+' "$objdump_d_file" || true)
            echo "Rank $i xmm register lines: $xmm_count"
            total_xmm_count=$((total_xmm_count + xmm_count))

            # Count zmm register usage in objdump -d
            zmm_count=$(grep -cE '%zmm[0-9]+' "$objdump_d_file" || true)
            echo "Rank $i zmm register lines: $zmm_count"
            total_zmm_count=$((total_zmm_count + zmm_count))

            # Count ARMv8 NEON register usage in objdump -d (v0-v31 with size specifiers)
            neon_count=$(grep -cE 'v[0-9]+\.(16b|8b|8h|4h|4s|2s|2d|1d|b|h|s|d)' "$objdump_d_file" || true)
            echo "Rank $i NEON register lines: $neon_count"
            total_neon_count=$((total_neon_count + neon_count))

            # Count ARMv8 SVE register usage in objdump -d (z0-z31, p0-p15 with specifiers)
            sve_z_count=$(grep -cE 'z[0-9]+\.(b|h|s|d)' "$objdump_d_file" || true)
            sve_p_count=$(grep -cE 'p[0-9]+[/\.]' "$objdump_d_file" || true)
            sve_count=$((sve_z_count + sve_p_count))
            echo "Rank $i SVE register lines: $sve_count"
            total_sve_count=$((total_sve_count + sve_count))
        elif [[ "$exec_file_count" -gt 0 ]]; then
            echo "Error: Incomplete executable files for rank $i (found $exec_file_count/4)" >&2
            exit 1
        else
            echo "Error: Neither python nor executable indicators found for rank $i" >&2
            exit 1
        fi

        # Count environment variables from pass_env_
        env_file="$slug_dir/incisor_env/pass_env_"
        ompi_env_count=$(grep -c '^OMPI_' "$env_file" || true)
        echo "Rank $i OMPI_ env vars: $ompi_env_count"
        omp_env_count=$(grep -c '^OMP_' "$env_file" || true)
        echo "Rank $i OMP_ env vars: $omp_env_count"
        omp_num_threads=$(grep '^OMP_NUM_THREADS=' "$env_file" | cut -d= -f2 || true)
        echo "Rank $i OMP_NUM_THREADS: ${omp_num_threads:--}"
        if [[ -n "$omp_num_threads" && "$omp_num_threads" -gt 1 ]]; then
            has_omp_num_threads_gt1=true
        fi
        ompi_comm_world_size=$(grep '^OMPI_COMM_WORLD_SIZE=' "$env_file" | cut -d= -f2 || true)
        echo "Rank $i OMPI_COMM_WORLD_SIZE: ${ompi_comm_world_size:--}"

        # Extract command line from pass_echo file
        pass_echo_file=$(find "$slug_dir/incisor_env" -name 'pass_echo_*' | head -1)
        if [[ -z "$pass_echo_file" ]]; then
            echo "Error: No pass_echo file found for rank $i" >&2
            exit 1
        fi
        cmd_line=$(sed -n '2p' "$pass_echo_file")
        echo "Rank $i command: $cmd_line"

        # Extract timestamps
        date_before=$(sed -n '2p' "$slug_dir/incisor_env/pass_date_before_s_" | cut -d= -f2)
        date_after=$(sed -n '2p' "$slug_dir/incisor_env/pass_date_after_s_" | cut -d= -f2)
        echo "Rank $i date_before: $date_before"
        echo "Rank $i date_after: $date_after"
        runtime=$((date_after - date_before))
        echo "Rank $i runtime: ${runtime}s"

        # Extract memory info (values in kB, convert to bytes)
        meminfo_file="$slug_dir/incisor_env/pass_cat_proc_meminfo_"
        mem_total_kb=$(grep '^MemTotal:' "$meminfo_file" | awk '{print $2}')
        mem_avail_kb=$(grep '^MemAvailable:' "$meminfo_file" | awk '{print $2}')
        mem_total_bytes=$((mem_total_kb * 1024))
        mem_avail_bytes=$((mem_avail_kb * 1024))
        echo "Rank $i MemTotal: $mem_total_bytes bytes"
        echo "Rank $i MemAvailable: $mem_avail_bytes bytes"
        total_mem_total=$((total_mem_total + mem_total_bytes))

        # Extract CPU info from lscpu
        lscpu_file="$slug_dir/incisor_env/pass_lscpu_"
        cpu_arch=$(grep '^Architecture:' "$lscpu_file" | awk '{print $2}')
        cpu_count=$(grep '^CPU(s):' "$lscpu_file" | awk '{print $2}')
        total_cpu_count=$((total_cpu_count + cpu_count))
        cpu_vendor=$(grep '^Vendor ID:' "$lscpu_file" | awk '{print $3}')
        cpu_model=$(grep '^Model name:' "$lscpu_file" | sed 's/^Model name:[[:space:]]*//')
        threads_per_core=$(grep '^Thread(s) per core:' "$lscpu_file" | awk '{print $4}')
	pcpu_count=$[$cpu_count/$threads_per_core]
        cores_per_socket=$(grep '^Core(s) per socket:' "$lscpu_file" | awk '{print $4}')
        sockets=$(grep '^Socket(s):' "$lscpu_file" | awk '{print $2}')
        cpu_flags=$(grep '^Flags:' "$lscpu_file" | sed 's/^Flags:[[:space:]]*//')
        l1d_cache=$(grep '^L1d cache:' "$lscpu_file" | sed 's/^L1d cache:[[:space:]]*//')
        l1i_cache=$(grep '^L1i cache:' "$lscpu_file" | sed 's/^L1i cache:[[:space:]]*//')
        l2_cache=$(grep '^L2 cache:' "$lscpu_file" | sed 's/^L2 cache:[[:space:]]*//')
        l3_cache=$(grep '^L3 cache:' "$lscpu_file" | sed 's/^L3 cache:[[:space:]]*//')
        numa_nodes=$(grep '^NUMA node(s):' "$lscpu_file" | awk '{print $3}')

        echo "Rank $i Architecture: $cpu_arch"
        echo "Rank $i vCPU(s): $cpu_count"
        echo "Rank $i pCPU(s): $pcpu_count"
        echo "Rank $i Vendor ID: $cpu_vendor"
        echo "Rank $i Model name: $cpu_model"
        echo "Rank $i Thread(s) per core: $threads_per_core"
        echo "Rank $i Core(s) per socket: $cores_per_socket"
        echo "Rank $i Socket(s): $sockets"
        echo "Rank $i L1d cache: $l1d_cache"
        echo "Rank $i L1i cache: $l1i_cache"
        echo "Rank $i L2 cache: $l2_cache"
        echo "Rank $i L3 cache: $l3_cache"
        echo "Rank $i NUMA node(s): $numa_nodes"

        # Extract NUMA node CPU mappings
        for ((n=0; n<numa_nodes; n++)); do
            numa_cpus=$(grep "^NUMA node${n} CPU(s):" "$lscpu_file" | sed "s/^NUMA node${n} CPU(s):[[:space:]]*//")
            echo "Rank $i NUMA node${n} CPU(s): $numa_cpus"
        done

        echo "Rank $i Flags: $cpu_flags"

        # Dump prometheus TSDB and extract minimum MemAvailable
	promtool="${script_dir}/prometheus-3.9.1.linux-amd64/promtool"
        tsdb_path="$prom_dir/incisor_tsdb"
        tsdb_dump="$output_dir/incisor/tsdb_dump_r${i}.txt"
        "$promtool" tsdb dump "$tsdb_path" > "$tsdb_dump"

        date_before_ms=$((date_before * 1000))
        # Find minimum MemAvailable: output "bytes timestamp" for the minimum bytes value
        min_entry=$(grep 'node_memory_MemAvailable_bytes' "$tsdb_dump" | awk '{print $(NF-1), $NF}' | sort -g | head -1)
        min_bytes=$(echo "$min_entry" | awk '{print $1}')
        min_timestamp_ms=$(echo "$min_entry" | awk '{print $2}')
        min_relative_ms=$((min_timestamp_ms - date_before_ms))
        min_bytes_int=$(printf "%.0f" "$min_bytes")
        echo "Rank $i min MemAvailable: ${min_bytes_int} bytes at ${min_relative_ms}ms"
        total_min_mem_avail=$((total_min_mem_avail + min_bytes_int))

        # Find maximum MemAvailable: output "bytes timestamp" for the maximum bytes value
        max_entry=$(grep 'node_memory_MemAvailable_bytes' "$tsdb_dump" | awk '{print $(NF-1), $NF}' | sort -rg | head -1)
        max_bytes=$(echo "$max_entry" | awk '{print $1}')
        max_timestamp_ms=$(echo "$max_entry" | awk '{print $2}')
        max_relative_ms=$((max_timestamp_ms - date_before_ms))
        max_bytes_int=$(printf "%.0f" "$max_bytes")
        echo "Rank $i max MemAvailable: ${max_bytes_int} bytes at ${max_relative_ms}ms"
        total_max_mem_avail=$((total_max_mem_avail + max_bytes_int))

        date_after_ms=$((date_after * 1000))

        # Extract memory pressure (PSI) metrics - monotonic counters, compute delta during run
        for psi_metric in node_pressure_memory_stalled_seconds_total node_pressure_memory_waiting_seconds_total; do
            psi_delta=$(grep "$psi_metric" "$tsdb_dump" | \
                awk -v ts_start="$date_before_ms" -v ts_end="$date_after_ms" '{
                    val = $(NF-1); ts = $NF
                    if (ts >= ts_start && ts <= ts_end) {
                        if (first_ts == "") { first_val = val; first_ts = ts }
                        last_val = val; last_ts = ts
                    }
                }
                END {
                    if (first_ts != "" && last_ts != first_ts)
                        printf "%.4f", last_val - first_val
                    else
                        printf "0.0000"
                }')
            echo "Rank $i ${psi_metric}: ${psi_delta}s"
            if [[ "$psi_metric" == "node_pressure_memory_stalled_seconds_total" ]]; then
                total_mem_pressure_stalled_seconds=$(awk "BEGIN {printf \"%.4f\", $total_mem_pressure_stalled_seconds + $psi_delta}")
            else
                total_mem_pressure_waiting_seconds=$(awk "BEGIN {printf \"%.4f\", $total_mem_pressure_waiting_seconds + $psi_delta}")
            fi
        done

        # Extract CPU pressure (PSI) metric - monotonic counter, compute delta during run
        psi_delta=$(grep "node_pressure_cpu_waiting_seconds_total" "$tsdb_dump" | \
            awk -v ts_start="$date_before_ms" -v ts_end="$date_after_ms" '{
                val = $(NF-1); ts = $NF
                if (ts >= ts_start && ts <= ts_end) {
                    if (first_ts == "") { first_val = val; first_ts = ts }
                    last_val = val; last_ts = ts
                }
            }
            END {
                if (first_ts != "" && last_ts != first_ts)
                    printf "%.4f", last_val - first_val
                else
                    printf "0.0000"
            }')
        echo "Rank $i node_pressure_cpu_waiting_seconds_total: ${psi_delta}s"
        total_cpu_pressure_waiting_seconds=$(awk "BEGIN {printf \"%.4f\", $total_cpu_pressure_waiting_seconds + $psi_delta}")

        # Extract I/O pressure (PSI) metrics - monotonic counters, compute delta during run
        for psi_metric in node_pressure_io_stalled_seconds_total node_pressure_io_waiting_seconds_total; do
            psi_delta=$(grep "$psi_metric" "$tsdb_dump" | \
                awk -v ts_start="$date_before_ms" -v ts_end="$date_after_ms" '{
                    val = $(NF-1); ts = $NF
                    if (ts >= ts_start && ts <= ts_end) {
                        if (first_ts == "") { first_val = val; first_ts = ts }
                        last_val = val; last_ts = ts
                    }
                }
                END {
                    if (first_ts != "" && last_ts != first_ts)
                        printf "%.4f", last_val - first_val
                    else
                        printf "0.0000"
                }')
            echo "Rank $i ${psi_metric}: ${psi_delta}s"
            if [[ "$psi_metric" == "node_pressure_io_stalled_seconds_total" ]]; then
                total_io_pressure_stalled_seconds=$(awk "BEGIN {printf \"%.4f\", $total_io_pressure_stalled_seconds + $psi_delta}")
            else
                total_io_pressure_waiting_seconds=$(awk "BEGIN {printf \"%.4f\", $total_io_pressure_waiting_seconds + $psi_delta}")
            fi
        done

        # Extract NVIDIA GPU utilization metrics (may not exist)
        for gpu_metric in nvidia_smi_utilization_gpu_ratio nvidia_smi_utilization_memory_ratio; do
            gpu_metric_output=$(grep "$gpu_metric" "$tsdb_dump" | \
                awk -v ts_start="$date_before_ms" -v ts_end="$date_after_ms" -v rank="$i" -v metric="$gpu_metric" '
                {
                    # Extract uuid from the label string
                    uuid = ""
                    if (match($0, /uuid="[^"]+"/)) {
                        uuid = substr($0, RSTART+6, RLENGTH-7)
                    }
                    val = $(NF-1); ts = $NF
                    if (ts >= ts_start && ts <= ts_end && uuid != "") {
                        sum[uuid] += val
                        count[uuid]++
                    }
                }
                END {
                    for (uuid in sum) {
                        avg = sum[uuid] / count[uuid]
                        printf "Rank %s %s uuid %s: %.4f (avg over %d samples)\n", rank, metric, uuid, avg, count[uuid]
                    }
                }')
            if [[ -n "$gpu_metric_output" ]]; then
                echo "$gpu_metric_output"
                all_gpu_utilization+="${gpu_metric_output}"$'\n'
            fi
        done

        # Calculate CPU time for each mode (idle, user, system, iowait)
        # Extract cpu number, seconds, and timestamp; sort by cpu then timestamp
        # Only include data points where both current and previous timestamps are within [date_before, date_after]

        # Function-like pattern to extract CPU mode stats
        # Arguments: mode name, tsdb_dump file, rank, ts_start, ts_end
        extract_cpu_mode_stats() {
            local mode="$1"
            local tsdb_file="$2"
            local rank="$3"
            local ts_start="$4"
            local ts_end="$5"

            grep "node_cpu_seconds_total.*mode=\"${mode}\"" "$tsdb_file" | \
                awk -F'[," ]' '{
                    for (j=1; j<=NF; j++) {
                        if ($j == "cpu=") cpu = $(j+1)
                    }
                    print cpu, $(NF-1), $NF
                }' | sort -k1,1n -k3,3n | \
                awk -v rank="$rank" -v mode="$mode" -v ts_start="$ts_start" -v ts_end="$ts_end" '{
                    cpu = $1; val = $2; ts = $3
                    if (!(cpu in prev_ts)) {
                        prev_ts[cpu] = ts
                        prev_val[cpu] = val
                        cpu_count++
                        next
                    }
                    if (prev_ts[cpu] >= ts_start && prev_ts[cpu] <= ts_end && ts >= ts_start && ts <= ts_end) {
                        if (!(cpu in first_val)) {
                            first_val[cpu] = prev_val[cpu]
                            first_ts[cpu] = prev_ts[cpu]
                        }
                        last_val[cpu] = val
                        last_ts[cpu] = ts
                    }
                    prev_ts[cpu] = ts
                    prev_val[cpu] = val
                }
                END {
                    total_mode = 0
                    total_elapsed = 0
                    for (cpu in first_val) {
                        increase = last_val[cpu] - first_val[cpu]
                        elapsed_ms = last_ts[cpu] - first_ts[cpu]
                        elapsed_s = elapsed_ms / 1000
                        pct = (elapsed_s > 0) ? (increase / elapsed_s * 100) : 0
                        printf "Rank %s cpu %s: %.2f %s over %.2fs (%.1f%% %s)\n", rank, cpu, increase, mode, elapsed_s, pct, mode
                        total_mode += increase
                        total_elapsed += elapsed_s
                    }
                    total_pct = (total_elapsed > 0) ? (total_mode / total_elapsed * 100) : 0
                    printf "Rank %s total: %.2f %s over %.2fs across %d CPUs (%.1f%% %s)\n", rank, total_mode, mode, total_elapsed, cpu_count, total_pct, mode
                    printf "TOTAL_MODE_SECONDS:%.4f\n", total_mode
                    printf "TOTAL_ELAPSED_SECONDS:%.4f\n", total_elapsed
                    printf "CPU_COUNT:%d\n", cpu_count
                }'
        }

        # Function to extract per-CPU stats without mode label (e.g., schedstat metrics)
        # Arguments: metric name, tsdb_dump file, rank, ts_start, ts_end
        extract_cpu_stats() {
            local metric="$1"
            local tsdb_file="$2"
            local rank="$3"
            local ts_start="$4"
            local ts_end="$5"

            grep "$metric" "$tsdb_file" | \
                awk -F'[," ]' '{
                    for (j=1; j<=NF; j++) {
                        if ($j == "cpu=") cpu = $(j+1)
                    }
                    print cpu, $(NF-1), $NF
                }' | sort -k1,1n -k3,3n | \
                awk -v rank="$rank" -v metric="$metric" -v ts_start="$ts_start" -v ts_end="$ts_end" '{
                    cpu = $1; val = $2; ts = $3
                    if (!(cpu in prev_ts)) {
                        prev_ts[cpu] = ts
                        prev_val[cpu] = val
                        cpu_count++
                        next
                    }
                    if (prev_ts[cpu] >= ts_start && prev_ts[cpu] <= ts_end && ts >= ts_start && ts <= ts_end) {
                        if (!(cpu in first_val)) {
                            first_val[cpu] = prev_val[cpu]
                            first_ts[cpu] = prev_ts[cpu]
                        }
                        last_val[cpu] = val
                        last_ts[cpu] = ts
                    }
                    prev_ts[cpu] = ts
                    prev_val[cpu] = val
                }
                END {
                    total_metric = 0
                    total_elapsed = 0
                    for (cpu in first_val) {
                        increase = last_val[cpu] - first_val[cpu]
                        elapsed_ms = last_ts[cpu] - first_ts[cpu]
                        elapsed_s = elapsed_ms / 1000
                        pct = (elapsed_s > 0) ? (increase / elapsed_s * 100) : 0
                        printf "Rank %s cpu %s: %.2f %s over %.2fs (%.1f%%)\n", rank, cpu, increase, metric, elapsed_s, pct
                        total_metric += increase
                        total_elapsed += elapsed_s
                    }
                    total_pct = (total_elapsed > 0) ? (total_metric / total_elapsed * 100) : 0
                    printf "Rank %s total: %.2f %s over %.2fs across %d CPUs (%.1f%%)\n", rank, total_metric, metric, total_elapsed, cpu_count, total_pct
                    printf "TOTAL_METRIC_SECONDS:%.4f\n", total_metric
                    printf "TOTAL_ELAPSED_SECONDS:%.4f\n", total_elapsed
                }'
        }

        # Extract idle CPU stats
        cpu_stats_idle=$(extract_cpu_mode_stats "idle" "$tsdb_dump" "$i" "$date_before_ms" "$date_after_ms")
        echo "$cpu_stats_idle" | grep ' total: '
        rank_idle_seconds=$(echo "$cpu_stats_idle" | grep '^TOTAL_MODE_SECONDS:' | cut -d: -f2)
        rank_elapsed_seconds=$(echo "$cpu_stats_idle" | grep '^TOTAL_ELAPSED_SECONDS:' | cut -d: -f2)
        rank_cpu_count=$(echo "$cpu_stats_idle" | grep '^CPU_COUNT:' | cut -d: -f2)
        total_idle_seconds=$(awk "BEGIN {printf \"%.4f\", $total_idle_seconds + $rank_idle_seconds}")
        total_elapsed_seconds=$(awk "BEGIN {printf \"%.4f\", $total_elapsed_seconds + $rank_elapsed_seconds}")

        # Calculate utilized CPUs from idle data
        rank_idle_pct=$(awk "BEGIN {printf \"%.4f\", ($rank_elapsed_seconds > 0) ? ($rank_idle_seconds / $rank_elapsed_seconds * 100) : 0}")
        rank_utilized_pct=$(awk "BEGIN {printf \"%.4f\", 100 - $rank_idle_pct}")
        rank_utilized_cpus=$(awk "BEGIN {printf \"%.4f\", $rank_cpu_count * $rank_utilized_pct / 100}")
        echo "Rank $i utilized CPUs: $rank_utilized_cpus"
        total_utilized_cpus=$(awk "BEGIN {printf \"%.4f\", $total_utilized_cpus + $rank_utilized_cpus}")

        # Extract user CPU stats
        cpu_stats_user=$(extract_cpu_mode_stats "user" "$tsdb_dump" "$i" "$date_before_ms" "$date_after_ms")
        echo "$cpu_stats_user" | grep ' total: '
        rank_user_seconds=$(echo "$cpu_stats_user" | grep '^TOTAL_MODE_SECONDS:' | cut -d: -f2)
        total_user_seconds=$(awk "BEGIN {printf \"%.4f\", $total_user_seconds + $rank_user_seconds}")

        # Extract system CPU stats
        cpu_stats_system=$(extract_cpu_mode_stats "system" "$tsdb_dump" "$i" "$date_before_ms" "$date_after_ms")
        echo "$cpu_stats_system" | grep ' total: '
        rank_system_seconds=$(echo "$cpu_stats_system" | grep '^TOTAL_MODE_SECONDS:' | cut -d: -f2)
        total_system_seconds=$(awk "BEGIN {printf \"%.4f\", $total_system_seconds + $rank_system_seconds}")

        # Extract iowait CPU stats
        cpu_stats_iowait=$(extract_cpu_mode_stats "iowait" "$tsdb_dump" "$i" "$date_before_ms" "$date_after_ms")
        echo "$cpu_stats_iowait" | grep ' total: '
        rank_iowait_seconds=$(echo "$cpu_stats_iowait" | grep '^TOTAL_MODE_SECONDS:' | cut -d: -f2)
        total_iowait_seconds=$(awk "BEGIN {printf \"%.4f\", $total_iowait_seconds + $rank_iowait_seconds}")

        # Extract steal CPU stats
        cpu_stats_steal=$(extract_cpu_mode_stats "steal" "$tsdb_dump" "$i" "$date_before_ms" "$date_after_ms")
        echo "$cpu_stats_steal" | grep ' total: '
        rank_steal_seconds=$(echo "$cpu_stats_steal" | grep '^TOTAL_MODE_SECONDS:' | cut -d: -f2)
        total_steal_seconds=$(awk "BEGIN {printf \"%.4f\", $total_steal_seconds + $rank_steal_seconds}")

        # Extract irq CPU stats
        cpu_stats_irq=$(extract_cpu_mode_stats "irq" "$tsdb_dump" "$i" "$date_before_ms" "$date_after_ms")
        echo "$cpu_stats_irq" | grep ' total: '
        rank_irq_seconds=$(echo "$cpu_stats_irq" | grep '^TOTAL_MODE_SECONDS:' | cut -d: -f2)
        total_irq_seconds=$(awk "BEGIN {printf \"%.4f\", $total_irq_seconds + $rank_irq_seconds}")

        # Extract softirq CPU stats
        cpu_stats_softirq=$(extract_cpu_mode_stats "softirq" "$tsdb_dump" "$i" "$date_before_ms" "$date_after_ms")
        echo "$cpu_stats_softirq" | grep ' total: '
        rank_softirq_seconds=$(echo "$cpu_stats_softirq" | grep '^TOTAL_MODE_SECONDS:' | cut -d: -f2)
        total_softirq_seconds=$(awk "BEGIN {printf \"%.4f\", $total_softirq_seconds + $rank_softirq_seconds}")

        # Extract nice CPU stats
        cpu_stats_nice=$(extract_cpu_mode_stats "nice" "$tsdb_dump" "$i" "$date_before_ms" "$date_after_ms")
        echo "$cpu_stats_nice" | grep ' total: '
        rank_nice_seconds=$(echo "$cpu_stats_nice" | grep '^TOTAL_MODE_SECONDS:' | cut -d: -f2)
        total_nice_seconds=$(awk "BEGIN {printf \"%.4f\", $total_nice_seconds + $rank_nice_seconds}")

        # Extract schedstat running seconds (time spent running on CPU)
        schedstat_running=$(extract_cpu_stats "node_schedstat_running_seconds_total" "$tsdb_dump" "$i" "$date_before_ms" "$date_after_ms")
        echo "$schedstat_running" | grep ' total: '
        rank_schedstat_running=$(echo "$schedstat_running" | grep '^TOTAL_METRIC_SECONDS:' | cut -d: -f2)
        if [[ -n "$rank_schedstat_running" ]]; then
            total_schedstat_running_seconds=$(awk "BEGIN {printf \"%.4f\", $total_schedstat_running_seconds + $rank_schedstat_running}")
        fi

        # Extract schedstat waiting seconds (time spent waiting to be scheduled)
        schedstat_waiting=$(extract_cpu_stats "node_schedstat_waiting_seconds_total" "$tsdb_dump" "$i" "$date_before_ms" "$date_after_ms")
        echo "$schedstat_waiting" | grep ' total: '
        rank_schedstat_waiting=$(echo "$schedstat_waiting" | grep '^TOTAL_METRIC_SECONDS:' | cut -d: -f2)
        if [[ -n "$rank_schedstat_waiting" ]]; then
            total_schedstat_waiting_seconds=$(awk "BEGIN {printf \"%.4f\", $total_schedstat_waiting_seconds + $rank_schedstat_waiting}")
        fi

        # Verify prometheus directory contents
        if [[ ! -d "$prom_dir/incisor_tsdb" ]]; then
            echo "Error: Missing $prom_dir/incisor_tsdb/" >&2
            exit 1
        fi
        if [[ ! -d "$prom_dir/node_exporter" ]]; then
            echo "Error: Missing $prom_dir/node_exporter/" >&2
            exit 1
        fi
        if ! ls -d "$prom_dir/prometheus_collector/prometheus-3.9.1.linux-"* &>/dev/null; then
            echo "Error: Missing $prom_dir/prometheus_collector/prometheus-3.9.1.linux-{amd64,arm64}/" >&2
            exit 1
        fi
    done

    # Infrastructure requirements
    echo ""
    echo "=== Infrastructure Utilization ==="
    echo "Utilized CPU count: $total_utilized_cpus of $total_cpu_count"
    required_memory=$((total_max_mem_avail - total_min_mem_avail))
    required_memory_gb=$(awk "BEGIN {printf \"%.2f\", $required_memory / (1024*1024*1024)}")
    total_mem_total_gb=$(awk "BEGIN {printf \"%.2f\", $total_mem_total / (1024*1024*1024)}")
    echo "Utilized memory: $required_memory bytes (${required_memory_gb} GB) of $total_mem_total bytes (${total_mem_total_gb} GB)"
    echo "CPU pressure waiting: ${total_cpu_pressure_waiting_seconds}s"
    echo "Memory pressure stalled: ${total_mem_pressure_stalled_seconds}s"
    echo "Memory pressure waiting: ${total_mem_pressure_waiting_seconds}s"
    echo "I/O pressure stalled: ${total_io_pressure_stalled_seconds}s"
    echo "I/O pressure waiting: ${total_io_pressure_waiting_seconds}s"

    # CPU mode breakdown
    echo ""
    echo "=== CPU Time Breakdown ==="
    idle_pct=$(awk "BEGIN {printf \"%.2f\", ($total_elapsed_seconds > 0) ? ($total_idle_seconds / $total_elapsed_seconds * 100) : 0}")
    user_pct=$(awk "BEGIN {printf \"%.2f\", ($total_elapsed_seconds > 0) ? ($total_user_seconds / $total_elapsed_seconds * 100) : 0}")
    system_pct=$(awk "BEGIN {printf \"%.2f\", ($total_elapsed_seconds > 0) ? ($total_system_seconds / $total_elapsed_seconds * 100) : 0}")
    iowait_pct=$(awk "BEGIN {printf \"%.2f\", ($total_elapsed_seconds > 0) ? ($total_iowait_seconds / $total_elapsed_seconds * 100) : 0}")
    steal_pct=$(awk "BEGIN {printf \"%.2f\", ($total_elapsed_seconds > 0) ? ($total_steal_seconds / $total_elapsed_seconds * 100) : 0}")
    irq_pct=$(awk "BEGIN {printf \"%.2f\", ($total_elapsed_seconds > 0) ? ($total_irq_seconds / $total_elapsed_seconds * 100) : 0}")
    softirq_pct=$(awk "BEGIN {printf \"%.2f\", ($total_elapsed_seconds > 0) ? ($total_softirq_seconds / $total_elapsed_seconds * 100) : 0}")
    nice_pct=$(awk "BEGIN {printf \"%.2f\", ($total_elapsed_seconds > 0) ? ($total_nice_seconds / $total_elapsed_seconds * 100) : 0}")
    echo "Total elapsed CPU-seconds: $total_elapsed_seconds"
    echo "Idle: ${total_idle_seconds}s (${idle_pct}%)"
    echo "User: ${total_user_seconds}s (${user_pct}%)"
    echo "System: ${total_system_seconds}s (${system_pct}%)"
    echo "I/O Wait: ${total_iowait_seconds}s (${iowait_pct}%)"
    echo "Steal: ${total_steal_seconds}s (${steal_pct}%)"
    echo "IRQ: ${total_irq_seconds}s (${irq_pct}%)"
    echo "Soft IRQ: ${total_softirq_seconds}s (${softirq_pct}%)"
    echo "Nice: ${total_nice_seconds}s (${nice_pct}%)"

    echo ""
    echo "=== Scheduler Stats ==="
    echo "Schedstat Running: ${total_schedstat_running_seconds}s (time spent running on CPU)"
    echo "Schedstat Waiting: ${total_schedstat_waiting_seconds}s (time spent waiting to be scheduled)"

    if [[ -n "$all_gpu_utilization" ]]; then
        echo ""
        echo "=== Accelerator Utilization ==="
        # Aggregate averages across ranks per uuid and metric
        echo -n "$all_gpu_utilization" | awk '{
            # Format: Rank R metric uuid U: avg (avg over N samples)
            rank = $2; metric = $3; uuid = $5;
            gsub(/:$/, "", uuid)
            avg = $6; samples = $9
            key = metric SUBSEP uuid
            weighted_sum[key] += avg * samples
            total_samples[key] += samples
            metrics[metric] = 1
            uuids[key] = uuid
            mets[key] = metric
        }
        END {
            for (key in weighted_sum) {
                overall_avg = weighted_sum[key] / total_samples[key]
                printf "%s uuid %s: %.4f (avg over %d samples)\n", mets[key], uuids[key], overall_avg, total_samples[key]
            }
        }' | sort
    fi

    echo ""
    echo "=== Static Needs ==="
    echo "Architecture: $static_architecture"
    if [[ $total_xmm_count -gt 0 ]]; then
        echo "Has SSE: yes ($total_xmm_count xmm instructions)"
    elif [[ "$has_python_math" == true ]]; then
        echo "Has SSE: yes (python math packages)"
    else
        echo "Has SSE: no"
    fi
    if [[ $total_zmm_count -gt 0 ]]; then
        echo "Has AVX-512: yes ($total_zmm_count zmm instructions)"
    elif [[ "$has_python_math" == true ]]; then
        echo "Has AVX-512: yes (python math packages)"
    else
        echo "Has AVX-512: no"
    fi
    if [[ $total_neon_count -gt 0 ]]; then
        echo "Has NEON: yes ($total_neon_count NEON instructions)"
    elif [[ "$has_python_math" == true ]]; then
        echo "Has NEON: yes (python math packages)"
    else
        echo "Has NEON: no"
    fi
    if [[ $total_sve_count -gt 0 ]]; then
        echo "Has SVE: yes ($total_sve_count SVE instructions)"
    elif [[ "$has_python_math" == true ]]; then
        echo "Has SVE: yes (python math packages)"
    else
        echo "Has SVE: no"
    fi
    if [[ $total_xmm_count -gt 0 || $total_zmm_count -gt 0 || $total_neon_count -gt 0 || $total_sve_count -gt 0 || "$has_python_math" == true ]]; then
        echo "Has Vector Math: yes"
    else
        echo "Has Vector Math: no"
    fi
    if [[ "$requires_gpu" == true ]]; then
        echo "Has GPU: yes"
    else
        echo "Has GPU: no"
    fi
    if [[ "$requires_mpi" == true ]]; then
        echo "Has MPI: yes"
    else
        echo "Has MPI: no"
    fi
    requires_openmp=false
    if [[ "$has_openmp_indicators" == true && "$has_omp_num_threads_gt1" == true ]]; then
        requires_openmp=true
        echo "Has OpenMP: yes"
    else
        echo "Has OpenMP: no"
    fi
    if [[ "$has_python_parallel" == true || "$requires_openmp" == true ]]; then
        echo "Has TLP: yes"
    else
        echo "Has TLP: no"
    fi
)
