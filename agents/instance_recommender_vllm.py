#!/usr/bin/env python3
"""
instance_recommender_vllm.py

Recommend EC2 instances for a given binary analysis result using a locally-served
vLLM model via the OpenAI-compatible API.

Usage:
    instance_recommender_vllm.py <analysis.json> [options]

Environment:
    VLLM_BASE_URL   — vLLM server base URL (default: http://localhost:8000/v1)
    VLLM_MODEL      — model name (default: Qwen/Qwen3.5-35B-A3B)
    VLLM_API_KEY    — API key (default: dummy)
"""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
import tempfile
from typing import Any, Dict, List, Optional

from jsonschema import Draft202012Validator
from pydantic import BaseModel, Field

from langchain_openai import ChatOpenAI
from langchain_core.messages import AIMessage, HumanMessage, ToolMessage
from langchain_core.tools import BaseTool, tool

import subprocess

from tools.query_instances import query_instances

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

_SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
_PROMPT_FILE = os.path.join(_SCRIPT_DIR, "recommender_prompt.txt")
_SCHEMA_FILE = os.path.join(_SCRIPT_DIR, "recommender_schema.json")
_CATALOG_CSV = os.path.join(_SCRIPT_DIR, "..", "static_aws_useast1.csv")
_LLM_CONFIG = os.path.join(_SCRIPT_DIR, "llm_config.json")

_VLLM_MODELS = {
    "qwen": "Qwen/Qwen3.5-35B-A3B",
    "llama": "meta-llama/Llama-3.3-70B-Instruct",
    "ministral": "mistralai/Ministral-3-14B-Instruct-2512",
    "nemo": "nvidia/Llama-3_3-Nemotron-Super-49B-v1_5",
}


def _default_vllm_model() -> str:
    """Read model key from llm_config.json and return the vLLM model name."""
    try:
        with open(_LLM_CONFIG, "r") as f:
            cfg = json.load(f)
        return _VLLM_MODELS.get(cfg.get("model", ""), "Qwen/Qwen3.5-35B-A3B")
    except (FileNotFoundError, json.JSONDecodeError):
        return "Qwen/Qwen3.5-35B-A3B"


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def try_parse_json(text: str) -> Optional[Any]:
    try:
        return json.loads(text)
    except Exception:
        return None


def _compact(text: str) -> str:
    """Strip think blocks / markdown fences; return compact single-line JSON if parseable."""
    # Remove <think>...</think> blocks
    text = re.sub(r"<think>.*?</think>", "", text, flags=re.DOTALL).strip()
    candidates = [
        text.strip(),
        re.sub(r"^```[a-z]*\n?", "", text.strip()).rstrip("` \n"),
    ]
    brace = text.find("{")
    if brace != -1:
        candidates.append(text[brace:].strip())
    for c in candidates:
        p = try_parse_json(c)
        if p is not None:
            return json.dumps(p, ensure_ascii=False)
    return text


# ---------------------------------------------------------------------------
# Tool schemas
# ---------------------------------------------------------------------------

class ReadArgs(BaseModel):
    path: str = Field(..., description="File path to read (must be within the staging directory).")
    max_chars: int = Field(120_000, ge=1_000, le=2_000_000, description="Max characters to return.")


class FilterInstancesArgs(BaseModel):
    min_memory_gib: Optional[float] = Field(None, description="Minimum instance memory in GiB.")
    max_memory_gib: Optional[float] = Field(None, description="Maximum instance memory in GiB.")
    min_vcpus: Optional[int] = Field(None, description="Minimum vCPU count.")
    max_vcpus: Optional[int] = Field(None, description="Maximum vCPU count.")
    arch: Optional[str] = Field(None, description="CPU architecture (e.g. x86_64, arm64).")
    needs_gpu: Optional[bool] = Field(None, description="True=GPU required, False=no GPU, None=no filter.")
    min_gpu_memory_gib: Optional[float] = Field(None, description="Minimum per-GPU memory in GiB.")


@tool("FilterInstances", args_schema=FilterInstancesArgs)
def filter_instances_tool(
    min_memory_gib: Optional[float] = None,
    max_memory_gib: Optional[float] = None,
    min_vcpus: Optional[int] = None,
    max_vcpus: Optional[int] = None,
    arch: Optional[str] = None,
    needs_gpu: Optional[bool] = None,
    min_gpu_memory_gib: Optional[float] = None,
) -> str:
    """Filter the AWS instance catalog and return matching instances as a CSV string."""
    return query_instances(
        src_csv=_CATALOG_CSV,
        min_memory_gib=min_memory_gib,
        max_memory_gib=max_memory_gib,
        min_vcpus=min_vcpus,
        max_vcpus=max_vcpus,
        arch=arch,
        needs_gpu=needs_gpu,
        min_gpu_memory_gib=min_gpu_memory_gib,
    )


# ---------------------------------------------------------------------------
# Build tools (Read + StructuredOutput) bound to a specific tmpdir
# ---------------------------------------------------------------------------

def build_tools(tmpdir: str, captured: List[Optional[Any]]):
    """
    Returns (read_tool, structured_output_tool, tools_map).
    captured is a one-element list used as a mutable closure variable.
    """

    @tool("Read", args_schema=ReadArgs)
    def read_tool(path: str, max_chars: int = 120_000) -> str:
        """Read a text file from the staging directory."""
        # Resolve and restrict to tmpdir
        if not os.path.isabs(path):
            path = os.path.abspath(os.path.join(os.getcwd(), path))
        path = os.path.abspath(path)
        tmpdir_abs = os.path.abspath(tmpdir)
        if path != tmpdir_abs and not path.startswith(tmpdir_abs + os.sep):
            raise ValueError(f"Access denied: path is outside the staging directory ({tmpdir_abs}).")
        if not os.path.isfile(path):
            raise FileNotFoundError(f"Not a file: {path}")
        with open(path, "r", encoding="utf-8", errors="replace") as f:
            return f.read(max_chars)

    # StructuredOutput: accepts any kwargs, stores them, returns sentinel string.
    # Intercepted in the ReAct loop before execution; _run is never called.
    class StructuredOutputTool(BaseTool):
        name: str = "StructuredOutput"
        description: str = (
            "Emit your final structured recommendations. "
            "Pass all recommendation fields as keyword arguments."
        )
        args_schema: type = type(
            "StructuredOutputArgs",
            (BaseModel,),
            {
                "__annotations__": {"recommendations": List[Dict[str, Any]]},
                "recommendations": Field(..., description="List of 10 recommendation objects."),
            },
        )

        def _run(self, **kwargs: Any) -> str:  # type: ignore[override]
            captured[0] = kwargs
            return "Answer recorded."

    structured_output_tool = StructuredOutputTool()

    tools_map = {
        "Read": read_tool,
        "FilterInstances": filter_instances_tool,
        "StructuredOutput": structured_output_tool,
    }
    return read_tool, structured_output_tool, tools_map


# ---------------------------------------------------------------------------
# Execute a single tool call (non-StructuredOutput)
# ---------------------------------------------------------------------------

def _execute_tool(tc: Dict[str, Any], tools_map: Dict[str, Any]) -> str:
    name = tc["name"]
    t = tools_map.get(name)
    if t is None:
        return f"TOOL_ERROR: unknown tool '{name}'"
    try:
        args = tc.get("args") or {}
        result = t.invoke(args)
        return str(result)
    except Exception as e:
        return f"TOOL_ERROR: {type(e).__name__}: {e}"


# ---------------------------------------------------------------------------
# Schema nudge loop
# Uses a minimal context (no tool-call history) to avoid context overflow.
# ---------------------------------------------------------------------------

def _nudge_to_schema(
    final_text: str,
    validator: Draft202012Validator,
    llm_base: ChatOpenAI,
    verbose: bool,
    original_prompt: str = "",
) -> str:
    # Seed with the original prompt (selection rules) + last AI response.
    # Omitting the prompt here would leave the model without selection criteria.
    nudge_msgs: List[Any] = []
    if original_prompt:
        nudge_msgs.append(HumanMessage(content=original_prompt))
    nudge_msgs.append(AIMessage(content=final_text))
    for attempt in range(3):
        parsed_out = try_parse_json(final_text)
        errors = list(validator.iter_errors(parsed_out)) if parsed_out is not None else []
        if parsed_out is not None and not errors:
            break
        if verbose:
            sys.stderr.write(f"[schema_nudge] attempt={attempt + 1}\n")
        if parsed_out is None:
            error_detail = "Your response was not valid JSON."
        else:
            error_detail = "Validation errors:\n" + "\n".join(
                f"- {e.json_path}: {e.message}" for e in errors[:8]
            )
        nudge_prompt = HumanMessage(content=(
            f"Your previous response did NOT validate against the JSON Schema.\n"
            f"{error_detail}\n\n"
            f"Required schema:\n{json.dumps(validator.schema, indent=2)}\n\n"
            "Return ONLY valid JSON matching the schema, with required fields and correct types. "
            "Do not include markdown or commentary."
        ))
        final_text = (llm_base.invoke(nudge_msgs + [nudge_prompt]).content or "").strip()
        nudge_msgs = nudge_msgs + [nudge_prompt, AIMessage(content=final_text)]
    return final_text


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main() -> int:
    ap = argparse.ArgumentParser(description="Recommend EC2 instances for a binary analysis result.")
    ap.add_argument("analysis_json", help="Path to the JSONL analysis output (last non-empty line used).")
    ap.add_argument("--base-url", default=os.environ.get("VLLM_BASE_URL", "http://localhost:8000/v1"))
    ap.add_argument("--model", default=os.environ.get("VLLM_MODEL", _default_vllm_model()))
    ap.add_argument("--api-key", default=os.environ.get("VLLM_API_KEY", "dummy"))
    ap.add_argument("--tool-budget", type=int, default=20, dest="tool_budget")
    ap.add_argument("--verbose", action="store_true")
    ap.add_argument("--output-format", choices=["text", "json", "stream-json"], default="text",
                    dest="output_format")
    args = ap.parse_args()

    # ------------------------------------------------------------------
    # 1. Read last non-empty line of analysis.json → constraint_analysis dict
    # ------------------------------------------------------------------
    with open(args.analysis_json, "r", encoding="utf-8") as f:
        lines = [ln.strip() for ln in f if ln.strip()]
    if not lines:
        sys.stderr.write("ERROR: analysis.json is empty\n")
        return 1
    constraint_analysis = json.loads(lines[-1])

    # ------------------------------------------------------------------
    # 2. Create staging tmpdir
    # ------------------------------------------------------------------
    tmpdir = tempfile.mkdtemp(prefix="instance_rec_")
    if args.verbose:
        sys.stderr.write(f"[staging] tmpdir={tmpdir}\n")

    # ------------------------------------------------------------------
    # 3. Write constraint_analysis.json to tmpdir
    # ------------------------------------------------------------------
    analysis_dst = os.path.join(tmpdir, "constraint_analysis.json")
    with open(analysis_dst, "w", encoding="utf-8") as f:
        json.dump(constraint_analysis, f, ensure_ascii=False)

    # ------------------------------------------------------------------
    # 4. Build prior run status section
    # ------------------------------------------------------------------
    prior_run_status = ""
    try:
        with open(_LLM_CONFIG, "r") as f:
            cfg = json.load(f)
        use_run = int(cfg.get("use_run", 0))
        llm_model_key = cfg.get("model", "")
    except (FileNotFoundError, json.JSONDecodeError, ValueError):
        use_run = 0
        llm_model_key = ""

    if use_run > 0:
        bench_dir = os.path.dirname(os.path.abspath(args.analysis_json))
        prior_instances_json = os.path.join(
            bench_dir, "..", f"agentic-L4bin-{llm_model_key}", "instances.json"
        )
        if os.path.isfile(prior_instances_json):
            list_inst_script = os.path.join(_SCRIPT_DIR, "..", "list_instances.py")
            try:
                result = subprocess.run(
                    [sys.executable, list_inst_script, prior_instances_json],
                    capture_output=True, text=True, timeout=10,
                )
                instances = [ln.strip() for ln in result.stdout.splitlines() if ln.strip()]
            except Exception:
                instances = []

            # Load instance catalog for memory lookup
            import csv as _csv
            _inst_mem = {}
            if os.path.isfile(_CATALOG_CSV):
                with open(_CATALOG_CSV, newline="") as cf:
                    for row in _csv.DictReader(cf):
                        _inst_mem[row.get("API Name", "")] = row.get("Instance Memory", "?")

            rows = []  # (instance, memory, result, rationale)
            for inst in instances[:use_run]:
                status_file = os.path.join(bench_dir, "..", inst, "status.json")
                if os.path.isfile(status_file):
                    try:
                        with open(status_file) as sf:
                            st = json.load(sf)
                        result_str = st.get("result", "unknown")
                        rationale = st.get("rationale", "")
                    except (json.JSONDecodeError, IOError):
                        result_str, rationale = "unknown", "no status available"
                else:
                    result_str, rationale = "(no data)", "(no data)"
                rows.append((inst, _inst_mem.get(inst, "?"), result_str, rationale))

            if rows:
                w_inst = max(len("Instance"), max(len(r[0]) for r in rows))
                w_mem = max(len("Memory"), max(len(r[1]) for r in rows))
                w_res = max(len("Result"), max(len(r[2]) for r in rows))
                hdr = f"  {'Instance':<{w_inst}}  {'Memory':<{w_mem}}  {'Result':<{w_res}}  Rationale"
                sep = "  " + "-" * w_inst + "  " + "-" * w_mem + "  " + "-" * w_res + "  " + "-" * 9
                table_lines = [hdr, sep]
                for inst, mem, res, rat in rows:
                    table_lines.append(f"  {inst:<{w_inst}}  {mem:<{w_mem}}  {res:<{w_res}}  {rat}")
                prior_run_status = (
                    "PRIOR RUN STATUS — the following instances were previously recommended and run for this\n"
                    "workload. Use these results to inform your recommendations. Generalize from failure modes:\n"
                    "  - out_of_memory on an N GiB instance → exclude all instances with ≤ N GiB memory\n"
                    "  - platform_mismatch (illegal instruction) → exclude instances with the same or older\n"
                    "    processor generation (the binary requires a newer ISA extension)\n"
                    "  - instance_unavailable → skip that specific instance, but similar sizes are fine\n\n"
                    + "\n".join(table_lines)
                )

    # ------------------------------------------------------------------
    # 5. Render prompt
    # ------------------------------------------------------------------
    with open(_PROMPT_FILE, "r", encoding="utf-8") as f:
        prompt_template = f.read()
    rendered_prompt = (
        prompt_template
        .replace("@@ANALYSIS_FILE@@", analysis_dst)
        .replace("@@CSV_FILE@@", "[use the FilterInstances tool]")
        .replace("@@PRIOR_RUN_STATUS@@", prior_run_status)
    )
    rendered_prompt += (
        "\n\nNote: To access the instance catalog, call FilterInstances with your filter "
        "parameters (e.g. min_memory_gib, max_memory_gib, min_vcpus, arch, needs_gpu). "
        "The tool returns a filtered CSV directly. Call it before making recommendations.\n\n"
        "FILTERING STRATEGY: Always supply both a lower AND upper bound to keep result sets "
        "manageable. For memory, start with max_memory_gib = 2× min_memory_gib "
        "(e.g. min_memory_gib=80, max_memory_gib=160 when you need at least 80 GiB). "
        "If FilterInstances returns 0 rows, double the upper bound and retry "
        "(e.g. max_memory_gib=320, then 640, etc.). Apply the same back-off for vCPUs: "
        "start with max_vcpus = 2× min_vcpus and double if needed."
    )

    # Save rendered prompt next to analysis.json
    prompt_save_path = os.path.join(
        os.path.dirname(os.path.abspath(args.analysis_json)),
        "recommender_prompt.txt",
    )
    with open(prompt_save_path, "w", encoding="utf-8") as f:
        f.write(rendered_prompt + "\n")

    # ------------------------------------------------------------------
    # 6. Load schema
    # ------------------------------------------------------------------
    with open(_SCHEMA_FILE, "r", encoding="utf-8") as f:
        schema = json.load(f)
    validator = Draft202012Validator(schema)

    # ------------------------------------------------------------------
    # 7. LLM setup
    # ------------------------------------------------------------------
    llm_base = ChatOpenAI(
        model=args.model,
        base_url=args.base_url,
        api_key=args.api_key,
        temperature=0.2,
    )
    captured: List[Optional[Any]] = [None]
    read_tool, structured_output_tool, tools_map = build_tools(tmpdir, captured)
    llm_with_tools = llm_base.bind_tools([read_tool, filter_instances_tool, structured_output_tool])

    # ------------------------------------------------------------------
    # 8. ReAct loop
    # ------------------------------------------------------------------
    messages: List[Any] = [HumanMessage(content=rendered_prompt)]
    tool_call_count = 0
    final_text = ""
    last_response = None

    while True:
        response = llm_with_tools.invoke(messages)
        messages.append(response)
        last_response = response

        tool_calls = getattr(response, "tool_calls", None) or []

        if not tool_calls:
            # Model wrote text instead of calling a tool
            final_text = (response.content or "").strip()
            break

        tool_results = []
        done = False
        for tc in tool_calls:
            if tc["name"] == "StructuredOutput":
                captured[0] = tc.get("args") or {}
                done = True
                break
            tool_call_count += 1
            if tool_call_count > args.tool_budget:
                done = True
                break
            result_str = _execute_tool(tc, tools_map)
            if tc["name"] == "FilterInstances":
                tc_args = tc.get("args") or {}
                row_count = max(0, result_str.count("\n") - 1)  # subtract header
                if args.verbose:
                    filters = ", ".join(f"{k}={v}" for k, v in tc_args.items() if v is not None)
                    sys.stderr.write(f"[tool] FilterInstances({filters}) → {row_count} rows\n")
                if row_count == 0:
                    result_str += (
                        "\n\n[No instances matched these filters. Double the upper bound "
                        "(e.g. max_memory_gib or max_vcpus) and call FilterInstances again.]"
                    )
            elif args.verbose:
                sys.stderr.write(f"[tool] {tc['name']}({list(tc.get('args', {}).keys())}) → {result_str[:80]!r}...\n")
            tool_results.append(ToolMessage(content=result_str, tool_call_id=tc["id"]))

        if done:
            break
        messages.extend(tool_results)

    # ------------------------------------------------------------------
    # 9. Answer extraction
    # ------------------------------------------------------------------
    if captured[0] is not None:
        final_text = json.dumps(captured[0], ensure_ascii=False)
    elif not final_text and last_response is not None:
        final_text = (last_response.content or "").strip()

    # ------------------------------------------------------------------
    # 10. Schema nudge loop
    # ------------------------------------------------------------------
    final_text = _nudge_to_schema(final_text, validator, llm_base, args.verbose,
                                   original_prompt=rendered_prompt)

    # ------------------------------------------------------------------
    # 11. Compact output
    # ------------------------------------------------------------------
    final_text = _compact(final_text)

    # ------------------------------------------------------------------
    # 12. Emit output
    # ------------------------------------------------------------------
    sys.stderr.write(f"tool_calls={tool_call_count}\n")

    if args.output_format == "json":
        sys.stdout.write(json.dumps({"output": final_text}, ensure_ascii=False) + "\n")
    elif args.output_format == "stream-json":
        import time, uuid
        run_id = f"msg_{uuid.uuid4().hex[:20]}"
        sys.stdout.write(json.dumps({"id": run_id, "type": "message", "role": "assistant",
                                     "model": args.model,
                                     "content": [{"type": "text", "text": final_text}],
                                     "stop_reason": "end_turn"}, ensure_ascii=False) + "\n")
        sys.stdout.write(json.dumps({"id": run_id, "type": "end",
                                     "ts": int(time.time())}, ensure_ascii=False) + "\n")

    sys.stdout.write(final_text + ("" if final_text.endswith("\n") else "\n"))
    sys.stdout.flush()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
