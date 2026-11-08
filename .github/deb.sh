#!/bin/sh
# Packages dist/ as one .deb per distribution codename. The binary is static, so the packages differ only in name
# and version suffix (<name>_<ver>-<codename>_<arch>.deb).
# Usage: .github/deb.sh <version> <amd64|arm64> <output dir> <codename>...
set -eu
ver=$1 arch=$2 out=$3
shift 3
mkdir -p "$out"
for c in "$@"; do
    root=$(mktemp -d)
    mkdir -p "$root/DEBIAN" "$root/usr/lib/vexa-transcoder" "$root/usr/bin" "$root/usr/share/doc/vexa-transcoder"
    install -m 755 dist/vexa-transcoder dist/vexa-probe "$root/usr/lib/vexa-transcoder/"
    ln -s ../lib/vexa-transcoder/vexa-transcoder "$root/usr/bin/vexa-transcoder"
    ln -s ../lib/vexa-transcoder/vexa-probe "$root/usr/bin/vexa-probe"
    install -m 644 LICENSE "$root/usr/share/doc/vexa-transcoder/copyright"
    install -m 644 VERSIONS "$root/usr/share/doc/vexa-transcoder/VERSIONS"
    size=$(du -sk "$root/usr" | cut -f1)
    cat >"$root/DEBIAN/control" <<CTL
Package: vexa-transcoder
Version: $ver-$c
Architecture: $arch
Maintainer: VexaMedia <https://github.com/VexaMedia>
Installed-Size: $size
Section: video
Priority: optional
Homepage: https://github.com/VexaMedia/vexa-transcoder
Description: Vexa Transcoder (static FFmpeg build)
 FFmpeg built for Vexa Media, with its streaming extensions (segment lists, DASH
 resume, burned-in subtitles, progress and log reports to the server).
 Installs to /usr/lib/vexa-transcoder.
CTL
    dpkg-deb --root-owner-group -Zxz --build "$root" "$out/vexa-transcoder_$ver-${c}_$arch.deb" >/dev/null
    rm -rf "$root"
    echo "$out/vexa-transcoder_$ver-${c}_$arch.deb"
done
