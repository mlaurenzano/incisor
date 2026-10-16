#!/usr/bin/env bash
set -euo pipefail

### Read model from agents/llm_config.json
script_dir="$(cd "$(dirname "$0")" && pwd)"
llm_config="${script_dir}/agents/llm_config.json"
[[ -f "${llm_config}" ]] || { printf 'LLM config not found: %s\n' "${llm_config}" >&2; exit 1; }

declare -A vllm_models=(
    [qwen]="Qwen/Qwen3.5-35B-A3B"
    [llama]="meta-llama/Llama-3.3-70B-Instruct"
    [ministral]="mistralai/Ministral-3-14B-Instruct-2512"
    [nemo]="nvidia/Llama-3_3-Nemotron-Super-49B-v1_5"
)

declare -A vllm_parsers=(
    [qwen]="qwen3_coder"
    [llama]="llama3_json"
    [ministral]="mistral"
    [nemo]="llama3_json"
)

model_key=$(jq -r '.model' "${llm_config}")
model="${vllm_models[${model_key}]:-}"
parser="${vllm_parsers[${model_key}]:-llama3_json}"
parser_plugin=""

if [ -z "${model}" ]; then
    printf 'error: model key "%s" from llm_config.json is not a local model (expected qwen/llama/ministral/nemo)\n' "${model_key}" >&2
    exit 1
fi

# Optional env overrides to avoid file edits during A/B tests.
model="${VLLM_MODEL_OVERRIDE:-$model}"
parser="${VLLM_TOOL_PARSER_OVERRIDE:-$parser}"
parser_plugin="${VLLM_TOOL_PARSER_PLUGIN_OVERRIDE:-$parser_plugin}"
served_model_name="${VLLM_SERVED_MODEL_NAME_OVERRIDE:-$model}"

if [ "${1:-}" == "--test" ]; then
    temp=0.2
    top_p=0.5
    curl http://localhost:8000/v1/chat/completions -H "Content-Type: application/json" -d "{
    \"model\": \"${model}\",
    \"messages\": [{\"role\":\"user\",\"content\":\"Write a 2-sentence summary of vLLM.\"}],
    \"temperature\": ${temp},
    \"top_p\": ${top_p}
    }" | jq
elif [ "${1:-}" == "--run" ]; then
    # Hugging Face token: read from the environment, or from an untracked .env
    # file next to this script (see .env.example).
    if [ -z "${HF_TOKEN:-}" ] && [ -f "${script_dir}/.env" ]; then
        set -a; . "${script_dir}/.env"; set +a
    fi
    if [ -z "${HF_TOKEN:-}" ]; then
        echo "HF_TOKEN is not set. Export it or put it in ${script_dir}/.env" >&2
        exit 1
    fi

    echo "Launching vLLM"
    echo "  model=${model}"
    echo "  parser=${parser}"
    echo "  served_model_name=${served_model_name}"
    if [ -n "${parser_plugin}" ]; then
        echo "  parser_plugin=${parser_plugin}"
    fi

    vllm_args=(
        "${model}"
        --enable-auto-tool-choice
        --tool-call-parser "${parser}"
        --served-model-name "${served_model_name}"
        --trust-remote-code
        --tensor-parallel-size 4
        --dtype bfloat16
        --kv-cache-dtype fp8
        --max-model-len 65536
    )
#        --quantization awq

    if [ -n "${parser_plugin}" ]; then
        vllm_args+=(--tool-parser-plugin "${parser_plugin}")
    fi

    sudo docker run --runtime nvidia --gpus all \
        -v ~/.cache/huggingface:/root/.cache/huggingface \
        -e HF_TOKEN="$HF_TOKEN" \
        -e HUGGINGFACE_HUB_TOKEN="$HF_TOKEN" \
        -p 8000:8000 \
        --ipc=host \
        vllm/vllm-openai:nightly \
        "${vllm_args[@]}"
else
    echo "usage: ${0} [--run|--test]"
    exit 1
fi
