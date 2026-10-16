#!/usr/bin/env -S /data/mlaurenz/adviser/e2e/llm/tools/venv/bin/python3
"""
angr CFG analysis helper: recover function structure from a binary.
Called by constraint_analysis.sh when ENABLE_ANGR=1.
Usage: angr_analyze.py <binary> [cfg_json_out] [decomp_out]
  cfg_json_out: if given, writes call graph JSON (nodes + edges)
  decomp_out:   if given, writes pseudo-C decompilation of all named functions
"""
import sys

if len(sys.argv) not in (2, 3, 4, 5):
    print(f"Usage: {sys.argv[0]} <binary> [cfg_json_out] [decomp_out]", file=sys.stderr)
    sys.exit(1)

binary       = sys.argv[1]
cfg_out      = sys.argv[2] if len(sys.argv) >= 3 else None
decomp_out   = sys.argv[3] if len(sys.argv) >= 4 else None
functions_out = sys.argv[4] if len(sys.argv) >= 5 else None

try:
    import angr
except ImportError:
    print("angr not installed. Run: pip install angr")
    sys.exit(1)

import json

try:
    p = angr.Project(binary, auto_load_libs=False)
    print(f"Binary:       {binary}")
    print(f"Architecture: {p.arch.name}")
    print(f"Entry point:  {hex(p.entry)}")
    print()

    # pick executable sections
    main = p.loader.main_object
    texty = [s for s in main.sections if s.is_executable]
    regions = [(s.vaddr, s.vaddr + s.memsize) for s in texty]
    for r in regions:
        print(r)

    print("Running CFGFast analysis (no execution required)...")
    cfg = p.analyses.CFGFast(show_progressbar=True)
    funcs = sorted(cfg.functions.values(), key=lambda f: f.addr)
    named = [f for f in funcs if not f.name.startswith(("sub_", "fun_"))]

    func_lines = []
    func_lines.append(f"Total functions recovered: {len(funcs)} ({len(named)} named)")
    func_lines.append("")
    func_lines.append(f"{'Function':<50}  {'Address':<14}  {'Blocks':>6}  {'Bytes':>8}")
    func_lines.append("-" * 84)
    for f in named:
        func_lines.append(f"  {f.name:<48}  {hex(f.addr):<14}  {len(f.block_addrs_set):>6}  {f.size:>8}")

    if functions_out:
        with open(functions_out, 'w') as fh:
            fh.write("\n".join(func_lines) + "\n")
    else:
        print("\n".join(func_lines))

    # Optional second file: call graph JSON
    if cfg_out:
        func_by_addr = {f.addr: f for f in funcs}
        nodes = [
            {
                'addr':             hex(f.addr),
                'name':             f.name,
                'size':             f.size,
                'blocks':           len(f.block_addrs_set),
                'is_simprocedure':  f.is_simprocedure,
                'has_return':       f.has_return,
            }
            for f in funcs
        ]
        calls = []
        for src_addr, dst_addr in cfg.functions.callgraph.edges():
            src = func_by_addr.get(src_addr)
            dst = func_by_addr.get(dst_addr)
            if src and dst:
                calls.append({
                    'from_addr': hex(src_addr),
                    'from_name': src.name,
                    'to_addr':   hex(dst_addr),
                    'to_name':   dst.name,
                })
        with open(cfg_out, 'w') as fh:
            json.dump({'functions': nodes, 'calls': calls}, fh, indent=2)

    # Optional third file: pseudo-C decompilation of all named functions
    if decomp_out:
        with open(decomp_out, 'w') as fh:
            for f in named:
                try:
                    f.normalize()
                    dec = p.analyses.Decompiler(f, cfg=cfg)
                    if dec.codegen and dec.codegen.text:
                        fh.write(f"/* === {f.name} @ {hex(f.addr)} === */\n")
                        fh.write(dec.codegen.text)
                        fh.write("\n\n")
                except Exception as de:
                    fh.write(f"/* === {f.name} @ {hex(f.addr)} : decompilation failed: {de} === */\n\n")

except Exception as e:
    print(f"Analysis failed: {e}", file=sys.stderr)
    sys.exit(1)
