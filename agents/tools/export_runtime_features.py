#@runtime Jython
# -*- coding: utf-8 -*-

# export_runtime_features.py
# Run with: analyzeHeadless <projdir> <projname> -postScript export_runtime_features.py <OUTDIR>
#
# Emits CSV files into OUTDIR:
#   ghidra_functions.csv
#   ghidra_imports_xrefs.csv
#   ghidra_strings_xrefs.csv
#   ghidra_alloc_sites.csv
#   ghidra_parallel_evidence.csv
#   ghidra_io_evidence.csv

import os, csv

from ghidra.program.model.symbol import SymbolType
from ghidra.program.model.block import BasicBlockModel
from ghidra.app.decompiler import DecompInterface

def ensure_dir(p):
    if not os.path.isdir(p):
        os.makedirs(p)

def wcsv(path, header):
    f = open(path, 'wb')  # Jython2 csv wants binary mode
    w = csv.writer(f, delimiter='\t')
    w.writerow(header)
    return f, w

def s(x):
    try:
        return "" if x is None else str(x)
    except:
        return "<unprintable>"

def count_refs_to(addr):
    rm = currentProgram.getReferenceManager()
    n = 0
    for _ in rm.getReferencesTo(addr):
        n += 1
    return n

def caller_name(addr):
    f = getFunctionContaining(addr)
    return "" if f is None else s(f.getName())

def num_basic_blocks(func):
    bbm = BasicBlockModel(currentProgram)
    it = bbm.getCodeBlocksContaining(func.getBody(), monitor)
    n = 0
    while it.hasNext():
        it.next()
        n += 1
    return n

def has_backedge(func):
    listing = currentProgram.getListing()
    it = listing.getInstructions(func.getBody(), True)
    while it.hasNext():
        ins = it.next()
        flows = ins.getFlows()
        if flows is None:
            continue
        src = ins.getAddress()
        for dst in flows:
            try:
                if func.getBody().contains(dst) and dst.compareTo(src) < 0:
                    return True
            except:
                pass
    return False

def count_calls_out(func):
    listing = currentProgram.getListing()
    it = listing.getInstructions(func.getBody(), True)
    n = 0
    while it.hasNext():
        ins = it.next()
        ft = ins.getFlowType()
        if ft is not None and ft.isCall():
            n += 1
    return n

def init_decompiler():
    ifc = DecompInterface()
    ifc.openProgram(currentProgram)
    return ifc

def resolve_call_target(ins):
    flows = ins.getFlows()
    if flows is None or len(flows) == 0:
        return None, None
    tgt = flows[0]
    sym = getSymbolAt(tgt)
    if sym is not None:
        return s(sym.getName()), tgt
    fn = getFunctionAt(tgt)
    if fn is not None:
        return s(fn.getName()), tgt
    return s(tgt), tgt

def main():
    args = getScriptArgs()
    if args is None or len(args) < 1:
        raise Exception("Usage: export_runtime_features.py <OUTDIR>")
    outdir = args[0]
    ensure_dir(outdir)

    rm = currentProgram.getReferenceManager()
    listing = currentProgram.getListing()
    symtab = currentProgram.getSymbolTable()

    # -------------------------
    # 1) Functions index
    fn_f, fn_w = wcsv(os.path.join(outdir, "ghidra_functions.csv"),
                      ["addr","name","size_bytes","num_blocks","stack_frame_bytes","xrefs_in","calls_out","has_loop_backedge"])

    fm = currentProgram.getFunctionManager()
    it = fm.getFunctions(True)
    while it.hasNext():
        f = it.next()
        try:
            body = f.getBody()
            size_bytes = int(body.getNumAddresses())  # heuristic, but stable
            nb = num_basic_blocks(f)
            try:
                sf = int(f.getStackFrame().getFrameSize())
            except:
                sf = 0
            xi = count_refs_to(f.getEntryPoint())
            co = count_calls_out(f)
            hl = 1 if has_backedge(f) else 0
            fn_w.writerow([s(f.getEntryPoint()), s(f.getName()), size_bytes, nb, sf, xi, co, hl])
        except:
            pass
    fn_f.close()

    # -------------------------
    # 2) Imports + xrefs
    imp_f, imp_w = wcsv(os.path.join(outdir, "ghidra_imports_xrefs.csv"),
                        ["import","ext_lib","caller","callsite","ref_type"])

    ext_syms = symtab.getExternalSymbols()
    for sym in ext_syms:
        try:
            name = sym.getName()
            ext_lib = ""
            try:
                parent = sym.getParentSymbol()
                if parent is not None:
                    ext_lib = s(parent.getName())
            except:
                ext_lib = ""
            addr = sym.getAddress()
            refs = rm.getReferencesTo(addr)
            for r in refs:
                frm = r.getFromAddress()
                imp_w.writerow([s(name), ext_lib, caller_name(frm), s(frm), s(r.getReferenceType())])
        except:
            pass
    imp_f.close()

    # -------------------------
    # 3) Strings + xrefs (only strings that Ghidra defined as string data)
    str_f, str_w = wcsv(os.path.join(outdir, "ghidra_strings_xrefs.csv"),
                        ["string","string_addr","caller","xref_from"])

    data_it = listing.getDefinedData(True)
    while data_it.hasNext():
        d = data_it.next()
        try:
            if not d.hasStringValue():
                continue
            sval = s(d.getValue())
            a = d.getAddress()
            refs = rm.getReferencesTo(a)
            for r in refs:
                frm = r.getFromAddress()
                str_w.writerow([sval, s(a), caller_name(frm), s(frm)])
        except:
            pass
    str_f.close()

    # -------------------------
    # 4) Allocation sites (best-effort)
    alloc_names = set([
        "malloc","calloc","realloc","free",
        "mmap","munmap","brk","sbrk",
        "posix_memalign","aligned_alloc",
        "_Znwm","_Znam","_ZnwmRKSt9nothrow_t","_ZnamRKSt9nothrow_t",
        "operator new","operator new[]"
    ])

    alloc_f, alloc_w = wcsv(os.path.join(outdir, "ghidra_alloc_sites.csv"),
                            ["kind","caller","callsite","target","size_arg_kind","size_arg_value"])

    decomp = None
    try:
        decomp = init_decompiler()
    except:
        decomp = None

    # Pre-index external alloc symbol addresses
    alloc_ext_addrs = set()
    for sym in ext_syms:
        try:
            if sym.getSymbolType() == SymbolType.FUNCTION and sym.getName() in alloc_names:
                alloc_ext_addrs.add(sym.getAddress())
        except:
            pass

    ins_it = listing.getInstructions(True)
    while ins_it.hasNext():
        ins = ins_it.next()
        try:
            ft = ins.getFlowType()
            if ft is None or not ft.isCall():
                continue
            tgt_name, tgt_addr = resolve_call_target(ins)
            if tgt_name is None:
                continue
            if (tgt_name not in alloc_names) and (tgt_addr not in alloc_ext_addrs):
                continue

            callsite = ins.getAddress()
            caller = caller_name(callsite)
            kind = "free_like" if ("free" in tgt_name or "munmap" in tgt_name) else "alloc"

            size_kind, size_val = "", ""

            # Best-effort: if we can decompile, extract constant first arg to CALL pcode.
            if decomp is not None and caller != "":
                fn = getFunctionContaining(callsite)
                if fn is not None:
                    res = decomp.decompileFunction(fn, 10, monitor)
                    if res is not None and res.decompileCompleted():
                        hf = res.getHighFunction()
                        if hf is not None:
                            ops = hf.getPcodeOps(callsite)
                            while ops.hasNext():
                                op = ops.next()
                                if op.getOpcode() in [op.CALL, op.CALLIND]:
                                    if op.getNumInputs() >= 2:
                                        v = op.getInput(1)
                                        if v is not None and v.isConstant():
                                            size_kind, size_val = "const", str(v.getOffset())
                                        else:
                                            size_kind, size_val = "nonconst", ""
                                    break

            alloc_w.writerow([kind, caller, s(callsite), s(tgt_name), size_kind, size_val])
        except:
            pass
    alloc_f.close()

    # -------------------------
    # 5) Parallelism evidence (imports + strings)
    parallel_signatures = {
        "openmp": ["GOMP_", "omp_", "__kmpc_", "kmp_", "iomp"],
        "pthread": ["pthread_", "std::thread", "clone"],
        "mpi": ["MPI_"],
        "tbb": ["tbb", "TBB"],
        "cuda": ["cuda", "cuLaunchKernel", "cudaLaunchKernel", "cudart", "nvrtc", "nvtx"],
        "hip": ["hip", "hipLaunchKernel"],
        "opencl": ["clEnqueue", "OpenCL", "libOpenCL"]
    }

    par_f, par_w = wcsv(os.path.join(outdir, "ghidra_parallel_evidence.csv"),
                        ["model","evidence_type","name","count","sample_caller"])

    counts = {}
    sample = {}

    # imports
    for sym in ext_syms:
        try:
            n = sym.getName()
            for model, pats in parallel_signatures.items():
                for p in pats:
                    if p in n:
                        k = (model, "import", n)
                        counts[k] = counts.get(k, 0) + 1
                        if k not in sample:
                            # pick a sample caller if possible
                            sc = ""
                            for r in rm.getReferencesTo(sym.getAddress()):
                                sc = caller_name(r.getFromAddress())
                                if sc != "":
                                    break
                            sample[k] = sc
        except:
            pass

    # strings
    data_it2 = listing.getDefinedData(True)
    while data_it2.hasNext():
        d = data_it2.next()
        try:
            if not d.hasStringValue():
                continue
            sval = s(d.getValue())
            for model, pats in parallel_signatures.items():
                for p in pats:
                    if p in sval:
                        k = (model, "string", p)
                        counts[k] = counts.get(k, 0) + 1
                        if k not in sample:
                            sc = ""
                            for r in rm.getReferencesTo(d.getAddress()):
                                sc = caller_name(r.getFromAddress())
                                if sc != "":
                                    break
                            sample[k] = sc
        except:
            pass

    for (model, et, name), c in counts.items():
        par_w.writerow([model, et, name, c, sample.get((model, et, name), "")])
    par_f.close()

    # -------------------------
    # 6) I/O evidence (imports + strings)
    io_signatures = {
        "file_io": ["open","openat","read","write","pread","pwrite","lseek","fopen","fread","fwrite","fprintf","fsync","fdatasync"],
        "mmap_io": ["mmap","munmap","msync"],
        "dir_fs": ["opendir","readdir","stat","lstat","fstat","access","chmod","chown","rename","unlink","mkdir","rmdir"],
        "net_io": ["socket","connect","accept","send","recv","sendto","recvfrom","getaddrinfo","poll","epoll","select"],
        "async_io": ["io_uring","aio_","epoll"],
        "compression": ["zlib","deflate","inflate","ZSTD","LZ4","bz2","snappy"],
        "data_formats": ["H5","HDF5","netcdf","protobuf","flatbuffers","parquet","arrow"]
    }

    io_f, io_w = wcsv(os.path.join(outdir, "ghidra_io_evidence.csv"),
                      ["category","evidence_type","name","count","sample_caller"])

    counts2 = {}
    sample2 = {}

    for sym in ext_syms:
        try:
            n = sym.getName()
            for cat, pats in io_signatures.items():
                for p in pats:
                    if p in n:
                        k = (cat, "import", n)
                        counts2[k] = counts2.get(k, 0) + 1
                        if k not in sample2:
                            sc = ""
                            for r in rm.getReferencesTo(sym.getAddress()):
                                sc = caller_name(r.getFromAddress())
                                if sc != "":
                                    break
                            sample2[k] = sc
        except:
            pass

    data_it3 = listing.getDefinedData(True)
    while data_it3.hasNext():
        d = data_it3.next()
        try:
            if not d.hasStringValue():
                continue
            sval = s(d.getValue())
            for cat, pats in io_signatures.items():
                for p in pats:
                    if p in sval:
                        k = (cat, "string", p)
                        counts2[k] = counts2.get(k, 0) + 1
                        if k not in sample2:
                            sc = ""
                            for r in rm.getReferencesTo(d.getAddress()):
                                sc = caller_name(r.getFromAddress())
                                if sc != "":
                                    break
                            sample2[k] = sc
        except:
            pass

    for (cat, et, name), c in counts2.items():
        io_w.writerow([cat, et, name, c, sample2.get((cat, et, name), "")])
    io_f.close()

    # -------------------------
    # 7) Decompiler output — pseudo-C for every function
    decomp2 = None
    try:
        decomp2 = init_decompiler()
    except:
        decomp2 = None

    if decomp2 is not None:
        dec_path = os.path.join(outdir, "ghidra_decomp.txt")
        dec_f = open(dec_path, 'w')
        fm3 = currentProgram.getFunctionManager()
        it3 = fm3.getFunctions(True)
        while it3.hasNext():
            f = it3.next()
            try:
                res = decomp2.decompileFunction(f, 30, monitor)
                if res is not None and res.decompileCompleted():
                    c_code = res.getDecompiledFunction().getC()
                    if c_code:
                        dec_f.write("/* === %s @ %s === */\n" % (s(f.getName()), s(f.getEntryPoint())))
                        dec_f.write(c_code)
                        dec_f.write("\n")
            except:
                pass
        dec_f.close()
        decomp2.dispose()

if __name__ == "__main__":
    main()
