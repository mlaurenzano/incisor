# Incisor

Incisor analyzes a resource intensive batch program, asks an LLM to infer its
resource constraints (memory, cores, I/O, parallelism), recommends AWS
instance types, and then launch the program on those instances.
If you use this code or data in your research, please cite our paper:

```bibtex
@inproceedings{laurenzano2026incisor,
  author    = {Laurenzano, Michael A. and Cheng, Shihan and Hyde, David A. B.},
  title     = {Incisor: Ex Ante Instance Selection in the Cloud},
  booktitle = {Proceedings of the ACM Symposium on Cloud Computing (SoCC)},
  year      = {2026},
  doi       = {10.1145/3828161.3857875}
}
```


The repository contains the pipeline scripts, the LLM agent and its prompts,
and one example benchmark (`hec_omp_n16_bezier`, an OpenMP Bezier-surface
kernel from the Chai suite).

## Setup

Linux x86_64 or aarch64. You need a C/C++ toolchain, `cmake`, `ninja`, `git`,
`curl`, `unzip`, `jq`, and GNU `parallel`. On Debian/Ubuntu:

```
sudo apt install build-essential cmake ninja-build git curl unzip xz-utils \
                 pkg-config patch jq parallel
```

**1. Python environment.** Use a virtual environment; the pinned versions in
`requirements.txt` (angr, langgraph, skypilot, ...) do not mix well with
system packages.

```
python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
```

**2. Third-party analysis tools.** `install.sh` downloads Prometheus, a JDK,
and Ghidra, and builds Bloaty and radare2 from source into `agents/tools/`.
It takes 10 to 20 minutes the first time, mostly spent on compiling.

```
./install.sh            # everything
./install.sh --only ghidra,jdk   # a subset; --force reinstalls, --help lists options
```

**3. LLM backend.** Pick one in `agents/llm_config.json`:

- `claudeopus` or `claudesonnet` uses the `claude` CLI, which must be
  installed and logged in.
- `qwen`, `llama`, `ministral`, or `nemo` uses a local vLLM server. Copy
  `.env.example` to `.env`, put your Hugging Face token in it, and start the
  server with `./launch_vllm.sh --run` (needs Docker and an NVIDIA GPU).
  `./launch_vllm.sh --test` checks that it answers.

**4. Cloud runs (optional).** Only needed to execute benchmarks on AWS
(the `rank1`, `sky`, and `expsky` modes below). SkyPilot is installed with
the requirements and starts its local API server on first use.
You need AWS credentials on the local machine, set up the usual
way (`aws configure`, or `AWS_ACCESS_KEY_ID`/`AWS_SECRET_ACCESS_KEY` in the
environment). Verify that SkyPilot can see them with:

```
sky check aws
```

## Running

Each benchmark lives in its own directory:

```
<bench>/program/config.json   runner, args, parallel type/count, setup command
<bench>/program/source/       source tree (used when link_type is "source")
<bench>/program/runnable/     prebuilt binary and inputs
<bench>/expert/               expert-chosen constraints for comparison runs
```

`sweep.sh` runs every benchmark listed at the top of the script through
`incisor_run`:

```
./sweep.sh           # analyze and recommend instances; no cloud access needed
./sweep.sh rank1     # then launch on the top recommendation
./sweep.sh sky       # launch on the instance in expert/skypilot_only.txt
./sweep.sh expsky    # launch on the instance in expert/skypilot_expert.txt
```

Output is written to `<bench>/<analysis_dir>/`, where `analysis_dir` comes from
`agents/llm_config.json`:

- `analysis.json`: the streamed LLM transcript and final structured answer
- `instances.json`: ranked instance recommendations
- `main_*/`: raw tool outputs and `tool-timing.log`. A tool that finishes in
  a few milliseconds almost certainly failed, usually because `install.sh` or
  `pip install` has not been run.

Delete `<bench>/<analysis_dir>/` to force a re-analysis; `sweep.sh` skips
benchmarks that already have one.

After a cloud run, `extract_data.sh <run_dir>` summarizes the Prometheus
metrics into `incisor_report.log` and `history_summary.log`.

## Adding a benchmark

Create `<name>/program/config.json` with the fields shown in
`hec_omp_n16_bezier/program/config.json`, add the source or binary, add
`<name>` to the list in `sweep.sh`, and optionally fill `<name>/expert/`.

## License

incisor is released under the University of Illinois/NCSA Open Source
License (`LICENSE`). Third-party components, including everything
`install.sh` fetches, keep their own licenses; see `THIRD_PARTY_NOTICES.md`.
