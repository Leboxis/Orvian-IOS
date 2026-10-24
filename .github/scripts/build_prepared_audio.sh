#!/usr/bin/env bash
# Build private FFmpeg into a dynamic bridge; never link these archives into Orvian.
set -euo pipefail
export LC_ALL=C
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)
cd "$ROOT"
FFMPEG_VERSION=9.0.2
FFMPEG_SHA256=8c3850283eb25fa026482078a04051e0be17347b09ef81a0849bec15a96e002e
FFMPEG_TAG=946fcce07b6dcd0331c8cc609192aeff5e1924f8
NAME=OrvianAudioDecoder
NATIVE="$ROOT/Native/PreparedAudio"
VENDOR="$ROOT/Vendor"
OUTPUT="$VENDOR/$NAME.xcframework"
LEGAL="$VENDOR/$NAME-Settings.plist"
SOURCES="$VENDOR/$NAME-relink.tar.gz"
STAMP="$VENDOR/$NAME-build.sha256"
[[ $(uname -s) == Darwin ]] || { echo 'Apple Xcode/macOS is required.' >&2; exit 1; }
for tool in xcrun xcodebuild clang make curl tar shasum python3; do
    command -v "$tool" >/dev/null || { echo "Missing tool: $tool" >&2; exit 1; }
done
[[ -f "$NATIVE/$NAME.h" && -f "$NATIVE/$NAME.c" ]] || { echo 'Missing native bridge sources.' >&2; exit 1; }
mkdir -p "$VENDOR"
WORK=$(mktemp -d "$VENDOR/.prepared-audio.XXXXXX")
# Keep failed build evidence for diagnosis; successful builds remove only this verified temporary directory.
trap 'echo "Prepared audio build failed; evidence: $WORK" >&2' ERR
EXPORTS="$WORK/exports.txt"
printf '%s\n' _OADCancellationCreate _OADCancellationRetain _OADCancellationCancel _OADCancellationRelease \
    _OADOpen _OADRead _OADSeek _OADClose _OADDuration _OADVersion | sort > "$EXPORTS"
FINGERPRINT=$({ shasum -a 256 "$ROOT/.github/scripts/build_prepared_audio.sh" "$NATIVE/$NAME.h" "$NATIVE/$NAME.c" "$ROOT/docs/prepared-audio-decoder.md"; \
    xcodebuild -version; printf '%s\n' "$FFMPEG_VERSION" "$FFMPEG_SHA256" "$FFMPEG_TAG"; } | shasum -a 256 | awk '{print $1}')
verify_framework() {
    local binary="$1/$NAME"
    [[ -f "$binary" && -f "$1/Headers/$NAME.h" && -f "$1/Modules/module.modulemap" ]]
    xcrun nm -gUj "$binary" | sort > "$WORK/actual-exports.txt"
    diff -u "$EXPORTS" "$WORK/actual-exports.txt"
    # Exact export equality above also rejects every av*, swr* and ff_* symbol.
    xcrun otool -hv "$binary" > "$WORK/mach-header.txt"
    grep -q TWOLEVEL "$WORK/mach-header.txt"
    xcrun otool -L "$binary" > "$WORK/dependencies.txt"
    if grep -Ei 'libav|libswresample|VideoToolbox|AudioToolbox|libc\+\+|ffmpegkit|MobileVLC' "$WORK/dependencies.txt"; then
        echo 'Unexpected framework dependency.' >&2; return 1
    fi
}
if [[ -f "$STAMP" && -f "$LEGAL" && -f "$SOURCES" && $(< "$STAMP") == "$FINGERPRINT" ]]; then
    verify_framework "$OUTPUT/ios-arm64/$NAME.framework"
    verify_framework "$OUTPUT/ios-arm64-simulator/$NAME.framework"
    echo 'Prepared audio XCFramework is up to date (both export tables verified).'
    [[ "$WORK" == "$VENDOR"/.prepared-audio.* ]] && rm -rf -- "$WORK"
    exit 0
fi
ARCHIVE="$WORK/ffmpeg-$FFMPEG_VERSION.tar.xz"
curl --fail --location --retry 3 "https://ffmpeg.org/releases/ffmpeg-$FFMPEG_VERSION.tar.xz" -o "$ARCHIVE"
printf '%s  %s\n' "$FFMPEG_SHA256" "$ARCHIVE" | shasum -a 256 -c -
tar -xJf "$ARCHIVE" -C "$WORK"
SOURCE="$WORK/ffmpeg-$FFMPEG_VERSION"
RELINK="$WORK/relink"
mkdir -p "$RELINK/Native/PreparedAudio" "$RELINK/.github/scripts" "$RELINK/docs"
cp "$ARCHIVE" "$SOURCE/COPYING.LGPLv2.1" "$SOURCE/LICENSE.md" "$RELINK/"
cp "$NATIVE/$NAME.h" "$NATIVE/$NAME.c" "$RELINK/Native/PreparedAudio/"
cp "$ROOT/.github/scripts/build_prepared_audio.sh" "$RELINK/.github/scripts/"
printf 'FFmpeg %s\nSHA256 %s\nTag %s\nXcode:\n%s\n' "$FFMPEG_VERSION" "$FFMPEG_SHA256" "$FFMPEG_TAG" "$(xcodebuild -version)" > "$RELINK/BUILD.txt"
JOBS=$(sysctl -n hw.ncpu)
for SDK in iphoneos iphonesimulator; do
    TARGET=arm64-apple-ios26.0
    PLATFORM=iPhoneOS
    [[ "$SDK" != iphonesimulator ]] || { TARGET=arm64-apple-ios26.0-simulator; PLATFORM=iPhoneSimulator; }
    SYSROOT=$(xcrun --sdk "$SDK" --show-sdk-path)
    CC=$(xcrun --sdk "$SDK" --find clang)
    BUILD="$WORK/$SDK"
    PREFIX="$BUILD/install"
    FRAMEWORK="$BUILD/$NAME.framework"
    mkdir -p "$BUILD" "$FRAMEWORK/Headers" "$FRAMEWORK/Modules" "$RELINK/$SDK"
    (
        cd "$BUILD"
        "$SOURCE/configure" \
            --prefix="$PREFIX" --target-os=darwin --arch=aarch64 --enable-cross-compile \
            --cc="$CC" --sysroot="$SYSROOT" \
            --extra-cflags="-target $TARGET -fPIC" --extra-ldflags="-target $TARGET" \
            --disable-everything --disable-autodetect --disable-programs --disable-doc --disable-network \
            --disable-avdevice --disable-avfilter --disable-swscale \
            --disable-gpl --disable-nonfree --disable-version3 \
            --enable-static --disable-shared --enable-pic --enable-small --disable-debug \
            --disable-audiotoolbox --disable-videotoolbox --disable-avfoundation --disable-coreimage --disable-metal \
            --enable-demuxer=matroska,mpegps,mpegts --enable-protocol=file \
            --enable-decoder=aac,aac_latm,ac3,eac3,mp1,mp2,mp3,flac,vorbis,opus,alac,dca,truehd,mlp,pcm_s16le,pcm_s16be,pcm_s24le,pcm_s24be,pcm_s32le,pcm_s32be,pcm_f32le,pcm_f64le,pcm_dvd,pcm_bluray \
            --enable-parser=aac,aac_latm,ac3,mpegaudio,flac,vorbis,opus,dca,mlp --enable-zlib \
            2>&1 | tee configure-output.txt
        python3 - "$BUILD" <<'PY'
import pathlib, re, sys
build = pathlib.Path(sys.argv[1])
config = (build / 'config.h').read_text()
components = (build / 'config_components.h').read_text()
for option in ('GPL', 'NONFREE', 'VERSION3', 'NETWORK', 'AVDEVICE', 'AVFILTER', 'SWSCALE', 'AUDIOTOOLBOX', 'VIDEOTOOLBOX', 'AVFOUNDATION', 'COREIMAGE', 'METAL'):
    assert re.search(rf'^#define CONFIG_{option} 0$', config, re.M), option
assert not re.search(r'^#define CONFIG_\w+_(?:ENCODER|MUXER|HWACCEL) 1$', components, re.M), 'Unexpected encoder/muxer/hwaccel'
# Fail closed if a new configure dependency silently adds a video decoder.
allowed = set('aac aac_latm ac3 eac3 mp1 mp2 mp3 flac vorbis opus alac dca truehd mlp pcm_s16le pcm_s16be pcm_s24le pcm_s24be pcm_s32le pcm_s32be pcm_f32le pcm_f64le pcm_dvd pcm_bluray'.upper().split())
enabled = set(re.findall(r'^#define CONFIG_(\w+)_DECODER 1$', components, re.M))
assert enabled <= allowed, f'Unexpected decoders: {enabled - allowed}'
assert enabled, 'No audio decoders enabled'
PY
        make -j "$JOBS"
        make install
    )
    LIBS=()
    for LIB in avformat avcodec swresample avutil; do
        LIBS+=("-Wl,-load_hidden,$PREFIX/lib/lib$LIB.a")
        cp "$PREFIX/lib/lib$LIB.a" "$RELINK/$SDK/"
    done
    "$CC" -target "$TARGET" -isysroot "$SYSROOT" -std=c11 -O2 -fPIC \
        -I "$PREFIX/include" -I "$NATIVE" -c "$NATIVE/$NAME.c" -o "$BUILD/$NAME.o"
    # load_hidden localizes FFmpeg; the allowlist is an independent second boundary.
    # Do not add -flat_namespace, -undefined dynamic_lookup, -all_load or app-level static links.
    "$CC" -target "$TARGET" -isysroot "$SYSROOT" -dynamiclib \
        "$BUILD/$NAME.o" "${LIBS[@]}" -lz -lm -lpthread \
        -Wl,-exported_symbols_list,"$EXPORTS" \
        -Wl,-install_name,"@rpath/$NAME.framework/$NAME" \
        -Wl,-compatibility_version,1 -Wl,-current_version,1 \
        -o "$FRAMEWORK/$NAME"
    cp "$NATIVE/$NAME.h" "$FRAMEWORK/Headers/"
    printf 'framework module %s {\n  umbrella header "%s.h"\n  export *\n}\n' "$NAME" "$NAME" > "$FRAMEWORK/Modules/module.modulemap"
    python3 - "$FRAMEWORK/Info.plist" "$PLATFORM" "$NAME" <<'PY'
import plistlib, sys
path, platform, name = sys.argv[1:]
with open(path, 'wb') as output:
    plistlib.dump(dict(CFBundleExecutable=name, CFBundleIdentifier='com.orvian.audio-decoder', CFBundleName=name,
        CFBundlePackageType='FMWK', CFBundleShortVersionString='1.0', CFBundleVersion='1',
        MinimumOSVersion='26.0', CFBundleSupportedPlatforms=[platform]), output)
PY
    verify_framework "$FRAMEWORK"
    cp "$BUILD/$NAME.o" "$BUILD/config.h" "$BUILD/config_components.h" "$BUILD/configure-output.txt" "$RELINK/$SDK/"
    cp "$BUILD/ffbuild/config.log" "$RELINK/$SDK/"
    cp "$EXPORTS" "$RELINK/$SDK/"
done
xcodebuild -create-xcframework \
    -framework "$WORK/iphoneos/$NAME.framework" \
    -framework "$WORK/iphonesimulator/$NAME.framework" \
    -output "$WORK/$NAME.xcframework"
python3 - "$SOURCE/COPYING.LGPLv2.1" "$WORK/$NAME-Settings.plist" <<'PY'
import pathlib, plistlib, sys
notice = ('FFmpeg 9.0.2, Copyright FFmpeg contributors. GNU LGPL 2.1 or later; no warranty. '
          'Used only for local prepared-subtitle audio decoding, dynamically isolated from MobileVLCKit. '
          'Source: https://ffmpeg.org/releases/ffmpeg-9.0.2.tar.xz . '
          'Corresponding source, native bridge, build scripts and relink materials are supplied as '
          'OrvianAudioDecoder-relink.tar.gz alongside the Orvian release. '
          'You may modify this library and reverse engineer for debugging such modifications. '
          'Rebuilding/replacing the framework on iOS may require re-signing the application; '
          'see docs/prepared-audio-decoder.md in the corresponding Orvian source revision.')
license_text = pathlib.Path(sys.argv[1]).read_text()
with open(sys.argv[2], 'wb') as output:
    plistlib.dump({'PreferenceSpecifiers': [
        {'Type': 'PSGroupSpecifier', 'Title': 'FFmpeg / OrvianAudioDecoder', 'FooterText': notice},
        {'Type': 'PSGroupSpecifier', 'Title': 'GNU LGPL 2.1', 'FooterText': license_text}]}, output)
PY
cp "$ROOT/docs/prepared-audio-decoder.md" "$RELINK/docs/"
tar -czf "$WORK/$NAME-relink.tar.gz" -C "$RELINK" .
# All deletion targets are fixed absolute descendants of this repository's verified Vendor directory.
[[ "$OUTPUT" == "$ROOT/Vendor/OrvianAudioDecoder.xcframework" ]] || exit 1
if [[ -e "$OUTPUT" ]]; then rm -rf -- "$OUTPUT"; fi
mv "$WORK/$NAME.xcframework" "$OUTPUT"
mv "$WORK/$NAME-Settings.plist" "$LEGAL"
mv "$WORK/$NAME-relink.tar.gz" "$SOURCES"
printf '%s\n' "$FINGERPRINT" > "$STAMP"
[[ "$WORK" == "$VENDOR"/.prepared-audio.* ]] && rm -rf -- "$WORK"
echo "Built $OUTPUT and corresponding source/relink materials."
