#!/usr/bin/env python3
"""
query_instances_mcp.py — stdio MCP server exposing query_instances as a tool.

Launched by the Claude Code CLI via --mcp-config; the tool is surfaced to the
model as mcp__instances__FilterInstances.
"""

from __future__ import annotations

import os
import sys
from typing import Optional

# Ensure sibling query_instances.py is importable regardless of cwd.
_SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
if _SCRIPT_DIR not in sys.path:
    sys.path.insert(0, _SCRIPT_DIR)

from mcp.server.fastmcp import FastMCP  # noqa: E402

from query_instances import query_instances, _DEFAULT_CSV  # noqa: E402

mcp = FastMCP("instances")


@mcp.tool()
def FilterInstances(
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
    """Filter the AWS instance catalog and return matching instances as CSV.

    Args:
        min_memory_gib: Minimum instance memory in GiB.
        max_memory_gib: Maximum instance memory in GiB.
        min_vcpus: Minimum vCPU count.
        max_vcpus: Maximum vCPU count.
        arch: CPU architecture (e.g. "x86_64", "arm64").
        needs_gpu: True requires GPU, False excludes GPU, None = no filter.
        min_gpu_memory_gib: Minimum per-GPU memory in GiB (only with needs_gpu=True).
        include_burstable: Set true to include burstable instances (t2, t3, t3a, etc.); excluded by default.
        include_flex: Set true to include flex instances (c8i-flex, m7i-flex, etc.); excluded by default.
        min_gen_number: Minimum instance generation number (e.g. 8 keeps m8i, c8a but drops m7i, c6a).
        limit: Maximum number of rows to return.
    """
    return query_instances(
        src_csv=_DEFAULT_CSV,
        min_memory_gib=min_memory_gib,
        max_memory_gib=max_memory_gib,
        min_vcpus=min_vcpus,
        max_vcpus=max_vcpus,
        arch=arch,
        needs_gpu=needs_gpu,
        min_gpu_memory_gib=min_gpu_memory_gib,
        include_burstable=include_burstable,
        include_flex=include_flex,
        min_gen_number=min_gen_number,
        limit=limit,
    )


if __name__ == "__main__":
    mcp.run()
