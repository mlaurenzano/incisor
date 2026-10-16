# Third-party notices

The incisor code itself is released under the University of Illinois/NCSA
Open Source License (see `LICENSE`). That license does not extend to the
third-party components listed here. Each remains under its own license, which
is reproduced or linked below. Nothing in this repository modifies, links
against, or embeds any of the GPL or LGPL components; incisor invokes them as
separate command-line programs and parses their output.

## 1. Code redistributed in this repository

### Bezier surface benchmark (`hec_omp_n16_bezier/program/source/bezier-surface-omp/`)

Taken from HeCBench (<https://github.com/ORNL/HeCBench>, `src/bezier-surface-omp`).
Two licenses apply:

- The HeCBench packaging (`Makefile`, `Makefile.aomp`, `Makefile.nvc`,
  `CMakeLists.txt`, `input/`) is BSD-3-Clause, Copyright (c) 2020 Argonne
  National Laboratory and Oak Ridge National Laboratory (Zheming Jin). The
  full text is in `hec_omp_n16_bezier/program/LICENSE-HeCBench.txt`.
- The kernel itself (`main.cpp`) originates in the Chai benchmark suite and
  keeps its own NCSA-style header, reproduced here:

```
Copyright (c) 2016 University of Cordoba and University of Illinois
All rights reserved.

Developed by:    IMPACT Research Group
                 University of Cordoba and University of Illinois
                 http://impact.crhc.illinois.edu/

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
with the Software without restriction, including without limitation the
rights to use, copy, modify, merge, publish, distribute, sublicense, and/or
sell copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

     > Redistributions of source code must retain the above copyright notice,
       this list of conditions and the following disclaimers.
     > Redistributions in binary form must reproduce the above copyright
       notice, this list of conditions and the following disclaimers in the
       documentation and/or other materials provided with the distribution.
     > Neither the names of IMPACT Research Group, University of Cordoba,
       University of Illinois nor the names of its contributors may be used
       to endorse or promote products derived from this Software without
       specific prior written permission.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
CONTRIBUTORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS WITH
THE SOFTWARE.
```

The prebuilt binary in `hec_omp_n16_bezier/program/runnable/` was compiled
from that source and is covered by the same notice.

### AWS instance catalog (`static_aws_useast1.csv`)

A snapshot of the EC2 instance table for us-east-1 exported from
ec2instances.info (<https://github.com/vantage-sh/ec2instances.info>, MIT
License). The underlying figures are AWS's published instance specifications
and list prices. Prices change; the snapshot is provided for reproducibility
only, not as a source of current pricing.

## 2. Tools downloaded or built by `install.sh`

These are not stored in the repository. `install.sh` fetches the pinned
version from the upstream project and places it under `agents/tools/` or the
repository root, where each component keeps its own license file.

| Component | Version | License | Upstream |
|---|---|---|---|
| Prometheus and promtool | 3.9.1 | Apache-2.0 | <https://github.com/prometheus/prometheus> |
| Eclipse Temurin JDK | 21 | GPL-2.0 with Classpath Exception | <https://adoptium.net> |
| Ghidra | 12.1.4 | Apache-2.0. Stand-alone helper programs under `GPL/` are GPL-3.0. Bundled icon sets include LGPL-2.1 and LGPL-3.0 works. The full per-module list is in `licenses/` and each module's `LICENSE.txt` inside the install. | <https://github.com/NationalSecurityAgency/ghidra> |
| Ghidra Jython extension | shipped with Ghidra 12.1.4 | Jython License (PSF-style) | same |
| Bloaty McBloatface | git main, commit f1a83e6 | Apache-2.0. Bundled dependencies: Abseil (Apache-2.0), Capstone (BSD-3), demumble (Apache-2.0), FreeBSD ELF headers (BSD-2), googletest (BSD-3), LIEF PE headers (Apache-2.0), Darwin XNU Mach-O headers (APSL-2.0), protobuf (BSD-3), RE2 (BSD-3), zlib (zlib), zstd (BSD-3 or GPL-2, used under BSD-3). | <https://github.com/google/bloaty> |
| radare2 | 6.2.4 | LGPL-3.0 core with MIT, BSD-3, Apache-2.0, and zlib plugins. `install.sh` builds with `--without-gpl` by default, which omits the GPL-3.0 architecture plugins; pass `--with-gpl` to include them. | <https://github.com/radareorg/radare2> |

Ghidra's `NOTICE` additionally states that portions written by U.S.
Government employees are not subject to U.S. copyright and are in the public
domain in the United States.

## 3. Python packages (`requirements.txt`)

Installed with pip, not redistributed here.

| Package | License |
|---|---|
| angr | BSD-2-Clause |
| langchain-openai | MIT |
| langgraph, langgraph-prebuilt | MIT |
| mcp | MIT |
| skypilot | Apache-2.0 |

## 4. External services

`incisor_setup.sh` downloads Prometheus node_exporter 1.10.2 (Apache-2.0) on
the target host at run time. `launch_vllm.sh` runs vLLM (Apache-2.0) in a
container and pulls model weights from Hugging Face; each model has its own
license and access terms, which the user accepts when obtaining a token.
