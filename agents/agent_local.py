#!/usr/bin/env python3
"""
agent_local.py

Hierarchical task decomposition agent for binary analysis.

Graph topology:
  START → decomposer → task_executor → [route]
                            ↑               |
                            └──"next_task"──┘
                                            |
                                      "synthesize"
                                            ↓
                                       synthesizer → END

Key differences from agent-claudelike.py:
- decomposer_node decomposes the problem into a list of subtasks (1 LLM call, 0 tools)
- task_executor_node runs each subtask in its OWN context window (embedded ReAct while-loop)
- Each subtask produces a prose summary (not JSON)
- synthesizer_node converts all prose summaries into final JSON (same nudge loop)

Environment:
  export VLLM_BASE_URL="http://localhost:8000/v1"
  export VLLM_API_KEY="dummy"
  export VLLM_MODEL="your-model-name"

Usage:
  agent_local.py \\
    --tools ReadSlice --tools Head --tools Grep \\
    [--think] \\
    --allow-file <files> \\
    --tool-budget 60 \\
    --output-format stream-json --verbose \\
    --json-schema "$(cat analysis_schema.json)" \\
    -p "$(cat outdir/prompt.txt)" < /dev/null
"""

from __future__ import annotations

import argparse
import json
import operator
import os
import re
import sys
import time
import uuid
from dataclasses import dataclass, field
from typing import Annotated, Any, Dict, List, Optional, Tuple

from jsonschema import Draft202012Validator
from pydantic import BaseModel, Field

from openai import BadRequestError as OpenAIBadRequestError

from langchain_openai import ChatOpenAI
from langchain_core.messages import AnyMessage, AIMessage, HumanMessage, SystemMessage, ToolMessage
from langchain_core.tools import BaseTool, tool
from langgraph.graph import StateGraph, END
from langgraph.prebuilt import ToolNode
from typing_extensions import TypedDict

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

DEFAULT_SLICE_LINES = 100
DEFAULT_TURNS_LIMIT = 100
DEFAULT_TOOL_BUDGET = 100

# Hierarchical-specific constants
SUBTASK_DEFAULT_BUDGET   = 15     # default tool calls per subtask
SUBTASK_MEMORY_FRACTION  = 0.50   # memory task gets 50% of --tool-budget
MAX_SUBTASK_BUDGET       = 30     # hard cap per subtask
MAX_CONSECUTIVE_THINK_TURNS = 3   # safety net against Think-only spin


# ---------------------------------------------------------------------------
# Exceptions
# ---------------------------------------------------------------------------

class DuplicateCallError(Exception):
    """Raised when the agent repeats an identical tool call."""


# ---------------------------------------------------------------------------
# Binary refusal helpers
# ---------------------------------------------------------------------------

def _binary_refusal_message(full_path: str) -> Optional[str]:
    bin_exts = {".x", ".o", ".a", ".so", ".bin", ".exe"}
    _, ext = os.path.splitext(full_path.lower())
    if ext in bin_exts:
        return "BINARY_SKIPPED: executable/object file. Use MANIFEST + text tool outputs (objdump/strings/etc)."
    with open(full_path, "rb") as bf:
        chunk = bf.read(4096)
    if b"\x00" in chunk:
        return "BINARY_SKIPPED: detected binary content. Use MANIFEST + text tool outputs."
    return None


# ---------------------------------------------------------------------------
# AllowlistedFS
# ---------------------------------------------------------------------------

@dataclass
class AllowlistedFS:
    roots: List[str]
    allowed_files: Optional[set] = field(default=None)

    def __post_init__(self):
        norm = []
        for r in self.roots:
            rr = os.path.abspath(r)
            if not os.path.isdir(rr):
                raise ValueError(f"Allowlisted root is not a directory: {r}")
            norm.append(rr)
        self.roots = norm

        if self.allowed_files is not None:
            self.allowed_files = {os.path.abspath(f) for f in self.allowed_files}

    def _in_roots(self, path: str) -> bool:
        p = os.path.abspath(path)
        for r in self.roots:
            if p == r or p.startswith(r + os.sep):
                return True
        return False

    def resolve(self, maybe_path: str) -> str:
        p = maybe_path
        if not os.path.isabs(p):
            p = os.path.abspath(os.path.join(os.getcwd(), p))
        p = os.path.abspath(p)

        if self.allowed_files is not None and os.path.isfile(p):
            if p not in self.allowed_files and not self._in_roots(p):
                raise ValueError("Access denied: file is not in the allowed files list.")
            return p

        if not self._in_roots(p):
            raise ValueError("Access denied: path is outside allowed directories.")
        return p


# ---------------------------------------------------------------------------
# Tool schemas
# ---------------------------------------------------------------------------

class ReadArgs(BaseModel):
    path: str = Field(..., description="File path to read (must be within allowed directories).")
    max_chars: int = Field(120_000, ge=1_000, le=2_000_000, description="Max characters to return.")

class HeadArgs(BaseModel):
    path: str
    max_lines: int = Field(200, ge=1, le=2000)

class ReadSliceArgs(BaseModel):
    path: str
    start_line: int = Field(..., ge=1, description="First line to return (1-indexed).")
    end_line: int = Field(..., ge=1, le=200000,
                         description=f"Last line to return (inclusive). Use start_line + {DEFAULT_SLICE_LINES - 1} as a default chunk size ({DEFAULT_SLICE_LINES} lines per call).")
    max_chars: int = Field(80_000, ge=1_000, le=200_000)

class GrepArgs(BaseModel):
    pattern: str = Field(..., description="Regex pattern (Python-style).")
    root: Optional[str] = Field(None, description="Optional root directory (must be an allowlisted source root like the source dir). Omit root to search all allowed analysis files — use glob= to filter by filename instead.")
    glob: Optional[str] = Field(None, description="Optional filename filter like 'nm_undef.txt' or '*.csv' (applied to basenames). Use this instead of root when targeting specific analysis output files.")
    max_matches: int = Field(200, ge=1, le=5000, description="Max number of matches to return.")

class GlobArgs(BaseModel):
    pattern: str = Field(..., description="Glob pattern (e.g. '**/*.c', '*.h'). Matched against files within allowed source directories.")
    root: Optional[str] = Field(None, description="Root directory to search within (must be under an allowed root). Defaults to all allowed roots.")
    max_results: int = Field(200, ge=1, le=2000, description="Max number of file paths to return.")

class CalcArgs(BaseModel):
    expression: str = Field(description=(
        "Arithmetic expression to evaluate. Supports integers, hex literals (0x...), "
        "floats, +, -, *, /, //, **, and parentheses. "
        "Use this whenever you need to convert hex to decimal or compute sizes. "
        "Examples: '0x801000000', '0x801000000 * 2', '34359738368 / 1e9', "
        "'0x1000 + 0x200'"
    ))


class ThinkArgs(BaseModel):
    thought: str = Field(description=(
        "Explicit chain-of-thought reasoning before the next tool call batch. "
        "State what you found, what it implies, and what you need to read next and why. "
        "Example: 'bloaty.txt shows __ft_data_MOD_u = 32 KB. "
        "ft_data.f90 shows ntotalp=nxp*ny*nz*2. Binary is ft.D.x → class D, not W. "
        "Need ghidra_alloc_sites.csv to verify actual malloc sizes for class D.'"
    ))


# ---------------------------------------------------------------------------
# Think tool (no-op; thought captured in AIMessage.tool_calls)
# ---------------------------------------------------------------------------

class Think(BaseTool):
    name: str = "Think"
    description: str = (
        "Use before each tool call batch to reason explicitly: "
        "what you found, what it implies, and what you need next. "
        "Does NOT count against your tool budget."
    )
    args_schema: type = ThinkArgs

    def _run(self, thought: str) -> str:  # type: ignore[override]
        return (
            "Thought recorded. "
            "NEXT STEP — choose exactly one:\n"
            "  A) Call ReadSlice / Head / Grep on a specific file\n"
            "  B) Write your final task summary as plain text (no tool calls)\n"
            "Do NOT call Think again."
        )


# Whitelist: hex digits, decimal digits, operators, parens, dot, underscore,
# scientific-notation e/E, and L suffix (Python 2 style long literals).
_CALC_SAFE_RE = re.compile(r'^[\d\s+\-*/().xXeE_a-fA-FL,]+$')
_CALC_BYTES_SUFFIXES = [
    (1 << 40, "TiB"),
    (1 << 30, "GiB"),
    (1 << 20, "MiB"),
    (1 << 10, "KiB"),
]


class Calc(BaseTool):
    name: str = "Calc"
    description: str = (
        "Evaluate an arithmetic expression. Use this for hex-to-decimal conversion "
        "and size arithmetic — do NOT compute hex values mentally. "
        "Always call Calc before using a hex value in an estimate."
    )
    args_schema: type = CalcArgs

    def _run(self, expression: str) -> str:  # type: ignore[override]
        expr = expression.strip().rstrip("Ll")
        if not _CALC_SAFE_RE.match(expr):
            raise ValueError(
                f"Expression contains disallowed characters: {expression!r}. "
                "Only digits, hex (0x...), and operators (+,-,*,/,**,()) are allowed."
            )
        try:
            result = eval(expr, {"__builtins__": {}}, {})  # noqa: S307
        except Exception as e:
            raise ValueError(f"Could not evaluate {expression!r}: {e}") from e

        if not isinstance(result, (int, float)):
            return str(result)

        lines = [f"= {result}"]
        if isinstance(result, float) and result != int(result):
            pass
        else:
            b = int(result)
            for size, unit in _CALC_BYTES_SUFFIXES:
                if abs(b) >= size:
                    lines.append(f"≈ {b / size:.3g} {unit}")
                    break
        return "\n".join(lines)


# ---------------------------------------------------------------------------
# build_tools
# ---------------------------------------------------------------------------

def build_tools(
    fs: AllowlistedFS,
    enabled_tools: List[str],
    call_cache: Dict[str, str],
    include_think: bool = False,
) -> List[Any]:
    tools: List[Any] = []

    def _cache_key(tool_name: str, **kwargs) -> str:
        return json.dumps({"tool": tool_name, **kwargs}, sort_keys=True)

    def _check_cache(key: str) -> None:
        if key not in call_cache:
            return
        cached = call_cache[key]
        preview = cached[:400] + ("…" if len(cached) > 400 else "")
        try:
            kd = json.loads(key)
            t = kd.get("tool", "")
            if t == "ReadSlice":
                end_line = kd.get("end_line", DEFAULT_SLICE_LINES)
                fname = os.path.basename(kd.get("path", ""))
                hint = (f" You read '{fname}' up to line {end_line}. "
                        f"To continue, call ReadSlice with start_line={end_line + 1}, end_line={end_line + DEFAULT_SLICE_LINES}.")
            elif t == "Head":
                max_lines = kd.get("max_lines", 200)
                fname = os.path.basename(kd.get("path", ""))
                hint = (f" You read the first {max_lines} lines of '{fname}'. "
                        f"To continue, call ReadSlice with start_line={max_lines + 1}, end_line={max_lines + DEFAULT_SLICE_LINES}.")
            else:
                hint = " Search a different file, or write your task summary."
        except Exception:
            hint = ""
        raise DuplicateCallError(
            f"DUPLICATE: you already made this call. The result was:\n{preview}\n"
            "Do NOT repeat it." + hint
        )

    def _store(key: str, result: str) -> str:
        call_cache[key] = result
        return result

    if "Read" in enabled_tools:
        @tool("Read", args_schema=ReadArgs)
        def read_tool(path: str, max_chars: int = 120_000) -> str:
            """Read a UTF-8 text file from allowlisted directories."""
            key = _cache_key("Read", path=path, max_chars=max_chars)
            _check_cache(key)
            full = fs.resolve(path)
            if not os.path.isfile(full):
                raise FileNotFoundError("Not a file.")
            msg = _binary_refusal_message(full)
            if msg:
                return msg
            with open(full, "r", encoding="utf-8", errors="replace") as f:
                return _store(key, f.read(max_chars))
        tools.append(read_tool)

    if "Head" in enabled_tools:
        @tool("Head", args_schema=HeadArgs)
        def head_tool(path: str, max_lines: int = 200) -> str:
            """Return the first N lines of a text file inside allowlisted roots (refuses binaries)."""
            key = _cache_key("Head", path=path, max_lines=max_lines)
            _check_cache(key)
            full = fs.resolve(path)
            msg = _binary_refusal_message(full)
            if msg:
                return msg
            out = []
            with open(full, "r", encoding="utf-8", errors="replace") as f:
                for _ in range(max_lines):
                    line = f.readline()
                    if not line:
                        break
                    out.append(line)
            return _store(key, "".join(out))
        tools.append(head_tool)

    if "ReadSlice" in enabled_tools:
        @tool("ReadSlice", args_schema=ReadSliceArgs)
        def readslice_tool(path: str, start_line: int, end_line: int, max_chars: int = 80_000) -> str:
            """Return lines [start_line, end_line] from a text file. Refuses binaries."""
            key = _cache_key("ReadSlice", path=path, start_line=start_line, end_line=end_line, max_chars=max_chars)
            _check_cache(key)
            if end_line < start_line:
                raise ValueError("end_line must be >= start_line")
            full = fs.resolve(path)
            msg = _binary_refusal_message(full)
            if msg:
                return msg
            out = []
            chars = 0
            last_line_seen = 0
            with open(full, "r", encoding="utf-8", errors="replace") as f:
                for i, line in enumerate(f, start=1):
                    last_line_seen = i
                    if i < start_line:
                        continue
                    if i > end_line:
                        break
                    out.append(line)
                    chars += len(line)
                    if chars >= max_chars:
                        out.append("\n[TRUNCATED: max_chars reached]\n")
                        break
            if not out:
                return _store(key, f"EOF: file has {last_line_seen} lines total; requested start_line={start_line} is past the end. Stop reading this file.")
            return _store(key, "".join(out))
        tools.append(readslice_tool)

    if "Grep" in enabled_tools:
        @tool("Grep", args_schema=GrepArgs)
        def grep_tool(
            pattern: str,
            root: Optional[str] = None,
            glob: Optional[str] = None,
            max_matches: int = 200,
        ) -> str:
            """
            Grep (regex search) within the allowed files.
            Returns JSON: {"matches":[{file,line,text},...], "truncated":bool}
            """
            key = _cache_key("Grep", pattern=pattern, root=root, glob=glob, max_matches=max_matches)
            _check_cache(key)
            filename_re = None
            if glob:
                g = re.escape(glob).replace(r"\*", ".*").replace(r"\?", ".")
                filename_re = re.compile("^" + g + "$")

            rx = re.compile(pattern)
            out: List[Dict[str, Any]] = []
            searched: set = set()
            truncated = False

            def _grep_file(fp: str) -> bool:
                """Search fp; return True if max_matches reached."""
                if _binary_refusal_message(fp):
                    return False
                try:
                    with open(fp, "r", encoding="utf-8", errors="replace") as f:
                        for i, line in enumerate(f, start=1):
                            if rx.search(line):
                                out.append({"file": fp, "line": i, "text": line.rstrip("\n")})
                                if len(out) >= max_matches:
                                    return True
                except (IsADirectoryError, PermissionError, OSError):
                    pass
                return False

            # Search explicitly allowed files first.
            if fs.allowed_files is not None:
                for fp in sorted(fs.allowed_files):
                    if filename_re and not filename_re.match(os.path.basename(fp)):
                        continue
                    searched.add(fp)
                    if _grep_file(fp):
                        return _store(key, json.dumps({"matches": out, "truncated": True}, indent=2))

            # Also walk root directories (source dirs added via --add-dir).
            dirs_to_walk: List[str]
            if root:
                start_dir = fs.resolve(root)
                if not os.path.isdir(start_dir):
                    raise ValueError("Root must be a directory.")
                dirs_to_walk = [start_dir]
            else:
                dirs_to_walk = list(fs.roots)

            for walk_root in dirs_to_walk:
                for dirpath, dirnames, filenames in os.walk(walk_root):
                    if not fs._in_roots(dirpath):
                        dirnames[:] = []
                        continue
                    for fn in filenames:
                        if filename_re and not filename_re.match(fn):
                            continue
                        fp = os.path.join(dirpath, fn)
                        if fp in searched or not fs._in_roots(fp):
                            continue
                        if _grep_file(fp):
                            truncated = True
                            break
                    if truncated:
                        break
                if truncated:
                    break

            return _store(key, json.dumps({"matches": out, "truncated": truncated}, indent=2))
        tools.append(grep_tool)

    if "Glob" in enabled_tools:
        import pathlib as _pathlib

        @tool("Glob", args_schema=GlobArgs)
        def glob_tool(
            pattern: str,
            root: Optional[str] = None,
            max_results: int = 200,
        ) -> str:
            """
            Find files matching a glob pattern within allowed source directories.
            Returns JSON: {"matches": [<absolute_path>, ...], "truncated": bool}
            """
            key = _cache_key("Glob", pattern=pattern, root=root, max_results=max_results)
            _check_cache(key)

            if root:
                r = fs.resolve(root)
                if not os.path.isdir(r):
                    raise ValueError("Root must be a directory.")
                dirs_to_walk = [r]
            else:
                dirs_to_walk = list(fs.roots)

            matches: List[str] = []
            truncated = False
            for walk_root in dirs_to_walk:
                for p in _pathlib.Path(walk_root).glob(pattern):
                    if not p.is_file():
                        continue
                    fp = str(p)
                    if not fs._in_roots(fp):
                        continue
                    matches.append(fp)
                    if len(matches) >= max_results:
                        truncated = True
                        break
                if truncated:
                    break

            return _store(key, json.dumps({"matches": matches, "truncated": truncated}))
        tools.append(glob_tool)

    # Calc is always available — no file access, pure arithmetic.
    tools.append(Calc())

    if include_think:
        tools.append(Think())

    return tools


# ---------------------------------------------------------------------------
# State
# ---------------------------------------------------------------------------

class HierarchicalState(TypedDict):
    root_prompt:        str                                           # original prompt (immutable)
    plan_json:          Optional[str]                                 # decomposer output
    task_stack:         List[Dict[str, Any]]                          # plain list, no reducer
    active_task_idx:    int                                           # index into task_stack
    tool_call_count:    int                                           # cumulative across ALL tasks
    force_end:          bool
    synth_messages:     Annotated[List[AnyMessage], operator.add]     # for synthesizer
    intercepted_answer: Optional[str]


# ---------------------------------------------------------------------------
# Output helpers
# ---------------------------------------------------------------------------

def emit_stream_json(obj: Dict[str, Any]) -> None:
    sys.stdout.write(json.dumps(obj, ensure_ascii=False) + "\n")
    sys.stdout.flush()

def emit_verbose(obj: Dict[str, Any], verbose: bool) -> None:
    if verbose:
        emit_stream_json({"role": "system", **obj})


# ---------------------------------------------------------------------------
# JSON schema helpers
# ---------------------------------------------------------------------------

def _schema_fields(validator: Optional[Draft202012Validator]) -> List[str]:
    if validator is None:
        return []
    return list(validator.schema.get("properties", {}).keys())


def load_schema_from_arg(schema_arg: Optional[str]) -> Optional[Draft202012Validator]:
    if not schema_arg:
        return None
    s = schema_arg.strip()
    if s.startswith("@"):
        path = s[1:]
        with open(path, "r", encoding="utf-8") as f:
            schema = json.load(f)
        return Draft202012Validator(schema)
    try:
        schema = json.loads(s)
    except json.JSONDecodeError as e:
        raise ValueError(
            "--json-schema must be a JSON string (or use @/path/to/schema.json). "
            f"Parse error: {e}"
        ) from e
    return Draft202012Validator(schema)


def try_parse_json(text: str) -> Optional[Any]:
    try:
        return json.loads(text)
    except Exception:
        return None


def strip_think(text: str) -> str:
    """Remove <think>...</think> reasoning blocks from model output."""
    cleaned = re.sub(r"<think>.*?</think>", "", text, flags=re.DOTALL).strip()
    return cleaned if cleaned else text


# ---------------------------------------------------------------------------
# _trim_messages (shared)
# ---------------------------------------------------------------------------

def _msgs_char_count(msgs: List[AnyMessage]) -> int:
    return sum(len(getattr(m, "content", "") or "") for m in msgs)

MAX_COMPRESS_RESULT_CHARS = 2000

def _format_batch_for_summary(batch_msgs: List[AnyMessage]) -> str:
    parts = []
    for m in batch_msgs:
        if getattr(m, "tool_calls", None):
            for tc in m.tool_calls:
                args_str = json.dumps(tc.get("args", {}), ensure_ascii=False)[:500]
                parts.append(f"Tool call: {tc['name']}({args_str})")
        elif isinstance(m, ToolMessage):
            content = (m.content or "")[:MAX_COMPRESS_RESULT_CHARS]
            parts.append(f"Result:\n{content}")
    return "\n".join(parts)

def _compress_batch(batch_msgs: List[AnyMessage], llm) -> str:
    raw = _format_batch_for_summary(batch_msgs)
    if not raw.strip():
        return ""
    try:
        out = llm.invoke([
            SystemMessage(content=(
                "Summarize the KEY FINDINGS from the following tool calls in "
                "3-5 concise bullet points. Focus on what was discovered "
                "(values, file contents, facts), not the mechanics of the calls."
            )),
            HumanMessage(content=raw),
        ])
        return getattr(out, "content", "") or ""
    except Exception:
        return ""

def _trim_messages(msgs: List[AnyMessage], llm=None) -> List[AnyMessage]:
    """Shrink context: compress (or drop) the oldest tool-call batch; if none exists, halve the system message."""
    for i, m in enumerate(msgs):
        if i < 2:
            continue
        if getattr(m, "tool_calls", None):
            j = i + 1
            while j < len(msgs) and isinstance(msgs[j], ToolMessage):
                j += 1
            batch = msgs[i:j]
            if llm is not None:
                summary = _compress_batch(batch, llm)
                if summary:
                    compressed = HumanMessage(
                        content=(
                            f"[COMPRESSED CONTEXT: tool calls {i}–{j-1} summarized]\n"
                            + summary
                        )
                    )
                    candidate = msgs[:i] + [compressed] + msgs[j:]
                    if _msgs_char_count(candidate) < _msgs_char_count(msgs):
                        return candidate
            # llm=None, compression failed, or summary was not smaller → fall back to dropping
            return msgs[:i] + msgs[j:]
    # No tool-call batch to drop — truncate the system message content by half.
    if msgs and isinstance(msgs[0], SystemMessage):
        content = msgs[0].content or ""
        if len(content) > 200:
            half = len(content) // 2
            return [SystemMessage(content=content[:half] + "\n[...context truncated to fit model limit...]")] + list(msgs[1:])
    # System message too short to halve — drop the oldest non-essential message (index 2).
    if len(msgs) >= 3:
        return msgs[:2] + msgs[3:]
    return msgs


# ---------------------------------------------------------------------------
# _resolve_fake_tool_args (shared)
# ---------------------------------------------------------------------------

def _resolve_fake_tool_args(args_dict: dict) -> str:
    resolved = {}
    for k, v in args_dict.items():
        if isinstance(v, str):
            parsed = try_parse_json(v)
            resolved[k] = parsed if parsed is not None else v
        else:
            resolved[k] = v
    return json.dumps(resolved, ensure_ascii=False)


_ERROR_PREFIXES = ("DUPLICATE_CALL_ERROR:", "FORCED_STOP:", "TOOL_ERROR:", "Error:", "EOF:")

def _is_error_msg(content: str) -> bool:
    return any(content.startswith(p) for p in _ERROR_PREFIXES)


# ---------------------------------------------------------------------------
# Default task stack — one task per schema field
# ---------------------------------------------------------------------------

# Per-field specs for the known binary-analysis schema fields.
# Each entry: (description, priority_reads).
# Fields not listed here get a generic fallback entry.
_KNOWN_FIELD_SPECS: Dict[str, Tuple[str, List[str]]] = {
    "parallelization": (
        "Determine all parallelization strategies in use (OMP, MPI, CUDA, HIP, threading, none). "
        "Check ldd.txt for libgomp/libmpi/libcuda, nm_undef.txt for MPI_Init/omp_* symbols, "
        "ghidra_parallel_evidence.csv for parallel API call sites. "
        "Report strategies as a list (e.g. ['openmp', 'mpi']) with supporting evidence.",
        ["ldd.txt", "nm_undef.txt", "ghidra_parallel_evidence.csv", "run_command.txt"],
    ),
    "vcpu_count": (
        "Estimate the number of vCPUs (logical CPU cores) this binary requires. "
        "Check OMP_NUM_THREADS / nthreads / ntasks in run_command.txt, MPI process count (-np), "
        "and symbols such as omp_get_num_threads/omp_get_num_procs in nm_undef.txt. "
        "Report a specific integer or 'ALL' if the code uses all available cores.",
        ["run_command.txt", "nm_undef.txt", "ldd.txt", "ghidra_parallel_evidence.csv"],
    ),
    "accelerator": (
        "Determine whether a GPU or other accelerator is required. "
        "Search ldd.txt for libcuda/librocm/libhip/libOpenCL, nm_undef.txt for cudaMalloc/hipMalloc, "
        "cuobjdump.txt for GPU kernel presence, file.txt for device code markers. "
        "Report type as 'gpu', 'other', or 'none'.",
        ["ldd.txt", "nm_undef.txt", "cuobjdump.txt", "file.txt"],
    ),
    "gpu_count": (
        "Estimate the number of GPUs required. "
        "Look for nccl/multi-GPU init symbols (ncclCommInitRank, cudaSetDevice calls with multiple IDs) "
        "in nm_undef.txt and ghidra_parallel_evidence.csv. Check run_command.txt for --ngpu / --ndevice flags. "
        "Report 0 if no GPU, an integer for a specific count, or 'ALL'.",
        ["nm_undef.txt", "run_command.txt", "ghidra_parallel_evidence.csv", "cuobjdump.txt"],
    ),
    "gpu_memory_gb": (
        "Estimate GPU memory required per GPU in GB. "
        "Check cuobjdump.txt for kernel register/shared-memory pressure, "
        "strings output for model-size hints, run_command.txt for --batch-size / --mem flags. "
        "Report 0 if no GPU is used.",
        ["cuobjdump.txt", "run_command.txt", "nm_undef.txt"],
    ),
    "memory": (
        "Estimate peak CPU memory (RAM) in GB. "
        "ReadSlice ghidra_alloc_sites.csv exhaustively — ALL rows, multiple ReadSlice chunks "
        "until you reach EOF; do NOT stop after finding the largest value or after the first chunk. "
        "For every row where size_arg_kind='const', size_arg_value is the allocation size in bytes; "
        "accumulate a running total across ALL such rows. "
        "Use Calc to sum and convert the final total to GiB. "
        "Callsites inside loops allocate repeatedly — factor in loop counts where available. "
        "Cross-validate against bloaty.txt section sizes if available. "
        "Report the total in GiB.",
        ["ghidra_alloc_sites.csv", "bloaty.txt", "nm_defined.txt", "file.txt"],
    ),
    "io_bound": (
        "Determine whether the workload is primarily I/O-bound. "
        "Search ldd.txt for HDF5/NetCDF/MPI-IO/POSIX-IO libraries, "
        "strings_io.txt for file-path patterns and large-read call sites, "
        "nm_undef.txt for fread/fwrite/hdf5 symbols. "
        "Report true if I/O dominates, false if compute-bound.",
        ["ldd.txt", "strings_io.txt", "nm_undef.txt", "run_command.txt"],
    ),
    "required_platform": (
        "Determine the CPU architecture required (x86_64, arm64, or ANY for platform-independent). "
        "Read file.txt for ELF machine type (e.g. 'ELF 64-bit LSB executable, x86-64'). "
        "Check for ISA-specific instructions or interpreter shebang if it is a script.",
        ["file.txt", "run_command.txt"],
    ),
}


def _default_task_stack(field_list: List[str], args: Any) -> List[Dict[str, Any]]:
    """Build one task per schema field. Fields not in _KNOWN_FIELD_SPECS get a generic task."""
    memory_budget  = min(int(args.tool_budget * SUBTASK_MEMORY_FRACTION), args.max_subtask_budget)
    default_budget = min(SUBTASK_DEFAULT_BUDGET, args.max_subtask_budget)

    tasks = []
    for field in field_list:
        if field in _KNOWN_FIELD_SPECS:
            description, priority_reads = _KNOWN_FIELD_SPECS[field]
        else:
            description = (
                f"Gather evidence for the '{field}' output field. "
                "Search ldd.txt, nm_undef.txt, and run_command.txt for relevant indicators. "
                f"Report all findings relevant to '{field}'."
            )
            priority_reads = ["ldd.txt", "nm_undef.txt", "run_command.txt", "file.txt"]

        budget = memory_budget if field == "memory" else default_budget

        tasks.append({
            "task_id":       field,
            "description":   description,
            "fields":        [field],
            "priority_reads": priority_reads,
            "budget":        budget,
            "messages":      [],
            "result":        None,
            "status":        "pending",
        })
    return tasks


# ---------------------------------------------------------------------------
# _compute_task_budgets
# ---------------------------------------------------------------------------

def _compute_task_budgets(tasks: List[Dict[str, Any]], args: Any) -> List[Dict[str, Any]]:
    """Assign budgets to tasks from args, applying overrides."""
    overrides: Dict[str, int] = {}
    if args.task_budget_json:
        try:
            overrides = json.loads(args.task_budget_json)
        except Exception:
            pass

    for task in tasks:
        tid = task["task_id"]
        if tid in overrides:
            task["budget"] = min(int(overrides[tid]), args.max_subtask_budget)
        elif tid == "memory" and args.subtask_budget_memory is not None:
            task["budget"] = min(args.subtask_budget_memory, args.max_subtask_budget)
        elif tid == "memory":
            task["budget"] = min(
                int(args.tool_budget * SUBTASK_MEMORY_FRACTION),
                args.max_subtask_budget)
        else:
            task["budget"] = min(SUBTASK_DEFAULT_BUDGET, args.max_subtask_budget)
    return tasks


# ---------------------------------------------------------------------------
# main() — builds everything in one closure so nodes can share mutable state
# ---------------------------------------------------------------------------

def main() -> int:
    ap = argparse.ArgumentParser(add_help=True)
    ap.add_argument("--tools", action="append", default=[],
                    help="Allowed tool name (e.g., Read, Grep). Can be repeated.")
    ap.add_argument("--add-dir", action="append", default=[],
                    help="Additional allowlisted directory. Can be repeated.")
    ap.add_argument("--allow-file", action="append", default=[], dest="allow_files",
                    help="Individually allowed file path. Can be repeated.")
    ap.add_argument("--output-format", choices=["text", "json", "stream-json"], default="text")
    ap.add_argument("--verbose", action="store_true")
    ap.add_argument("--json-schema", dest="json_schema", default=None,
                    help="Literal JSON Schema string (or @file).")
    ap.add_argument("-p", "--print", dest="prompt", default=None,
                    help="Prompt text (print mode).")
    ap.add_argument("--max-turns", type=int, default=DEFAULT_TURNS_LIMIT,
                    help="Maximum agent/tool turns.")
    ap.add_argument("--tool-budget", type=int, default=DEFAULT_TOOL_BUDGET, dest="tool_budget",
                    help="Soft cap on total successful tool calls across all tasks.")
    ap.add_argument("--model", default=os.environ.get("VLLM_MODEL", "your-model-name"))
    ap.add_argument("--base-url", default=os.environ.get("VLLM_BASE_URL", "http://localhost:8000/v1"))
    ap.add_argument("--api-key", default=os.environ.get("VLLM_API_KEY", "dummy"))
    ap.add_argument("--think", action="store_true",
                    help="Enable explicit Think pseudo-tool for chain-of-thought (default: off).")
    # Hierarchical-specific flags
    ap.add_argument("--subtask-budget-memory", type=int, default=None, dest="subtask_budget_memory",
                    help=f"Tool calls for memory task (default: {int(SUBTASK_MEMORY_FRACTION*100)}%% of --tool-budget).")
    ap.add_argument("--max-subtask-budget", type=int, default=MAX_SUBTASK_BUDGET, dest="max_subtask_budget",
                    help=f"Hard cap per subtask (default: {MAX_SUBTASK_BUDGET}).")
    ap.add_argument("--decompose-only", action="store_true", dest="decompose_only",
                    help="Print task decomposition JSON and exit (for debugging).")
    ap.add_argument("--task-budget-json", default=None, dest="task_budget_json",
                    help='Override per-task budgets as JSON: \'{"memory":20,"parallelization":10}\'')
    ap.add_argument("dirs", nargs="*", help="Allowlisted directories (positional).")

    args = ap.parse_args()

    if not args.prompt:
        sys.stderr.write("Provide -p/--print.\n")
        return 2

    enabled_tools = args.tools or ["Read", "ReadSlice", "Head", "Grep"]
    allowlisted_dirs: List[str] = list(args.dirs) + list(args.add_dir)
    if not allowlisted_dirs:
        allowlisted_dirs = [os.getcwd()]

    allowed_files_set = set(args.allow_files) if args.allow_files else None
    fs = AllowlistedFS(roots=allowlisted_dirs, allowed_files=allowed_files_set)

    if args.verbose and args.output_format == "stream-json":
        info: Dict[str, Any] = {"role": "system", "event": "allowed_roots", "roots": fs.roots}
        if fs.allowed_files is not None:
            info["allowed_files"] = sorted(fs.allowed_files)
        emit_stream_json(info)
    elif args.verbose:
        print("[allowed roots]", fs.roots, file=sys.stderr)
        if fs.allowed_files is not None:
            print("[allowed files]", sorted(fs.allowed_files), file=sys.stderr)

    # -----------------------------------------------------------------------
    # Mutable closure state (shared across all tasks)
    # -----------------------------------------------------------------------
    call_cache: Dict[str, str] = {}
    MAX_CONSECUTIVE_ERROR_TURNS = 3

    # -----------------------------------------------------------------------
    # Schema / field list
    # -----------------------------------------------------------------------
    validator = load_schema_from_arg(args.json_schema)
    field_list = _schema_fields(validator)
    field_list_str = ", ".join(field_list) if field_list else "(no schema fields)"

    # -----------------------------------------------------------------------
    # LLM instances
    # -----------------------------------------------------------------------
    llm_base = ChatOpenAI(
        model=args.model,
        base_url=args.base_url,
        api_key=args.api_key,
        temperature=0.2,
    )

    # -----------------------------------------------------------------------
    # Files section helper
    # -----------------------------------------------------------------------
    def _files_section() -> str:
        if fs.allowed_files is not None:
            files_list = "".join(f"  {f}\n" for f in sorted(fs.allowed_files))
            return "Allowed files (ONLY these paths — do NOT attempt others):\n" + files_list
        return f"Allowed directories: {', '.join(fs.roots)}\n"

    # -----------------------------------------------------------------------
    # _invoke_no_tools helper
    # -----------------------------------------------------------------------
    def _invoke_no_tools(msgs: List[AnyMessage]) -> str:
        """Call llm_base with context-overflow trimming, return text content."""
        while True:
            try:
                out = llm_base.invoke(msgs)
                return getattr(out, "content", "") or ""
            except OpenAIBadRequestError as e:
                if "context length" not in str(e) and "input_tokens" not in str(e):
                    raise
                before = _msgs_char_count(msgs[:-1])
                trimmed = _trim_messages(msgs[:-1], llm=llm_base)
                if _msgs_char_count(trimmed) >= before:
                    raise
                msgs = trimmed + [msgs[-1]]

    # -----------------------------------------------------------------------
    # Tool error handler factory
    # -----------------------------------------------------------------------
    def _make_tool_error_handler(phase: str):
        def handler(e: Exception) -> str:
            if isinstance(e, DuplicateCallError):
                return f"DUPLICATE_CALL_ERROR: {e}"
            return (
                f"TOOL_ERROR: {type(e).__name__}: {e}\n"
                "Recovery instructions:\n"
                "- Do NOT attempt to read binaries/executables (*.x, *.o, *.so).\n"
                "- Use the analysis text outputs (objdump/strings/nm/etc.) listed in MANIFEST.txt.\n"
                "- Use Grep + ReadSlice/Head on those text outputs instead.\n"
            )
        return handler

    # -----------------------------------------------------------------------
    # run_id / start event
    # -----------------------------------------------------------------------
    run_id = f"msg_{uuid.uuid4().hex[:20]}"
    if args.output_format == "stream-json":
        emit_stream_json({"id": run_id, "type": "start", "ts": int(time.time()), "model": args.model})

    # -----------------------------------------------------------------------
    # _make_task_system_msg
    # -----------------------------------------------------------------------
    def _make_task_system_msg(
        task: Dict[str, Any],
        plan_json: Optional[str],
        used: int = 0,
        total: Optional[int] = None,
    ) -> str:
        if total is None:
            total = task["budget"]
        remaining = max(0, total - used)

        think_instructions = ""
        if args.think:
            think_instructions = (
                "\nUse Think before each tool call batch to reason explicitly:\n"
                "  what you found → what it implies → what you need next and why\n"
                "Think calls do NOT count against your tool budget.\n"
            )

        priority_reads_section = ""
        pr = task.get("priority_reads", [])
        if pr:
            priority_reads_section = (
                "\nPriority reads for this task (start here, but follow evidence wherever it leads):\n"
                + "".join(f"  - {f}\n" for f in pr)
            )

        plan_context = ""
        if plan_json:
            plan_context = f"\nTask decomposition plan (for context):\n{plan_json}\n"

        return (
            f"You are a binary analysis agent working on task: {task['task_id']}\n"
            f"Tool budget: {remaining} calls remaining ({used}/{total} used).\n"
            + plan_context
            + f"\nTask description:\n{task['description']}\n"
            + f"\nFields this task covers: {', '.join(task['fields'])}\n"
            + priority_reads_section
            + "\nYou are free to read any file in the MANIFEST, not just the priority files.\n"
            "Follow evidence chains wherever they lead.\n"
            + think_instructions
            + "\nUse Calc for ANY hex-to-decimal conversion or arithmetic.\n"
            "  Example: Calc(\"0x801000000\") → value in bytes + human-readable size\n"
            "\nDo NOT re-read files already read (duplicate calls are rejected).\n"
            "Batch multiple independent reads as parallel tool calls in a single response.\n"
            "\nWhen you have gathered sufficient evidence for ALL fields in your task,\n"
            "write a prose summary of your findings. Include specific numbers, file sources,\n"
            "and any uncertainty. Do NOT produce JSON — just a thorough prose summary.\n"
            "\n" + _files_section()
        )

    # -----------------------------------------------------------------------
    # Node 1: decomposer_node — 1 LLM call, 0 tool calls
    # -----------------------------------------------------------------------
    def decomposer_node(state: HierarchicalState) -> Dict[str, Any]:
        memory_budget  = min(int(args.tool_budget * SUBTASK_MEMORY_FRACTION), args.max_subtask_budget)
        default_budget = min(SUBTASK_DEFAULT_BUDGET, args.max_subtask_budget)

        # Build per-field default descriptions for the prompt
        field_defaults_lines = []
        for fld in field_list:
            if fld in _KNOWN_FIELD_SPECS:
                desc, pr = _KNOWN_FIELD_SPECS[fld]
                budget = memory_budget if fld == "memory" else default_budget
                field_defaults_lines.append(
                    f'  - task_id="{fld}", fields=["{fld}"], budget={budget}\n'
                    f'    description: "{desc[:120]}..."\n'
                    f'    priority_reads: {pr[:3]}'
                )
        field_defaults_str = "\n".join(field_defaults_lines)

        system_content = (
            "You are a binary analysis agent. Your task is ONLY to produce a task decomposition plan.\n"
            "Do NOT call any tools.\n\n"
            f"Required output fields: {field_list_str}\n\n"
            "The MANIFEST contents are pre-loaded at the bottom of the human message — "
            "use them to set priority_reads for each task.\n\n"
            "Produce ONE task per required output field. Each task:\n"
            "- Has task_id equal to the field name\n"
            "- Covers exactly that one field (fields=[field_name])\n"
            "- Has a focused description: which files to read, which symbols/patterns to search for\n"
            "- Lists 2-4 priority_reads (starting files most likely to contain evidence)\n"
            "- Gets a budget proportional to complexity\n\n"
            f"Default per-field tasks (adjust priority_reads based on MANIFEST):\n"
            + field_defaults_str + "\n\n"
            f"Budget rules:\n"
            f"  - 'memory' field: {memory_budget} calls (CSV traversal + per-row Calc calls)\n"
            f"  - All other fields: {default_budget} calls each\n"
            "  - Note: shared files (ldd.txt, nm_undef.txt) are cached across tasks — later tasks\n"
            "    that need the same file will receive its content via a DUPLICATE cache hit.\n"
            "    Order tasks so the most data-hungry task for a file runs first.\n\n"
            "Produce a JSON task list:\n"
            "{\n"
            '  "tasks": [\n'
            '    {\n'
            '      "task_id": "<field_name>",\n'
            '      "description": "...",\n'
            '      "fields": ["<field_name>"],\n'
            '      "priority_reads": ["file1.txt", ...],\n'
            "      \"budget\": N\n"
            "    },\n"
            "    ...\n"
            "  ],\n"
            '  "reasoning": "ordering rationale"\n'
            "}\n\n"
            "Output ONLY the JSON object, no markdown fences."
        )

        sys_msg = SystemMessage(content=system_content)
        human_msg = HumanMessage(content=state["root_prompt"])
        raw = _invoke_no_tools([sys_msg, human_msg])

        # Strip markdown fences if present
        raw_stripped = re.sub(r"^```[a-z]*\n?", "", raw.strip())
        raw_stripped = re.sub(r"\n?```$", "", raw_stripped.strip())
        parsed = try_parse_json(raw_stripped)

        if parsed is not None and isinstance(parsed, dict) and "tasks" in parsed:
            tasks = parsed["tasks"]
            # Ensure required fields exist
            for t in tasks:
                t.setdefault("messages", [])
                t.setdefault("result", None)
                t.setdefault("status", "pending")
                t.setdefault("priority_reads", [])
                t.setdefault("fields", [])
                t.setdefault("budget", default_budget)
            # Override descriptions for known fields with canonical instructions.
            # The decomposer only sees a 120-char hint and generates weaker text;
            # always use the full spec so task executors get accurate instructions.
            for t in tasks:
                tid = t.get("task_id", "")
                if tid in _KNOWN_FIELD_SPECS:
                    t["description"] = _KNOWN_FIELD_SPECS[tid][0]
            tasks = _compute_task_budgets(tasks, args)
            plan_json_str = raw_stripped
            emit_verbose({
                "event": "decompose",
                "tasks": [t["task_id"] for t in tasks],
                "budgets": {t["task_id"]: t["budget"] for t in tasks},
            }, args.verbose)
        else:
            emit_verbose({"event": "decompose_parse_failed", "raw": raw[:300]}, args.verbose)
            tasks = _default_task_stack(field_list, args)
            plan_json_str = json.dumps({"tasks": [
                {k: v for k, v in t.items() if k not in ("messages", "result", "status")}
                for t in tasks
            ], "reasoning": "default decomposition (LLM parse failed)"})
            tasks = _compute_task_budgets(tasks, args)
            emit_verbose({
                "event": "decompose",
                "tasks": [t["task_id"] for t in tasks],
                "budgets": {t["task_id"]: t["budget"] for t in tasks},
            }, args.verbose)

        return {
            "plan_json":      plan_json_str,
            "task_stack":     tasks,
            "active_task_idx": 0,
        }

    # -----------------------------------------------------------------------
    # Node 2: task_executor_node — embedded ReAct while-loop
    # -----------------------------------------------------------------------
    def task_executor_node(state: HierarchicalState) -> Dict[str, Any]:
        idx = state["active_task_idx"]

        # Work on a local copy of the task dict
        src_task = state["task_stack"][idx]
        task: Dict[str, Any] = dict(src_task)
        task["messages"] = list(task.get("messages") or [])

        # Build task-local tools (shared call_cache for cross-task duplicate detection)
        task_tools = build_tools(fs, enabled_tools, call_cache, include_think=args.think)
        task_tool_names = {t.name for t in task_tools}
        task_tool_node = ToolNode(task_tools, handle_tool_errors=_make_tool_error_handler(task["task_id"]))
        llm_with_task_tools = llm_base.bind_tools(task_tools)

        # Initialize messages on first entry
        if not task["messages"]:
            task["messages"] = [
                SystemMessage(content=_make_task_system_msg(
                    task, state["plan_json"], used=0, total=task["budget"])),
                HumanMessage(content=state["root_prompt"]),
            ]

        task_tool_calls = [0]
        consecutive_errors = [0]
        consecutive_thinks = [0]
        force_task_end = [False]

        emit_verbose({
            "event":   "task_start",
            "task_id": task["task_id"],
            "budget":  task["budget"],
            "fields":  task["fields"],
        }, args.verbose)

        task["status"] = "running"

        while True:
            # Check budgets
            if task_tool_calls[0] >= task["budget"]:
                force_task_end[0] = True
            if state["tool_call_count"] + task_tool_calls[0] >= args.tool_budget:
                force_task_end[0] = True

            # Refresh system message with current budget usage
            task["messages"][0] = SystemMessage(content=_make_task_system_msg(
                task, state["plan_json"],
                used=task_tool_calls[0], total=task["budget"]))

            # LLM call with context-overflow handling
            while True:
                try:
                    response = llm_with_task_tools.invoke(task["messages"])
                    break
                except OpenAIBadRequestError as e:
                    if "context length" not in str(e) and "input_tokens" not in str(e):
                        raise
                    before = _msgs_char_count(task["messages"])
                    trimmed = _trim_messages(task["messages"], llm=llm_base)
                    if _msgs_char_count(trimmed) >= before:
                        raise
                    emit_verbose({
                        "event": "context_compressed",
                        "task_id": task["task_id"],
                        "msgs_before": len(task["messages"]),
                        "msgs_after": len(trimmed),
                    }, args.verbose)
                    task["messages"] = trimmed

            task["messages"].append(response)

            # Emit stream-json for this LLM response
            if args.output_format == "stream-json":
                content_arr = []
                if getattr(response, "tool_calls", None):
                    for tc in response.tool_calls:
                        content_arr.append({
                            "type": "tool_use",
                            "id": tc.get("id") or f"toolu_{uuid.uuid4().hex[:20]}",
                            "name": tc["name"],
                            "input": tc["args"],
                        })
                else:
                    content_arr.append({"type": "text", "text": response.content or ""})
                emit_stream_json({
                    "id": run_id, "type": "message", "role": "assistant",
                    "model": args.model, "content": content_arr,
                    "stop_reason": "tool_use" if getattr(response, "tool_calls", None) else "end_turn",
                })

            # Check for text answer (no tool calls) or forced end
            tool_calls = getattr(response, "tool_calls", None) or []
            if not tool_calls or force_task_end[0]:
                result_text = (response.content or "").strip()
                if not result_text:
                    result_text = "No findings for this task."
                task["result"] = result_text
                task["status"] = "done"
                break

            # Execute all tools via ToolNode
            fake_calls = [tc for tc in tool_calls if tc["name"] not in task_tool_names]
            real_calls = [tc for tc in tool_calls if tc["name"] in task_tool_names and tc["name"] != "Think"]

            # Handle all-fake tool calls (intercepted answer)
            if fake_calls and len(fake_calls) == len(tool_calls):
                tc = fake_calls[0]
                candidate = _resolve_fake_tool_args(tc.get("args") or {})
                emit_verbose({"event": "fake_tool_recovery", "tool": tc["name"],
                              "task_id": task["task_id"]}, args.verbose)
                task["result"] = candidate
                task["status"] = "done"
                break

            tool_result_state = task_tool_node.invoke({"messages": [response]})
            new_msgs: List[AnyMessage] = tool_result_state["messages"]

            # Separate Think from real tool results
            think_msgs = [m for m in new_msgs
                          if isinstance(m, ToolMessage) and getattr(m, "name", "") == "Think"]
            real_tool_msgs = [m for m in new_msgs
                              if isinstance(m, ToolMessage) and getattr(m, "name", "") != "Think"]

            # Emit think events
            if args.think and args.verbose:
                for tm in think_msgs:
                    for tc in tool_calls:
                        if tc["name"] == "Think" and tc.get("id") == tm.tool_call_id:
                            emit_verbose({
                                "event":   "think",
                                "task_id": task["task_id"],
                                "thought": tc["args"].get("thought", ""),
                            }, args.verbose)
                            break

            # Emit tool results in stream-json
            if args.output_format == "stream-json":
                for m in new_msgs:
                    if isinstance(m, ToolMessage) and getattr(m, "name", "") != "Think":
                        emit_stream_json({
                            "role": "user",
                            "content": [{"type": "tool_result",
                                         "tool_use_id": m.tool_call_id,
                                         "content": m.content}]
                        })

            # Think-only detection
            if think_msgs and not real_tool_msgs:
                consecutive_thinks[0] += 1
                if consecutive_thinks[0] >= 2:
                    new_msgs.append(HumanMessage(content=(
                        f"WARNING: Think called {consecutive_thinks[0]} times without file tools. "
                        "You MUST now call ReadSlice/Head/Grep OR write your task summary."
                    )))
                if consecutive_thinks[0] >= MAX_CONSECUTIVE_THINK_TURNS:
                    force_task_end[0] = True
            else:
                consecutive_thinks[0] = 0

            # Count successful real tool calls
            successful = sum(1 for m in real_tool_msgs if not _is_error_msg(m.content or ""))
            task_tool_calls[0] += successful

            # Track consecutive all-error turns
            if real_tool_msgs and all(_is_error_msg(m.content or "") for m in real_tool_msgs):
                consecutive_errors[0] += 1
            else:
                consecutive_errors[0] = 0

            task["messages"].extend(new_msgs)

            if consecutive_errors[0] >= MAX_CONSECUTIVE_ERROR_TURNS:
                task["result"] = "Task aborted: too many consecutive tool errors."
                task["status"] = "done"
                break

        emit_verbose({
            "event":           "task_done",
            "task_id":         task["task_id"],
            "tool_calls_used": task_tool_calls[0],
            "result_preview":  (task.get("result") or "")[:200],
        }, args.verbose)

        # Return updated task_stack (replace the entire list)
        new_stack = list(state["task_stack"])
        new_stack[idx] = task

        return {
            "task_stack":      new_stack,
            "tool_call_count": state["tool_call_count"] + task_tool_calls[0],
            "active_task_idx": idx + 1,
        }

    # -----------------------------------------------------------------------
    # Route: route_task_executor
    # -----------------------------------------------------------------------
    def route_task_executor(state: HierarchicalState) -> str:
        if state.get("force_end"):
            return "synthesize"
        idx = state["active_task_idx"]
        if idx >= len(state["task_stack"]):
            return "synthesize"
        if state["tool_call_count"] >= args.tool_budget:
            return "synthesize"
        return "next_task"

    # -----------------------------------------------------------------------
    # Node 3: synthesizer_node — 1-4 LLM calls
    # -----------------------------------------------------------------------
    def synthesizer_node(state: HierarchicalState) -> Dict[str, Any]:
        task_stack = state["task_stack"]
        completed = [t for t in task_stack if t.get("result")]
        n_completed = len(completed)

        emit_verbose({"event": "synthesis_start", "tasks_completed": n_completed}, args.verbose)

        # Build task results section
        task_results_section = ""
        for task in task_stack:
            task_id = task.get("task_id", "unknown")
            result = task.get("result") or "(no findings)"
            task_results_section += f"\n--- Task: {task_id} ---\n{result}\n"

        schema_str = json.dumps(validator.schema, indent=2) if validator else ""
        output_instructions = (
            "Produce the final JSON matching the schema exactly.\n"
            + (f"{schema_str}\n\n" if schema_str else "")
            + "Output ONLY the JSON object, no markdown fences."
        ) if validator else "Write your final answer as plain text."

        # Handle intercepted_answer as additional context
        intercepted_note = ""
        if state.get("intercepted_answer"):
            intercepted_note = (
                f"\nAdditional intercepted answer (may contain partial JSON):\n"
                f"{state['intercepted_answer']}\n"
            )

        system_content = (
            f"You are in SYNTHESIS phase. Do NOT call any tools.\n\n"
            f"You have received findings from {n_completed} analysis tasks:\n"
            + task_results_section
            + intercepted_note
            + "\nBased on ALL findings above, "
            + output_instructions
        )

        synth_msgs: List[AnyMessage] = [
            SystemMessage(content=system_content),
            HumanMessage(content=state["root_prompt"]),
        ]
        last_text = _invoke_no_tools(synth_msgs)

        # Schema nudge loop (up to 3 retries)
        if validator:
            nudge_msgs = synth_msgs + [AIMessage(content=last_text)]
            for nudge_attempt in range(3):
                parsed_out = try_parse_json(strip_think(last_text))
                errors = list(validator.iter_errors(parsed_out)) if parsed_out is not None else []
                if parsed_out is not None and not errors:
                    break
                emit_verbose({"event": "schema_nudge", "attempt": nudge_attempt + 1}, args.verbose)
                if parsed_out is None:
                    error_detail = "Your response was not valid JSON."
                else:
                    error_detail = "Validation errors:\n" + "\n".join(
                        f"- {e.json_path}: {e.message}" for e in errors[:8]
                    )
                schema_nudge = (
                    "Return ONLY valid JSON matching the schema, with required fields and correct types. "
                    "Do not include markdown or commentary."
                )
                nudge_prompt = HumanMessage(content=(
                    f"Your previous response did NOT validate against the JSON Schema.\n"
                    f"{error_detail}\n\n"
                    f"Required schema:\n{json.dumps(validator.schema, indent=2)}\n\n"
                    + schema_nudge
                ))
                last_text = _invoke_no_tools(nudge_msgs + [nudge_prompt])
                nudge_msgs = nudge_msgs + [HumanMessage(content=nudge_prompt.content),
                                           AIMessage(content=last_text)]

        return {"synth_messages": [AIMessage(content=last_text)]}

    # -----------------------------------------------------------------------
    # Build graph
    # -----------------------------------------------------------------------
    graph = StateGraph(HierarchicalState)
    graph.add_node("decomposer",    decomposer_node)
    graph.add_node("task_executor", task_executor_node)
    graph.add_node("synthesizer",   synthesizer_node)

    graph.set_entry_point("decomposer")
    graph.add_edge("decomposer", "task_executor")
    graph.add_conditional_edges("task_executor", route_task_executor,
        {"next_task": "task_executor", "synthesize": "synthesizer"})
    graph.add_edge("synthesizer", END)

    app = graph.compile()

    # -----------------------------------------------------------------------
    # Initial state
    # -----------------------------------------------------------------------
    prompt = args.prompt.strip()

    # Read MANIFEST once and inject so every LLM call (decomposer, task executors,
    # synthesizer) sees the full file list without spending a tool call on it.
    _manifest_content = ""
    _manifest_candidates = []
    if fs.allowed_files:
        _manifest_candidates = [f for f in fs.allowed_files
                                 if os.path.basename(f) == "MANIFEST.txt"]
    if not _manifest_candidates:
        for _root in fs.roots:
            _candidate = os.path.join(_root, "MANIFEST.txt")
            if os.path.isfile(_candidate):
                _manifest_candidates.append(_candidate)
    if _manifest_candidates:
        try:
            with open(_manifest_candidates[0], "r", encoding="utf-8", errors="replace") as _mf:
                _manifest_content = _mf.read()
        except Exception:
            pass
    if _manifest_content:
        prompt = (prompt
                  + "\n\nMANIFEST (pre-loaded — do NOT call a tool to re-read this file):\n"
                  + _manifest_content)

    initial_state: HierarchicalState = {
        "root_prompt":       prompt,
        "plan_json":         None,
        "task_stack":        [],
        "active_task_idx":   0,
        "tool_call_count":   0,
        "force_end":         False,
        "synth_messages":    [],
        "intercepted_answer": None,
    }

    # --decompose-only: show default task stack and exit (no LLM call needed)
    if args.decompose_only:
        tasks = _default_task_stack(field_list, args)
        tasks = _compute_task_budgets(tasks, args)
        out = json.dumps({
            "tasks": [
                {k: v for k, v in t.items() if k not in ("messages", "result", "status")}
                for t in tasks
            ]
        }, indent=2)
        sys.stdout.write(out + "\n")
        return 0

    emit_verbose({"event": "agent_run"}, args.verbose)
    final = app.invoke(initial_state, config={"recursion_limit": args.max_turns})

    # -----------------------------------------------------------------------
    # Extract final answer
    # -----------------------------------------------------------------------
    synth_msgs = final.get("synth_messages", [])
    last_text = ""
    if synth_msgs:
        last = synth_msgs[-1]
        last_text = getattr(last, "content", "") or ""

    # Force completion if empty
    if not last_text.strip() or (validator and not try_parse_json(strip_think(last_text))):
        schema_nudge = (
            "Return ONLY valid JSON matching the schema, with required fields and correct types. "
            "Do not include markdown or commentary."
        )
        forced_nudge = (
            "You have used all available tool calls. "
            "Based on everything gathered so far, produce your final answer now."
            + (f" {schema_nudge}" if validator else "")
        )
        # Build a condensed context from task results
        task_stack = final.get("task_stack", [])
        task_summary = "\n".join(
            f"Task {t['task_id']}: {t.get('result', '(none)')}"
            for t in task_stack
        )
        forced_msgs = [
            SystemMessage(content=(
                "You are in SYNTHESIS phase. Do NOT call any tools.\n\n"
                "Task findings:\n" + task_summary + "\n\n"
                + (f"Required schema:\n{json.dumps(validator.schema, indent=2)}\n\n" if validator else "")
            )),
            HumanMessage(content=forced_nudge),
        ]
        last_text = _invoke_no_tools(forced_msgs)

    # -----------------------------------------------------------------------
    # Compact last_text to a single-line JSON string.
    # The model may prepend a reasoning block before the JSON object, so try
    # progressively: full text → fence-stripped → from first '{' onward.
    # -----------------------------------------------------------------------
    def _compact(text: str) -> str:
        clean = strip_think(text)
        candidates = [
            clean,
            re.sub(r"^```[a-z]*\n?", "", clean).rstrip("` \n"),
        ]
        brace = clean.find("{")
        if brace != -1:
            candidates.append(clean[brace:].strip())
        for c in candidates:
            p = try_parse_json(c)
            if p is not None:
                return json.dumps(p, ensure_ascii=False)
        return text

    last_text = _compact(last_text)

    # -----------------------------------------------------------------------
    # Output
    # -----------------------------------------------------------------------
    if args.output_format == "json":
        sys.stdout.write(json.dumps({"output": last_text}, ensure_ascii=False) + "\n")
    elif args.output_format == "stream-json":
        emit_stream_json({
            "id": run_id,
            "type": "message",
            "role": "assistant",
            "model": args.model,
            "content": [{"type": "text", "text": last_text}],
            "stop_reason": "end_turn",
        })
        emit_stream_json({"id": run_id, "type": "end", "ts": int(time.time())})

    tool_calls_final = final.get("tool_call_count", 0)
    sys.stderr.write(f"tool_calls={tool_calls_final}\n")

    sys.stdout.write(last_text + ("" if last_text.endswith("\n") else "\n"))
    sys.stdout.flush()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
