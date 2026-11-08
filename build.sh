#!/usr/bin/env bash
# Vexa Transcoder build: downloads the pinned sources (VERSIONS), applies Jellyfin's patches and ours (patches/vexa),
# builds every library as a static archive and links one binary: dist/vexa-transcoder (+ dist/vexa-probe).
#
#   ./build.sh            build (each step is skipped when its pinned version is already built)
#   ./build.sh fetch      only download the sources
#   ./build.sh clean      remove the build and dist folders of the target (keeps the downloads in deps/)
#
# Targets (TARGET=...):
#   (unset)     native build on Linux (x86_64/arm64, fully static) or macOS (x86_64/arm64, only system libraries
#               are dynamic). Output in build/ and dist/.
#   win64       Windows x86_64, cross-compiled with llvm-mingw (downloaded to deps/ at the pinned version).
#   winarm64    Windows arm64, same. Output in build-<target>/ and dist-<target>/ (vexa-transcoder.exe).
#
# Needs: a C/C++ compiler, make, cmake, meson, ninja, autoconf/automake/libtool, pkg-config, git, curl, patch, perl,
# and nasm for x86_64 targets. On macOS: Xcode command line tools plus those from Homebrew.
# Only our own libraries are visible to pkg-config: nothing from the system ends up linked by accident.
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
. "$ROOT/VERSIONS"

log() { printf '\033[1;34m[vexa-transcoder]\033[0m %s\n' "$*"; }
die() { printf '\033[1;31m[vexa-transcoder]\033[0m %s\n' "$*" >&2; exit 1; }

TARGET=${TARGET:-}
HOST_OS=$(uname -s)
case "$TARGET" in
    "")       OS=$HOST_OS CROSS= ;;
    win64)    OS=Windows CROSS=x86_64-w64-mingw32 CPU=x86_64 ;;
    winarm64) OS=Windows CROSS=aarch64-w64-mingw32 CPU=aarch64 ;;
    *)        die "unknown TARGET: $TARGET" ;;
esac
[ -z "$CROSS" ] && CPU=$(uname -m)
case "$OS" in Linux | Darwin | Windows) ;; *) die "unsupported system: $OS" ;; esac

DEPS=$ROOT/deps                          # pristine sources (shared by every target)
PREFIX=$ROOT/build${TARGET:+-$TARGET}    # static libraries and headers
OBJ=$PREFIX/obj                          # out-of-tree build dirs
DIST=$ROOT/dist${TARGET:+-$TARGET}
EXE=; [ "$OS" = Windows ] && EXE=.exe

if [ "$HOST_OS" = Darwin ]; then
    JOBS=${JOBS:-$(sysctl -n hw.ncpu)}
    export MACOSX_DEPLOYMENT_TARGET=${MACOSX_DEPLOYMENT_TARGET:-12.0}
    export LIBTOOLIZE=${LIBTOOLIZE:-glibtoolize}   # Homebrew's libtool
    export CMAKE_POLICY_VERSION_MINIMUM=3.5        # CMake 4 refuses x265's old minimum version
    # some bootstrap scripts call libtoolize by name; Homebrew only installs it as glibtoolize
    if ! command -v libtoolize >/dev/null && command -v glibtoolize >/dev/null; then
        mkdir -p "$ROOT/build/tools" && ln -sf "$(command -v glibtoolize)" "$ROOT/build/tools/libtoolize"
        export PATH=$ROOT/build/tools:$PATH
    fi
else
    JOBS=${JOBS:-$(nproc)}
fi

sha256() { if command -v sha256sum >/dev/null; then sha256sum "$@"; else shasum -a 256 "$@"; fi; }
# in-place edit that works with GNU and BSD tools
edit() { perl -pi -e "$1" "$2"; }

# C++ runtime and extra system libraries for static linking
case "$OS" in
    Linux)   CXXLIB=-lstdc++ SYSLIBS="-lm -lpthread" ;;
    Darwin)  CXXLIB=-lc++    SYSLIBS="-lm -lpthread" ;;
    Windows) CXXLIB=-lc++    SYSLIBS="-lm -lpthread" ;;
esac

export PKG_CONFIG_LIBDIR=$PREFIX/lib/pkgconfig
export PKG_CONFIG_PATH=
export PATH=$PREFIX/bin:$PATH
if [ "$OS" = Windows ]; then
    # -fPIC means nothing for PE and clang rejects it for Windows targets
    export CFLAGS="-O2 -I$PREFIX/include" CXXFLAGS="-O2 -I$PREFIX/include"
else
    export CFLAGS="-O2 -fPIC -I$PREFIX/include" CXXFLAGS="-O2 -fPIC -I$PREFIX/include"
fi
export LDFLAGS="-L$PREFIX/lib"

# fetch_git <dir> <repo> <commit>: shallow checkout of exactly that commit (and its submodules)
fetch_git() {
    local d=$DEPS/$1
    [ "$(git -C "$d" rev-parse HEAD 2>/dev/null || true)" = "$3" ] && return 0
    log "download $1 @ ${3:0:12}"
    rm -rf "$d"
    git init -q "$d"
    git -C "$d" fetch -q --depth 1 "$2" "$3"
    git -C "$d" -c advice.detachedHead=false checkout -q FETCH_HEAD
    [ -f "$d/.gitmodules" ] && git -C "$d" submodule -q update --init --recursive --depth 1
    [ "$(git -C "$d" rev-parse HEAD)" = "$3" ] || die "$1: commit mismatch"
}

# fetch_git_dir <dir> <repo> <commit> <path>: only <path> of that commit (sparse, blobless), copied to deps/<dir>
fetch_git_dir() {
    local d=$DEPS/$1 t=$DEPS/.$1.git
    [ "$(cat "$d/.vexa-commit" 2>/dev/null || true)" = "$3" ] && return 0
    log "download $1 @ ${3:0:12}"
    rm -rf "$d" "$t"
    git init -q "$t"
    git -C "$t" remote add origin "$2"
    git -C "$t" fetch -q --depth 1 --filter=blob:none origin "$3"
    git -C "$t" sparse-checkout set --no-cone "/$4/"
    git -C "$t" -c advice.detachedHead=false checkout -q FETCH_HEAD
    [ "$(git -C "$t" rev-parse HEAD)" = "$3" ] || die "$1: commit mismatch"
    cp -a "$t/$4" "$d"
    echo "$3" >"$d/.vexa-commit"
    rm -rf "$t"
}

# fetch_tar <dir> <url> <sha256>
fetch_tar() {
    local d=$DEPS/$1 f=$DEPS/$1.tar
    [ -f "$d/.vexa-sha256" ] && [ "$(cat "$d/.vexa-sha256")" = "$3" ] && return 0
    log "download $1"
    curl -fsSL --retry 3 -o "$f" "$2"
    echo "$3  $f" | sha256 -c --quiet - || die "$1: sha256 mismatch"
    rm -rf "$d" && mkdir -p "$d"
    tar -xf "$f" -C "$d" --strip-components=1
    echo "$3" >"$d/.vexa-sha256"
    rm -f "$f"
}

fetch_all() {
    mkdir -p "$DEPS"
    fetch_git ffmpeg "$FFMPEG_REPO" "$FFMPEG_COMMIT"
    fetch_git_dir jellyfin-patches "$JELLYFIN_PATCHES_REPO" "$JELLYFIN_PATCHES_COMMIT" debian/patches
    fetch_git zlib "$ZLIB_REPO" "$ZLIB_COMMIT"
    fetch_git x264 "$X264_REPO" "$X264_COMMIT"
    fetch_git x265 "$X265_REPO" "$X265_COMMIT"
    fetch_git dav1d "$DAV1D_REPO" "$DAV1D_COMMIT"
    fetch_git opus "$OPUS_REPO" "$OPUS_COMMIT"
    fetch_git freetype "$FREETYPE_REPO" "$FREETYPE_COMMIT"
    fetch_git fribidi "$FRIBIDI_REPO" "$FRIBIDI_COMMIT"
    fetch_git harfbuzz "$HARFBUZZ_REPO" "$HARFBUZZ_COMMIT"
    fetch_git libunibreak "$LIBUNIBREAK_REPO" "$LIBUNIBREAK_COMMIT"
    fetch_git libxml2 "$LIBXML2_REPO" "$LIBXML2_COMMIT"
    fetch_git fontconfig "$FONTCONFIG_REPO" "$FONTCONFIG_COMMIT"
    fetch_git libass "$LIBASS_REPO" "$LIBASS_COMMIT"
    fetch_git zimg "$ZIMG_REPO" "$ZIMG_COMMIT"
    fetch_tar lame "$LAME_URL" "$LAME_SHA256"
    fetch_tar gperf "$GPERF_URL" "$GPERF_SHA256"
    if [ "$OS" = Windows ]; then
        fetch_tar libiconv "$LIBICONV_URL" "$LIBICONV_SHA256"
        case "$(uname -m)" in
            x86_64)          fetch_tar llvm-mingw "$LLVM_MINGW_X86_64_URL" "$LLVM_MINGW_X86_64_SHA256" ;;
            aarch64 | arm64) fetch_tar llvm-mingw "$LLVM_MINGW_AARCH64_URL" "$LLVM_MINGW_AARCH64_SHA256" ;;
            *)               die "no llvm-mingw for this host" ;;
        esac
    fi
}

# step <name> <version>: true when this step still has to run (a stamp records what was built)
step() {
    local s=$PREFIX/.stamps/$1
    [ "$(cat "$s" 2>/dev/null || true)" = "$2" ] && { log "$1: already built"; return 1; }
    log "build $1"
    return 0
}
done_step() { mkdir -p "$PREFIX/.stamps"; echo "$2" >"$PREFIX/.stamps/$1"; }

# a fresh copy of the pristine source to build in (autotools builds write into their source tree)
workdir() { rm -rf "$OBJ/$1"; mkdir -p "$OBJ"; cp -a "$DEPS/$1" "$OBJ/$1"; cd "$OBJ/$1"; }

MESON_COMMON=(--prefix="$PREFIX" --libdir=lib --buildtype=release --default-library=static)
AUTO_COMMON=(--prefix="$PREFIX" --libdir="$PREFIX/lib" --disable-shared --enable-static --with-pic)
CMAKE_COMMON=(-DCMAKE_INSTALL_PREFIX="$PREFIX" -DCMAKE_INSTALL_LIBDIR=lib -DCMAKE_BUILD_TYPE=Release)

# cross-compilation for Windows: llvm-mingw on PATH, plus the matching meson cross file and cmake settings
setup_cross() {
    [ -n "$CROSS" ] || return 0
    export PATH=$DEPS/llvm-mingw/bin:$PATH
    command -v "$CROSS-clang" >/dev/null || die "llvm-mingw not found"
    AUTO_COMMON+=(--host="$CROSS")
    mkdir -p "$PREFIX"
    cat >"$PREFIX/cross.meson" <<EOF
[binaries]
c = '$CROSS-clang'
cpp = '$CROSS-clang++'
ar = '$CROSS-ar'
ranlib = '$CROSS-ranlib'
strip = '$CROSS-strip'
windres = '$CROSS-windres'
pkg-config = 'pkg-config'

[host_machine]
system = 'windows'
cpu_family = '$CPU'
cpu = '$CPU'
endian = 'little'
EOF
    MESON_COMMON+=(--cross-file="$PREFIX/cross.meson")
    CMAKE_COMMON+=(-DCMAKE_SYSTEM_NAME=Windows -DCMAKE_SYSTEM_PROCESSOR="$CPU"
                   -DCMAKE_C_COMPILER="$CROSS-clang" -DCMAKE_CXX_COMPILER="$CROSS-clang++"
                   -DCMAKE_RC_COMPILER="$CROSS-windres" -DCMAKE_AR="$(command -v "$CROSS-ar")"
                   -DCMAKE_RANLIB="$(command -v "$CROSS-ranlib")" -DCMAKE_FIND_ROOT_PATH="$PREFIX"
                   -DCMAKE_FIND_ROOT_PATH_MODE_PROGRAM=NEVER -DCMAKE_FIND_ROOT_PATH_MODE_LIBRARY=ONLY
                   -DCMAKE_FIND_ROOT_PATH_MODE_INCLUDE=ONLY)
}

build_zlib() {
    step zlib "$ZLIB_COMMIT" || return 0
    workdir zlib
    if [ -n "$CROSS" ]; then
        CC=$CROSS-clang AR=$CROSS-ar RANLIB=$CROSS-ranlib CHOST=$CROSS ./configure --prefix="$PREFIX" --static
    else
        ./configure --prefix="$PREFIX" --static
    fi
    make -j"$JOBS" libz.a
    make install
    done_step zlib "$ZLIB_COMMIT"
}

# Windows has no iconv (glibc and macOS have it built in)
build_libiconv() {
    [ "$OS" = Windows ] || return 0
    step libiconv "$LIBICONV_SHA256" || return 0
    workdir libiconv
    ./configure "${AUTO_COMMON[@]}" --enable-extra-encodings --disable-nls
    make -j"$JOBS"
    make install
    done_step libiconv "$LIBICONV_SHA256"
}

build_x264() {
    step x264 "$X264_COMMIT" || return 0
    workdir x264
    local c=(--prefix="$PREFIX" --libdir="$PREFIX/lib" --enable-static --enable-pic --disable-cli
             --disable-lavf --disable-swscale --disable-opencl)
    [ -n "$CROSS" ] && c+=(--host="$CROSS" --cross-prefix="$CROSS-")
    ./configure "${c[@]}"
    make -j"$JOBS"
    make install-lib-static
    done_step x264 "$X264_COMMIT"
}

# 8-bit library with the 10- and 12-bit ones linked in (same layout as Jellyfin's builder)
build_x265() {
    step x265 "$X265_COMMIT" || return 0
    workdir x265
    grep -q '#include <cstdint>' source/dynamicHDR10/json11/json11.cpp ||
        edit 's/\A/#include <cstdint>\n/ if $. == 1' source/dynamicHDR10/json11/json11.cpp
    # without .git, x265 takes its version from x265Version.txt (the shallow checkout has no tags to describe)
    rm -rf .git
    local c=("${CMAKE_COMMON[@]}" -DENABLE_SHARED=OFF -DENABLE_CLI=OFF -DENABLE_ALPHA=ON)
    cmake "${c[@]}" -DHIGH_BIT_DEPTH=ON -DEXPORT_C_API=OFF -DENABLE_HDR10_PLUS=ON -DMAIN12=ON -S source -B 12bit
    cmake "${c[@]}" -DHIGH_BIT_DEPTH=ON -DEXPORT_C_API=OFF -DENABLE_HDR10_PLUS=ON -S source -B 10bit
    cmake --build 12bit -j"$JOBS"
    cmake --build 10bit -j"$JOBS"
    mkdir -p 8bit
    cp 12bit/libx265.a 8bit/libx265_main12.a
    cp 10bit/libx265.a 8bit/libx265_main10.a
    cmake "${c[@]}" -DEXTRA_LIB="x265_main10.a;x265_main12.a" -DEXTRA_LINK_FLAGS=-L. -DLINKED_10BIT=ON -DLINKED_12BIT=ON \
        -DENABLE_HDR10_PLUS=ON -S source -B 8bit
    cmake --build 8bit -j"$JOBS"
    (
        cd 8bit && mv libx265.a libx265_main.a
        if [ "$OS" = Darwin ]; then
            libtool -static -o libx265.a libx265_main.a libx265_main10.a libx265_main12.a
        else
            local ar=ar
            [ -n "$CROSS" ] && ar=$CROSS-ar
            "$ar" -M <<'EOF'
CREATE libx265.a
ADDLIB libx265_main.a
ADDLIB libx265_main10.a
ADDLIB libx265_main12.a
SAVE
END
EOF
        fi
    )
    cmake --install 8bit
    # x265 writes x265.pc only when git tags tell its version, and our shallow checkout has none
    local libs="$CXXLIB -lm -lpthread"
    [ "$OS" = Linux ] && libs="$libs -ldl"
    cat >"$PREFIX/lib/pkgconfig/x265.pc" <<EOF
prefix=$PREFIX
libdir=\${prefix}/lib
includedir=\${prefix}/include
Name: x265
Description: H.265/HEVC video encoder
Version: ${X265_COMMIT:0:12}
Libs: -L\${libdir} -lx265
Libs.private: $libs
Cflags: -I\${includedir}
EOF
    done_step x265 "$X265_COMMIT"
}

build_dav1d() {
    step dav1d "$DAV1D_COMMIT" || return 0
    workdir dav1d
    meson setup "${MESON_COMMON[@]}" -Denable_tools=false -Denable_tests=false build
    ninja -C build -j"$JOBS"
    ninja -C build install
    done_step dav1d "$DAV1D_COMMIT"
}

build_opus() {
    step opus "$OPUS_COMMIT" || return 0
    workdir opus
    ./autogen.sh   # also downloads Xiph's DNN model tarball (checked by sha256 inside the script)
    local c=(--disable-extra-programs --disable-doc)
    # Windows on arm64 has no run-time CPU detection in opus; NEON is always there anyway
    [ "$OS" = Windows ] && [ "$CPU" = aarch64 ] && c+=(--disable-rtcd)
    CFLAGS="$CFLAGS -O3" ./configure "${AUTO_COMMON[@]}" "${c[@]}"
    make -j"$JOBS"
    make install
    done_step opus "$OPUS_COMMIT"
}

build_lame() {
    step lame "$LAME_SHA256" || return 0
    workdir lame
    CFLAGS="$CFLAGS -DNDEBUG -Wno-error=incompatible-pointer-types" ./configure "${AUTO_COMMON[@]}" \
        --disable-gtktest --disable-frontend --disable-decoder
    make -j"$JOBS"
    make install
    done_step lame "$LAME_SHA256"
}

build_freetype() {
    step freetype "$FREETYPE_COMMIT" || return 0
    workdir freetype
    ./autogen.sh
    ./configure "${AUTO_COMMON[@]}" --without-harfbuzz --without-png --without-bzip2 --without-brotli --with-zlib=no
    make -j"$JOBS"
    make install
    done_step freetype "$FREETYPE_COMMIT"
}

build_fribidi() {
    step fribidi "$FRIBIDI_COMMIT" || return 0
    workdir fribidi
    meson setup "${MESON_COMMON[@]}" -Dbin=false -Ddocs=false -Dtests=false build
    ninja -C build -j"$JOBS"
    ninja -C build install
    edit 's/^Cflags:/Cflags: -DFRIBIDI_LIB_STATIC/' "$PREFIX/lib/pkgconfig/fribidi.pc"
    done_step fribidi "$FRIBIDI_COMMIT"
}

build_harfbuzz() {
    step harfbuzz "$HARFBUZZ_COMMIT" || return 0
    workdir harfbuzz
    meson setup "${MESON_COMMON[@]}" -Dfreetype=enabled -Dglib=disabled -Dgobject=disabled -Dcairo=disabled \
        -Dchafa=disabled -Dicu=disabled -Dtests=disabled -Dintrospection=disabled -Ddocs=disabled -Dutilities=disabled \
        -Dgpu=disabled -Dgdi=disabled -Ddirectwrite=disabled -Dcoretext=disabled build
    ninja -C build -j"$JOBS"
    ninja -C build install
    done_step harfbuzz "$HARFBUZZ_COMMIT"
}

build_libunibreak() {
    step libunibreak "$LIBUNIBREAK_COMMIT" || return 0
    workdir libunibreak
    ./bootstrap
    ./configure "${AUTO_COMMON[@]}"
    make -j"$JOBS"
    make install
    done_step libunibreak "$LIBUNIBREAK_COMMIT"
}

build_libxml2() {
    step libxml2 "$LIBXML2_COMMIT" || return 0
    workdir libxml2
    NOCONFIGURE=1 ./autogen.sh
    ./configure "${AUTO_COMMON[@]}" --without-python --without-zlib --without-lzma --without-icu --without-http \
        --without-debug --disable-maintainer-mode
    make -j"$JOBS"
    make install
    done_step libxml2 "$LIBXML2_COMMIT"
}

# build tool for fontconfig, installed into the prefix's bin (already on PATH); always built for the build machine
build_gperf() {
    command -v gperf >/dev/null && [ "$(command -v gperf)" != "$PREFIX/bin/gperf" ] && return 0
    step gperf "$GPERF_SHA256" || return 0
    workdir gperf
    # gperf 3.1 uses 'register', which clang rejects in C++17
    CFLAGS= CXXFLAGS=-std=gnu++11 LDFLAGS= ./configure --prefix="$PREFIX"
    make -j"$JOBS"
    make install
    done_step gperf "$GPERF_SHA256"
}

# Font lookup for burned-in subtitles. At run time it reads the system's /etc/fonts (FONTCONFIG_FILE can point elsewhere).
build_fontconfig() {
    step fontconfig "$FONTCONFIG_COMMIT" || return 0
    workdir fontconfig
    meson setup "${MESON_COMMON[@]}" --wrap-mode=nofallback --sysconfdir=/etc --localstatedir=/var -Ddoc=disabled \
        -Diconv=enabled -Dnls=disabled -Dxml-backend=libxml2 -Dtools=disabled -Dcache-build=disabled -Dtests=disabled build
    ninja -C build -j"$JOBS"
    # the install also writes /etc/fonts and /var/cache: stage it and keep only what lives under our prefix
    DESTDIR="$OBJ/fontconfig/stage" ninja -C build install
    cp -a "$OBJ/fontconfig/stage$PREFIX/." "$PREFIX/"
    done_step fontconfig "$FONTCONFIG_COMMIT"
}

build_libass() {
    step libass "$LIBASS_COMMIT+fc" || return 0
    workdir libass
    ./autogen.sh
    CFLAGS="$CFLAGS -Dread_file=libass_internal_read_file" ./configure "${AUTO_COMMON[@]}" \
        --enable-libunibreak --enable-fontconfig
    make -j"$JOBS"
    make install
    done_step libass "$LIBASS_COMMIT+fc"
}

build_zimg() {
    step zimg "$ZIMG_COMMIT" || return 0
    workdir zimg
    # mingw's header is windows.h, and the cross build runs on a case-sensitive file system
    [ "$OS" = Windows ] && grep -rl '<Windows.h>' src | while read -r f; do edit 's/<Windows\.h>/<windows.h>/' "$f"; done || true
    ./autogen.sh
    # zimg uses std::current_exception without including <exception>; libc++ (Windows, macOS) does not pull it in
    local cxx=$CXXFLAGS
    [ "$OS" = Linux ] || cxx="$cxx -include exception"
    CXXFLAGS=$cxx ./configure "${AUTO_COMMON[@]}"
    make -j"$JOBS"
    make install
    done_step zimg "$ZIMG_COMMIT"
}

# FFmpeg: the official release, then Jellyfin's patch series, then ours, on a fresh copy
prepare_ffmpeg() {
    local src=$OBJ/ffmpeg-src
    local sig ours=()
    shopt -s nullglob
    ours=("$ROOT"/patches/vexa/*.patch)
    shopt -u nullglob
    sig="$FFMPEG_COMMIT $JELLYFIN_PATCHES_COMMIT $(cat /dev/null "${ours[@]}" | sha256 | cut -c1-16)"
    [ "$(cat "$src/.vexa-patched" 2>/dev/null || true)" = "$sig" ] && return 0
    log "ffmpeg: applying patches"
    rm -rf "$src" "$OBJ/ffmpeg"
    mkdir -p "$OBJ"
    cp -a "$DEPS/ffmpeg" "$src"
    rm -rf "$src/.git"
    # like a release tarball: the version comes from VERSION (8.1.3), not from git
    cp "$src/RELEASE" "$src/VERSION"
    local n=0 p
    while read -r p; do
        [[ -z $p || $p == \#* ]] && continue
        patch -d "$src" -p1 --batch --forward --quiet <"$DEPS/jellyfin-patches/$p" || die "jellyfin patch failed: $p"
        n=$((n + 1))
    done <"$DEPS/jellyfin-patches/series"
    log "ffmpeg: $n patches from Jellyfin's series"
    for p in "${ours[@]}"; do
        patch -d "$src" -p1 --batch --forward --quiet <"$p" || die "vexa patch failed: $(basename "$p")"
        log "ffmpeg: $(basename "$p")"
    done
    echo "$sig" >"$src/.vexa-patched"
}

build_ffmpeg() {
    prepare_ffmpeg
    mkdir -p "$OBJ/ffmpeg" && cd "$OBJ/ffmpeg"
    [ "$CPU" = x86_64 ] && ! command -v nasm >/dev/null && die "nasm is needed for x86_64"
    local c=(--prefix="$PREFIX" --extra-version=Vexa --pkg-config-flags=--static
             --extra-cflags="-I$PREFIX/include" --extra-libs="$CXXLIB $SYSLIBS"
             --disable-shared --enable-static --disable-autodetect
             --disable-doc --disable-ffplay --disable-debug
             --enable-gpl --enable-version3
             --enable-zlib --enable-iconv
             --enable-libx264 --enable-libx265 --enable-libdav1d --enable-libopus --enable-libmp3lame
             --enable-libass --enable-libfontconfig --enable-libfreetype --enable-libfribidi --enable-libharfbuzz
             --enable-libzimg)
    case "$OS" in
        Linux)   c+=(--extra-ldflags="-L$PREFIX/lib -static") ;;
        Darwin)  c+=(--extra-ldflags="-L$PREFIX/lib" --cc=clang --cxx=clang++) ;;
        Windows) c+=(--extra-ldflags="-L$PREFIX/lib -static" --enable-cross-compile --target-os=mingw32
                     --arch="$CPU" --cross-prefix="$CROSS-" --cc="$CROSS-clang" --cxx="$CROSS-clang++"
                     --pkg-config=pkg-config) ;;
    esac
    "$OBJ/ffmpeg-src/configure" "${c[@]}"
    make -j"$JOBS"
    mkdir -p "$DIST"
    cp "ffmpeg$EXE" "$DIST/vexa-transcoder$EXE"
    cp "ffprobe$EXE" "$DIST/vexa-probe$EXE"
    local strip=strip
    [ -n "$CROSS" ] && strip=$CROSS-strip
    "$strip" "$DIST/vexa-transcoder$EXE" "$DIST/vexa-probe$EXE"
}

case "${1:-build}" in
    fetch) fetch_all ;;
    clean) rm -rf "$PREFIX" "$DIST" ;;
    build)
        fetch_all
        setup_cross
        mkdir -p "$PREFIX/lib/pkgconfig"
        build_zlib
        build_libiconv
        build_x264
        build_x265
        build_dav1d
        build_opus
        build_lame
        build_freetype
        build_fribidi
        build_harfbuzz
        build_libunibreak
        build_libxml2
        build_gperf
        build_fontconfig
        build_libass
        build_zimg
        build_ffmpeg
        cd "$ROOT"
        file "$DIST/vexa-transcoder$EXE" 2>/dev/null || true
        [ -z "$CROSS" ] && "$DIST/vexa-transcoder" -hide_banner -version | head -1
        log "done: $DIST/vexa-transcoder$EXE"
        ;;
    *) sed -n '2,17p' "$0"; exit 1 ;;
esac
