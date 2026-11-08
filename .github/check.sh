#!/bin/sh
# Quick checks of a freshly built binary: static, our codecs and options present, and short encodes that work.
# Usage: .github/check.sh <path to vexa-transcoder> [run]   ("run" is skipped when the binary cannot run here)
set -eu
d=$1
case "$(uname -s)" in
    Linux)  file "$d" | grep -q 'statically linked' || { echo "not static: $d"; exit 1; } ;;
    Darwin) # only system libraries may be dynamic
            if otool -L "$d" | tail -n +2 | grep -v -E '^\s+(/usr/lib/|/System/Library/)'; then
                echo "non-system dynamic library in $d"; exit 1
            fi ;;
esac
$d -hide_banner -version | head -1
for e in libx264 libx265 libopus libmp3lame; do
    $d -hide_banner -encoders | grep -q " $e " || { echo "missing encoder $e"; exit 1; }
done
$d -hide_banner -decoders | grep -q ' libdav1d ' || { echo "missing decoder libdav1d"; exit 1; }
for o in segment_list_unfinished segment_list_separate_stream_times manifest_name skip_to_segment delete_removed \
         progressurl loglevel_server map_inlineass strict_ts; do
    $d -hide_banner -h full | grep -q -- "-$o" || { echo "missing option -$o"; exit 1; }
done
$d -hide_banner -filters | grep -q inlineass || { echo "missing filter inlineass"; exit 1; }
$d -hide_banner -loglevel error -f lavfi -i testsrc2=size=640x360:rate=24:duration=2 -f lavfi -i sine=duration=2 \
    -map 0:v -map 1:a -c:v libx264 -c:a libopus -f null -
$d -hide_banner -loglevel error -f lavfi -i testsrc2=size=640x360:rate=24:duration=2 -c:v libx265 -f null -
echo "checks passed"
