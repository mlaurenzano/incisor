#!/usr/bin/env python3
"""
query_instances.py — filter the AWS instance catalog by explicit parameters.

Usage:
    query_instances.py [options] [--output <dst.csv>]

Options:
  --min-memory-gib FLOAT      Minimum instance memory (GiB)
  --max-memory-gib FLOAT      Maximum instance memory (GiB)
  --min-vcpus INT              Minimum vCPU count
  --max-vcpus INT              Maximum vCPU count
  --arch STR                   CPU architecture filter (e.g. x86_64, arm64); omit = no filter
  --gpu / --no-gpu             Require GPU presence or absence; omit = no filter
  --min-gpu-memory-gib FLOAT  Minimum per-GPU memory (GiB); only meaningful with --gpu
  --output PATH                Write filtered CSV here (default: stdout)
  --csv PATH                   Source CSV (default: ../../static_aws_useast1.csv relative to script)
"""

from __future__ import annotations

import argparse
import csv
import io
import os
import re
import sys
from typing import Optional

_SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
_DEFAULT_CSV = os.path.join(_SCRIPT_DIR, "..", "..", "static_aws_useast1.csv")

_ALWAYS_KEEP = [
    "API Name",
    "Instance Memory",
    "Memory Speed",
    "vCPUs",
    "Physical Processor",
    "Arch",
    "Instance Storage",
    "On Demand",
    "Generation",
    "NUMA Node Count",
    "Cores per NUMA Node (Avg)",
]
_GPU_COLS = ["GPUs", "GPU model", "GPU memory"]


def _parse_gib(s: str) -> float:
    """Parse '32 GiB' / '256 GB' → float GiB."""
    m = re.search(r"([\d,]+(?:\.\d+)?)\s*GiB?", s.replace(",", ""), re.I)
    return float(m.group(1)) if m else 0.0


def _parse_vcpus(s: str) -> int:
    """Parse '16 vCPUs' → 16."""
    m = re.search(r"(\d+)", s)
    return int(m.group(1)) if m else 0


def _is_gpu_row(row: dict) -> bool:
    return (
        row.get("Compute Family", "").strip() == "GPU Instance"
        or float(row.get("GPUs", "0").strip() or "0") > 0
    )


def query_instances(
    src_csv: str,
    min_memory_gib: Optional[float] = None,
    max_memory_gib: Optional[float] = None,
    min_vcpus: Optional[int] = None,
    max_vcpus: Optional[int] = None,
    arch: Optional[str] = None,
    needs_gpu: Optional[bool] = None,
    min_gpu_memory_gib: Optional[float] = None,
    include_burstable: bool = False,
    include_flex: bool = False,
    min_gen_number: Optional[int] = None,
    limit: Optional[int] = None,
) -> str:
    """Filter the AWS instance catalog and return a pruned CSV as a string.

    Unlike filter_instances.py, returns an empty CSV (header only) if no rows
    match — the caller should broaden parameters and retry.
    """
    with open(src_csv, newline="", encoding="utf-8") as fh:
        rows = list(csv.DictReader(fh))

    filtered = []
    for row in rows:
        # Skip rows with no on-demand price
        if not row.get("On Demand", "").strip():
            continue
        # Arch filter
        if arch is not None and row.get("Arch", "").strip() != arch:
            continue
        # GPU presence filter
        if needs_gpu is not None and needs_gpu != _is_gpu_row(row):
            continue
        # Exclude burstable instances (t2, t3, t3a, etc.) unless explicitly included
        api_name = row.get("API Name", "")
        if not include_burstable and api_name and api_name[0] in ("t", "T"):
            continue
        # Exclude flex instances (c8i-flex, m7i-flex, etc.) unless explicitly included
        if not include_flex and "-flex" in api_name:
            continue
        # Generation number filter (e.g. min_gen_number=8 keeps m8i, c8a but drops m7i, c6a)
        if min_gen_number is not None:
            m = re.search(r"[a-z](\d+)", row.get("API Name", ""))
            if m and int(m.group(1)) < min_gen_number:
                continue
        # Memory bounds
        mem = _parse_gib(row.get("Instance Memory", ""))
        if min_memory_gib is not None and mem < min_memory_gib:
            continue
        if max_memory_gib is not None and mem > max_memory_gib:
            continue
        # vCPU bounds
        vcpus = _parse_vcpus(row.get("vCPUs", ""))
        if min_vcpus is not None and vcpus < min_vcpus:
            continue
        if max_vcpus is not None and vcpus > max_vcpus:
            continue
        # Per-GPU memory (only applies when needs_gpu=True)
        if needs_gpu and min_gpu_memory_gib is not None and min_gpu_memory_gib > 0:
            if _parse_gib(row.get("GPU memory", "")) < min_gpu_memory_gib:
                continue
        filtered.append(row)

    # Cap the number of returned rows
    if limit is not None and limit > 0:
        filtered = filtered[:limit]

    # Include GPU columns only if any filtered rows have GPU
    include_gpu = any(_is_gpu_row(r) for r in filtered)
    keep = _ALWAYS_KEEP + (_GPU_COLS if include_gpu else [])

    out = io.StringIO()
    writer = csv.DictWriter(out, fieldnames=keep, extrasaction="ignore")
    writer.writeheader()
    for row in filtered:
        writer.writerow({k: row.get(k, "") for k in keep})
    return out.getvalue()


def main() -> int:
    ap = argparse.ArgumentParser(
        description="Filter the AWS instance catalog by explicit parameters."
    )
    ap.add_argument("--min-memory-gib", type=float, default=None)
    ap.add_argument("--max-memory-gib", type=float, default=None)
    ap.add_argument("--min-vcpus", type=int, default=None)
    ap.add_argument("--max-vcpus", type=int, default=None)
    ap.add_argument("--arch", default=None)
    gpu_group = ap.add_mutually_exclusive_group()
    gpu_group.add_argument("--gpu", action="store_true", default=False)
    gpu_group.add_argument("--no-gpu", action="store_true", default=False)
    ap.add_argument("--min-gpu-memory-gib", type=float, default=None)
    ap.add_argument("--include-burstable", action="store_true", default=False)
    ap.add_argument("--include-flex", action="store_true", default=False)
    ap.add_argument("--min-gen-number", type=int, default=None)
    ap.add_argument("--limit", type=int, default=None)
    ap.add_argument("--output", default=None)
    ap.add_argument("--csv", default=_DEFAULT_CSV)
    args = ap.parse_args()

    needs_gpu: Optional[bool] = None
    if args.gpu:
        needs_gpu = True
    elif args.no_gpu:
        needs_gpu = False

    result = query_instances(
        src_csv=args.csv,
        min_memory_gib=args.min_memory_gib,
        max_memory_gib=args.max_memory_gib,
        min_vcpus=args.min_vcpus,
        max_vcpus=args.max_vcpus,
        arch=args.arch,
        needs_gpu=needs_gpu,
        min_gpu_memory_gib=args.min_gpu_memory_gib,
        include_burstable=args.include_burstable,
        include_flex=args.include_flex,
        min_gen_number=args.min_gen_number,
        limit=args.limit,
    )

    if args.output:
        with open(args.output, "w", encoding="utf-8") as f:
            f.write(result)
    else:
        sys.stdout.write(result)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
