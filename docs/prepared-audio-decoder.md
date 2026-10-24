# Prepared-subtitle audio decoder build

## Boundary

`OrvianAudioDecoder` is a **dynamic** framework for extracting local audio for
prepared subtitles from Matroska/MKV, MPEG program streams and MPEG transport
streams. It is not a live playback engine, video decoder/encoder, network stack,
FFmpegKit replacement, or replacement for MobileVLCKit 3.7.4. Existing playback
continues to use CocoaPods' static MobileVLCKit.

The app imports only module `OrvianAudioDecoder` and its C header. No public
FFmpeg includes/types, app-level FFmpeg archives, extra C++ runtime, VideoToolbox,
GPL/nonfree/version-3 components, or video encoders are permitted. Canonical
private includes are `libavformat/...`, `libavcodec/...`, `libswresample/...` and
`libavutil/...` from the per-SDK installation, never flattened header copies.

The only exported C symbols (Mach-O adds an underscore) are:

- `OADCancellationCreate`, `OADCancellationRetain`, `OADCancellationCancel`, `OADCancellationRelease`
- `OADOpen`, `OADRead`, `OADSeek`, `OADClose`, `OADDuration`, `OADVersion`

The four PIC static archives (`avformat`, `avcodec`, `swresample`, `avutil`) are
inputs **only** to the dynamic framework link. Each uses Apple's
`-Wl,-load_hidden,<archive>`; an independent `-Wl,-exported_symbols_list,<file>`
allowlists exactly the bridge symbols. The default two-level namespace is retained
and checked. Do not add `-flat_namespace`, symbol reexports, or direct static
FFmpeg dependencies to the application: MobileVLCKit's private FFmpeg is a
separate, potentially ABI-incompatible implementation.

Reference: [Apple ld options](https://keith.github.io/xcode-man-pages/ld.1.html)
(`-load_hidden`, `-exported_symbols_list`, two-level namespace).

## Reproducible source and toolchain

- Official release: <https://ffmpeg.org/releases/ffmpeg-9.0.2.tar.xz>
- Version: **9.0.2**
- SHA-256: `8c3850283eb25fa026482078a04051e0be17347b09ef81a0849bec15a96e002e`
- Corresponding upstream tag commit: `946fcce07b6dcd0331c8cc609192aeff5e1924f8`
- Build entry point: `.github/scripts/build_prepared_audio.sh`
- Bridge sources: `Native/PreparedAudio/OrvianAudioDecoder.{h,c}`

The checksum is enforced on downloaded bytes before extraction. The release
archive is the build input; the tag is provenance, not a floating checkout.
Upstream FFmpeg sources are not patched. Configure options live in the script,
not in the app project or CocoaPods. Autodetection is disabled; the only external
library explicitly enabled is system zlib. Native audio decoders cover AAC/LATM,
AC-3/E-AC-3, MP1/2/3, FLAC, Vorbis, Opus, ALAC, DTS, TrueHD/MLP and the listed PCM
variants. Configure output is checked for licensing, unwanted components and
unapproved decoders before compilation.

Requires macOS, Xcode with iOS 26 SDKs, Apple command-line tools, make, curl, tar,
shasum and Python 3. Intel simulator builds are intentionally not included. CI
uses Apple Silicon macOS runners; do not select an x86_64 simulator destination.

```sh
bash .github/scripts/build_prepared_audio.sh
xcodegen generate
pod install
# Then build Orvian.xcworkspace normally.
```

The script builds separate out-of-tree `iphoneos` and `iphonesimulator` trees,
using `xcrun`'s clang and SDK paths, respectively targeting
`arm64-apple-ios26.0` and `arm64-apple-ios26.0-simulator`. It creates framework
binaries, headers, module maps and Info.plists, then runs
`xcodebuild -create-xcframework`. Output:

- `Vendor/OrvianAudioDecoder.xcframework`: device arm64 + simulator arm64;
  XcodeGen embeds the dynamic framework into the app.
- `Vendor/OrvianAudioDecoder-Settings.plist`: copyright/source notice plus the
  **complete, verbatim** `COPYING.LGPLv2.1` from the verified release archive.
  The app post-build phase copies it into `Settings.bundle/FFmpeg.plist` without
  replacing CocoaPods acknowledgements. Settings links both panes separately.
- `Vendor/OrvianAudioDecoder-relink.tar.gz`: exact upstream source archive,
  copyright/license files, bridge source, build script, this guide, per-SDK static
  archives and bridge object, configuration headers/logs, and exported symbols.
- `Vendor/OrvianAudioDecoder-build.sha256`: input/toolchain fingerprint.

All outputs are generated and gitignored. Failed builds retain their temporary
build directory under `Vendor/.prepared-audio.*` for config/link diagnostics.
Remove only the identified failed directory after diagnosis. To force a rebuild,
remove the generated fingerprint, then rerun the script.

All four existing CI workflows run the script **before every XcodeGen invocation**,
including the separate diagnostic job. Cache keys include script, native sources,
this guide, FFmpeg pin, runner architecture and Xcode version; no broad restore
key can restore a different version. A local fingerprint independently prevents
stale reuse. Even a cache hit rechecks both frameworks' exact export sets,
two-level namespace and forbidden dependencies.

## LGPL distribution and rebuilding

FFmpeg is copyright its contributors, licensed here under **LGPL 2.1 or later**,
without warranty. See [FFmpeg legal guidance](https://ffmpeg.org/legal.html) and
[the pinned LGPL text](https://raw.githubusercontent.com/FFmpeg/FFmpeg/946fcce07b6dcd0331c8cc609192aeff5e1924f8/COPYING.LGPLv2.1).
Other notices within the source archive must also be retained.

The release and diagnostic workflows attach the corresponding source/relink
archive alongside the IPA, including downloadable build artifacts. Any manual
redistributor must likewise supply that archive, the exact Orvian source revision,
and the notices with the binary, at the same download location. Do not distribute
an IPA alone or treat an expiring CI cache as a durable source offer. Preserve the
source/relink asset for as long as that binary is offered. If the upstream source
or bridge is modified, include those changes and prominent modification notices.

To rebuild from the relink archive, extract it into a new directory, ensure the
expected source layout is present, then run the included script on macOS. It
redownloads/verifies the upstream archive; for offline use extract the bundled
upstream archive and use the recorded configurations and four static archives.
The per-SDK bridge object and export list allow relinking an interface-compatible
replacement without recompiling the app. The link shape is:

```sh
# Set SDK=iphoneos or iphonesimulator and TARGET to the matching triple above.
# Run in the corresponding per-SDK relink directory.
xcrun --sdk "$SDK" clang -target "$TARGET" \
  -isysroot "$(xcrun --sdk "$SDK" --show-sdk-path)" -dynamiclib \
  OrvianAudioDecoder.o \
  -Wl,-load_hidden,libavformat.a -Wl,-load_hidden,libavcodec.a \
  -Wl,-load_hidden,libswresample.a -Wl,-load_hidden,libavutil.a \
  -Wl,-exported_symbols_list,exports.txt \
  -Wl,-install_name,@rpath/OrvianAudioDecoder.framework/OrvianAudioDecoder \
  -Wl,-compatibility_version,1 -Wl,-current_version,1 \
  -lz -lm -lpthread -o OrvianAudioDecoder
```

Replace the corresponding framework binary while preserving the public ABI,
module/header layout and install name. To modify bridge behavior, rebuild its
object from the supplied source against the modified FFmpeg headers first.
Recipients may modify the library and reverse engineer for debugging those
modifications. Dynamic isolation alone is **not** a claim of automatic LGPL or
App Store compliance: iOS signing/installation may prevent simply replacing an
embedded framework. A modified app/framework may need re-signing and an
appropriate installation method. Supply usable application source/object/relink
materials and obtain legal review of the intended distribution/signing channel;
do not impose terms forbidding the LGPL-granted modifications or debugging.
The bridge's independent licensing must also permit the distributed relink use.

## Validation limits

Preparation routes MKV/WebM, MPG/MPEG/VOB and TS/MTS/M2TS to this decoder;
other containers retain AVAssetReader. Only PCM is decoded, in bounded chunks
at the SpeechAnalyzer-requested rate/channel count. Buffer start times retain
media PTS, including initial delays and gaps; optional confidence rereads seek
and trim on the same timeline. Cancellation interrupts native I/O and closes
the decoder. Translated cue documents keep the existing account/file/version
cache and are displayed against VLC media time, without reprocessing playback.
Multiple audio tracks remain rejected rather than silently selecting a voice.

`PreparedAudioTests` runs without speech models or visual capture. Its tiny
bundled MPEG/Matroska fixtures were generated with FFmpeg 8.1.1 (the app decoder
still builds against the pinned version above):

```sh
ffmpeg -v error -f lavfi -i sine=frequency=800:sample_rate=48000:duration=0.2 -c:a mp2 -b:a 64k -f mpeg Tests/iOS/prepared-audio.mpg
ffmpeg -v error -f lavfi -i sine=frequency=800:sample_rate=44100:duration=0.2 -c:a flac -f matroska Tests/iOS/prepared-audio.mkv
ffmpeg -v error -f lavfi -i color=c=black:s=16x16:r=1:duration=3 -itsoffset 2 -f lavfi -i sine=frequency=800:sample_rate=44100:duration=0.2 -map 0:v -map 1:a -c:v mpeg4 -c:a flac -f matroska Tests/iOS/prepared-delay.mkv
```

They cover MPEG parser PTS interpolation, complete decode/drain, 44.1/48 kHz to
16 kHz resampling, seek after EOF, cancellation, PCM layout conversion and
range trimming without timestamp rebasing and a +2-second A/V audio delay.
They do not prove VLC clock alignment or cancellation of an already-running
native read: gaps, codec priming and transport stream discontinuities still
need representative device tests.

The script fails closed on incorrect downloaded bytes, unwanted configured
components, additional/missing exports, flat namespace, or forbidden shared
library dependencies. It checks both SDK slices even on reuse. These assertions
are the small executable build-contract checks; existing native/app tests remain
owned by the decoder implementation and are unchanged by build integration.

Windows can run `bash -n .github/scripts/build_prepared_audio.sh` and parse the
YAML/plists, but cannot build Mach-O/iOS binaries, inspect Apple's linker output,
run XcodeGen/CocoaPods, or prove device playback here. First macOS build and
simulator/device validation remain required. No visual capture, new CI dispatch,
or replacement server is part of this integration.
