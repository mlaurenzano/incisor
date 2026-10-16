#!/usr/bin/env bash
#
# install.sh — fetch (and build where needed) the third-party tools incisor uses.
#
# Installs, relative to this script's directory:
#   prometheus-<ver>.linux-<arch>/        Prometheus + promtool (prebuilt, Apache-2.0)
#   agents/tools/jdk21/                   Temurin JDK 21, needed by Ghidra (GPL-2 w/ Classpath exception)
#   agents/tools/ghidra/                  Ghidra release + Jython extension (prebuilt, Apache-2.0;
#                                         GPL-3 helpers under GPL/, Jython under PSF license)
#   agents/tools/bloaty/bin/bloaty        Bloaty, built from source (Apache-2.0)
#   agents/tools/radare2/{bin,lib}/       radare2, built from source (LGPL-3; GPL-3 plugins opt-in)
#
# Usage:
#   ./install.sh [--only a,b,...] [--force] [--jobs N] [--with-gpl] [--keep-downloads]
#
#   --only LIST        comma-separated subset of: prometheus jdk ghidra bloaty radare2
#   --force            reinstall a component even if it is already present
#   --jobs N           parallel build jobs (default: nproc)
#   --with-gpl         build radare2 with its GPL-3 plugins (default: --without-gpl)
#   --keep-downloads   do not delete the downloads/ cache when finished
#
# Each version pin can be overridden through the environment, e.g. GHIDRA_VERSION=12.2.
# Build prerequisites (Debian/Ubuntu names): build-essential cmake ninja-build git
# curl unzip tar xz-utils pkg-config patch.

set -euo pipefail

# ---------------------------------------------------------------- versions --
PROMETHEUS_VERSION="${PROMETHEUS_VERSION:-3.9.1}"

JDK_VERSION="${JDK_VERSION:-21.0.12.1+1}"              # Temurin release name, e.g. 21.0.12.1+1

GHIDRA_VERSION="${GHIDRA_VERSION:-12.1.4}"
GHIDRA_DATE="${GHIDRA_DATE:-20260921}"                 # date suffix of the release zip

BLOATY_REPO="${BLOATY_REPO:-https://github.com/google/bloaty.git}"
BLOATY_REF="${BLOATY_REF:-f1a83e63f36beb628dcf022e1201a2eb391a22a6}"   # main, 2026-09-24

RADARE2_VERSION="${RADARE2_VERSION:-6.2.4}"

# ----------------------------------------------------------------- options --
ROOT="${INCISOR_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
TOOLS="${ROOT}/agents/tools"
DL="${ROOT}/downloads"

ONLY="prometheus,jdk,ghidra,bloaty,radare2"
FORCE=0
JOBS="$(nproc 2>/dev/null || echo 4)"
R2_GPL_FLAG="--without-gpl"
KEEP_DL=0

while [ $# -gt 0 ]; do
    case "$1" in
        --only)           ONLY="$2"; shift 2 ;;
        --only=*)         ONLY="${1#*=}"; shift ;;
        --force)          FORCE=1; shift ;;
        --jobs)           JOBS="$2"; shift 2 ;;
        --jobs=*)         JOBS="${1#*=}"; shift ;;
        --with-gpl)       R2_GPL_FLAG="--with-gpl"; shift ;;
        --keep-downloads) KEEP_DL=1; shift ;;
        -h|--help)        sed -n '2,24p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "unknown option: $1" >&2; exit 2 ;;
    esac
done

case "$(uname -m)" in
    x86_64)  ARCH_PROM=amd64; ARCH_JDK=x64 ;;
    aarch64) ARCH_PROM=arm64; ARCH_JDK=aarch64 ;;
    *) echo "unsupported architecture: $(uname -m)" >&2; exit 1 ;;
esac

# ----------------------------------------------------------------- helpers --
log()  { printf '\n==> %s\n' "$*"; }
die()  { echo "error: $*" >&2; exit 1; }
want() { case ",${ONLY}," in *",$1,"*) return 0 ;; *) return 1 ;; esac; }

need_cmd() {
    local missing=()
    for c in "$@"; do command -v "$c" >/dev/null 2>&1 || missing+=("$c"); done
    [ ${#missing[@]} -eq 0 ] || die "missing required commands: ${missing[*]}"
}

# fetch URL DEST — download to DEST unless it already exists and is non-empty.
fetch() {
    local url="$1" dest="$2"
    if [ -s "$dest" ]; then
        echo "    cached: $(basename "$dest")"
        return
    fi
    mkdir -p "$(dirname "$dest")"
    echo "    downloading $(basename "$dest")"
    curl -fL --retry 3 --progress-bar -o "${dest}.part" "$url"
    mv "${dest}.part" "$dest"
}

# installed MARKER — true if MARKER exists and --force was not given.
installed() {
    if [ -e "$1" ] && [ "$FORCE" -eq 0 ]; then
        echo "    already installed ($1); use --force to reinstall"
        return 0
    fi
    return 1
}

# ------------------------------------------------------------- prometheus --
install_prometheus() {
    local name="prometheus-${PROMETHEUS_VERSION}.linux-${ARCH_PROM}"
    local dest="${ROOT}/${name}"
    log "Prometheus ${PROMETHEUS_VERSION} (${ARCH_PROM})"
    installed "${dest}/promtool" && return
    fetch "https://github.com/prometheus/prometheus/releases/download/v${PROMETHEUS_VERSION}/${name}.tar.gz" \
          "${DL}/${name}.tar.gz"
    rm -rf "$dest"
    tar -xzf "${DL}/${name}.tar.gz" -C "$ROOT"
    "${dest}/promtool" --version | head -1
}

# -------------------------------------------------------------------- jdk --
install_jdk() {
    local dest="${TOOLS}/jdk21"
    local ver_path="${JDK_VERSION/+/%2B}"            # 21.0.12.1+1 -> 21.0.12.1%2B1 (URL path)
    local ver_file="${JDK_VERSION/+/_}"              # 21.0.12.1+1 -> 21.0.12.1_1   (file name)
    local tarball="OpenJDK21U-jdk_${ARCH_JDK}_linux_hotspot_${ver_file}.tar.gz"
    log "Temurin JDK ${JDK_VERSION} (${ARCH_JDK})"
    installed "${dest}/bin/java" && return
    fetch "https://github.com/adoptium/temurin21-binaries/releases/download/jdk-${ver_path}/${tarball}" \
          "${DL}/${tarball}"
    rm -rf "$dest"
    mkdir -p "$dest"
    tar -xzf "${DL}/${tarball}" -C "$dest" --strip-components=1
    "${dest}/bin/java" -version 2>&1 | head -1
}

# ----------------------------------------------------------------- ghidra --
install_ghidra() {
    local dest="${TOOLS}/ghidra"
    local zip="ghidra_${GHIDRA_VERSION}_PUBLIC_${GHIDRA_DATE}.zip"
    log "Ghidra ${GHIDRA_VERSION}"
    installed "${dest}/support/analyzeHeadless" && return
    need_cmd unzip
    fetch "https://github.com/NationalSecurityAgency/ghidra/releases/download/Ghidra_${GHIDRA_VERSION}_build/${zip}" \
          "${DL}/${zip}"
    rm -rf "$dest" "${DL}/ghidra_unpack"
    mkdir -p "${DL}/ghidra_unpack"
    unzip -q "${DL}/${zip}" -d "${DL}/ghidra_unpack"
    # The zip contains a single top-level directory, ghidra_<ver>_PUBLIC/.
    mv "${DL}/ghidra_unpack"/ghidra_* "$dest"
    rmdir "${DL}/ghidra_unpack"
    # Since 12.0 Jython is shipped as an extension, not built in. Our headless
    # post-script (export_runtime_features.py) is Jython, so install it
    # installation-wide by unpacking it into Ghidra/Extensions/.
    local jython_zip
    jython_zip="$(ls "${dest}"/Extensions/Ghidra/ghidra_*_Jython.zip 2>/dev/null | head -1)"
    [ -n "$jython_zip" ] || die "Jython extension zip not found in ${dest}/Extensions/Ghidra"
    unzip -q "$jython_zip" -d "${dest}/Ghidra/Extensions"
    [ -d "${dest}/Ghidra/Extensions/Jython" ] || die "Jython extension did not unpack as expected"
    grep -E '^application\.(version|release\.name)=' "${dest}/Ghidra/application.properties"
}

# ----------------------------------------------------------------- bloaty --
install_bloaty() {
    local dest="${TOOLS}/bloaty"
    local src="${DL}/bloaty-src"
    log "Bloaty @ ${BLOATY_REF:0:12} (build from source)"
    installed "${dest}/bin/bloaty" && return
    need_cmd git cmake ninja g++
    if [ ! -d "${src}/.git" ]; then
        rm -rf "$src"
        git clone --no-checkout "$BLOATY_REPO" "$src"
    fi
    git -C "$src" fetch --depth 1 origin "$BLOATY_REF"
    git -C "$src" checkout --quiet "$BLOATY_REF"
    git -C "$src" submodule update --init --depth 1 --recursive
    rm -rf "${src}/build"
    cmake -S "$src" -B "${src}/build" -G Ninja \
          -DCMAKE_BUILD_TYPE=Release \
          -DCMAKE_INSTALL_PREFIX="$dest" \
          -DBLOATY_ENABLE_TESTS=OFF
    cmake --build "${src}/build" -j "$JOBS"
    rm -rf "$dest"
    cmake --install "${src}/build"
    # Only the binary is used; keep the license next to it.
    cp "${src}/LICENSE" "${dest}/LICENSE"
    "${dest}/bin/bloaty" --version
}

# ---------------------------------------------------------------- radare2 --
install_radare2() {
    local dest="${TOOLS}/radare2"
    local name="radare2-${RADARE2_VERSION}"
    local src="${DL}/${name}"
    log "radare2 ${RADARE2_VERSION} (build from source, ${R2_GPL_FLAG})"
    installed "${dest}/bin/r2" && return
    need_cmd make gcc patch
    fetch "https://github.com/radareorg/radare2/releases/download/${RADARE2_VERSION}/${name}.tar.xz" \
          "${DL}/${name}.tar.xz"
    rm -rf "$src" "$dest"
    tar -xJf "${DL}/${name}.tar.xz" -C "$DL"
    ( cd "$src" \
      && ./configure --prefix="$dest" "$R2_GPL_FLAG" >configure.log 2>&1 \
      && make -j "$JOBS" >make.log 2>&1 \
      && make install >install.log 2>&1 ) \
      || die "radare2 build failed; see ${src}/{configure,make,install}.log"
    cp "${src}/COPYING.md" "${dest}/COPYING.md"
    LD_LIBRARY_PATH="${dest}/lib" "${dest}/bin/r2" -v | head -1
}

# ------------------------------------------------------------------- main --
need_cmd curl tar
mkdir -p "$TOOLS" "$DL"

want prometheus && install_prometheus
want jdk        && install_jdk
want ghidra     && install_ghidra
want bloaty     && install_bloaty
want radare2    && install_radare2

if [ "$KEEP_DL" -eq 0 ]; then
    log "Removing download cache ${DL} (use --keep-downloads to keep it)"
    rm -rf "$DL"
fi

log "Done. Installed under ${ROOT}:"
for p in "prometheus-${PROMETHEUS_VERSION}.linux-${ARCH_PROM}/promtool" \
         "agents/tools/jdk21/bin/java" \
         "agents/tools/ghidra/support/analyzeHeadless" \
         "agents/tools/bloaty/bin/bloaty" \
         "agents/tools/radare2/bin/r2"; do
    if [ -e "${ROOT}/${p}" ]; then echo "    [ok]      ${p}"; else echo "    [missing] ${p}"; fi
done
