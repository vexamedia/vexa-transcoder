# Vexa Transcoder

FFmpeg built for Vexa Media, with custom streaming and subtitle extensions. Based on the official **FFmpeg 8.1.3** release
and delivered as **a single static binary** (`vexa-transcoder`, plus `vexa-probe`) for Linux, Windows and macOS.
This repository holds only the recipe: the pinned versions, the build script and our patches. All source code is
downloaded at build time.

## Building
```bash
./build.sh                   # downloads (deps/), builds everything static (build/), outputs dist/vexa-transcoder and dist/vexa-probe
./build.sh fetch             # download only
./build.sh clean             # removes build/ and dist/ (keeps the downloads)
TARGET=win64 ./build.sh      # Windows x64, cross-compiled: dist-win64/vexa-transcoder.exe
TARGET=winarm64 ./build.sh   # Windows arm64: dist-winarm64/vexa-transcoder.exe
```
| Platform | How | Result |
|---|---|---|
| Linux x86_64 and arm64 | native | fully static binary, runs on any distribution |
| macOS x86_64 and arm64 | native (Xcode + Homebrew) | only the system's own libraries stay dynamic; macOS 12 or newer |
| Windows x64 and arm64 | cross-compiled on Linux with llvm-mingw (downloaded at the pinned version) | `.exe` that only uses Windows DLLs (UCRT) |

Requires: a C/C++ compiler, make, cmake, meson, ninja, autoconf/automake/libtool, pkg-config, git, curl, patch, perl;
and nasm for x86_64. pkg-config only sees the libraries built here: nothing from the system ends up in the binary by
accident.

## What goes in
| Component | Purpose |
|---|---|
| FFmpeg 8.1.3 + community patch series (106 patches) | the base, plus tonemapx (HDR→SDR on the CPU), Dolby Vision, AC-4, DTS:X, segment fixes, pausing |
| x264 | H.264, the main transcode format |
| x265 (8, 10 and 12 bit) | HEVC |
| dav1d | AV1 decoding |
| opus, LAME | Opus and MP3 audio |
| libass + freetype + fribidi + harfbuzz + libunibreak + fontconfig (libxml2) | burning subtitles into the video; fonts come from the system and from MKV attachments |
| zimg | color conversion and scaling (zscale) |
| zlib (and libiconv on Windows) | compression (MKV, PNG) and subtitle character set conversion |

The library versions are the ones pinned alongside that patch series, a combination that is tested together.

Left out on purpose: fdk-aac (license incompatible with the GPL; the native AAC encoder is enough and HE-AAC/xHE-AAC
are read by the native decoder), vvenc/vvdec (FFmpeg 8 decodes H.266 on its own; no player asks for H.266), dovi_tool
(Dolby Vision is handled by FFmpeg itself), and openssl (the transcoder only reads local files and talks to the server on
127.0.0.1).

## Updating
1. Pick the new FFmpeg release and the matching patch series tag; write both commits and `VEXA_VERSION` into `VERSIONS`.
2. Update each library's commit in `VERSIONS` to the one pinned for that series.
3. Run `./build.sh`, then the tests. If one of our patches no longer applies, adjust only that patch.

## Our patches (`patches/vexa/`)
Applied after the patch series, in name order. They add the options vexa-server uses and FFmpeg lacks:

| Patch | Options | What they do |
|---|---|---|
| `0001` segment muxer | `-segment_list_unfinished`, `-segment_list_separate_stream_times` | the (csv) list also carries the segment being written, prefixed with `#`, and the audio and video end times of each segment; this is how the server knows what is ready and paces the transcode |
| `0002` DASH muxer | `-manifest_name`, `-skip_to_segment`, `-delete_removed` | manifest sent to a URL; numbering starting mid-stream (resume); segments leaving the window stay on disk. With video, only video cuts segments (audio follows) |
| `0003` `inlineass` filter | `inlineass=...` (`font_size`, `outline`, `shadow`, `marginH`, `marginV`, `overrides`, `apply_overrides`, `font_name`, `font_path`, `fontconfig_file`, `fonts_dir`, `language`, `source`) | burns in the subtitle that `ffmpeg` itself decodes; sizes in 720p pixels |
| `0004` `ffmpeg` tool | `-map_inlineass`, `-progressurl`, `-loglevel_server`, `-strict_ts` | selects the burned-in subtitle; reports to the server (streams, duration and progress every 0.5 s via HTTP PUT); sends log lines to the server (POST to `<progressurl>/log`); `-strict_ts 0` lets a stream repeat the previous timestamp |
| `0005` Matroska demuxer | — | reads the track's IETF language tag (`LanguageBCP47`: `pt-BR`, `zh-Hans`) and prefers it over the legacy 3-letter one (`por`); an undetermined language stays `und`; this is what goes into the stream reports and the log |

Verified against the reference transcoder with the same commands: HLS segment list identical byte for byte, DASH
manifests identical (apart from timestamps), copied audio identical byte for byte, identical log messages and the same
burned-in subtitles (PSNR in the subtitle area equal to the rest of the frame). Known difference: FFmpeg 8's ASS muxer
writes LF line endings (previously CRLF).

## Prebuilt binaries
Every `v*` tag builds everything on GitHub Actions (`.github/workflows/build.yml`) and publishes it under **Releases**:

| File | Contents |
|---|---|
| `vexa-transcoder_<version>_portable_linux64-gpl.tar.xz` / `linuxarm64` | Linux x86_64 / arm64 |
| `vexa-transcoder_<version>_portable_win64-clang-gpl.zip` / `winarm64` | Windows x64 / arm64 |
| `vexa-transcoder_<version>_portable_mac64-gpl.tar.xz` / `macarm64` | macOS Intel / Apple Silicon |
| `vexa-transcoder_<version>-<distro>_<amd64\|arm64>.deb` | Debian bookworm/trixie and Ubuntu jammy/noble/resolute; installs to `/usr/lib/vexa-transcoder` |

Before publishing, each binary goes through quick tests (`.github/check.sh`: encoders, the options above, the
`inlineass` filter and a short H.264/HEVC/Opus encode); the Windows ones run on real Windows machines. The `.deb`
packages carry the same static binary; the distribution name is there only to follow the packaging convention.

## Releasing
1. Bump `VEXA_VERSION` in `VERSIONS` (`<FFmpeg version>-<revision>`), commit and push; wait for CI to pass on `main`.
2. Tag with the same number and push the tag:
   ```bash
   git tag -a v8.1.3-2 -m "Vexa Transcoder 8.1.3-2" && git push origin v8.1.3-2
   ```
3. CI builds all platforms again and, only if every job passes, publishes the release with all archives, the `.deb`
   packages and `SHA256SUMS`. To build everything without releasing: `gh workflow run build.yml`.

## Credits
FFmpeg by the FFmpeg developers (<https://ffmpeg.org>). The patch series applied before ours is maintained by the
Jellyfin project (<https://github.com/jellyfin/jellyfin-ffmpeg>, `debian/patches`); only those patch files are
downloaded, at the commit pinned in `VERSIONS`. Every library keeps its own license.

## License
The binary is **GPLv3** (text in `LICENSE`; `--enable-gpl --enable-version3`, because of x264/x265). This repository,
with the pinned versions and the patches, is the corresponding source.
