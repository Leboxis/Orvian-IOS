# MobileVLCKit dependency and redistribution

## Reproducible dependency selection

[Podfile](<../Podfile>) pins **MobileVLCKit 3.7.4**, not a version range and not the
4.x alpha shown first on the CocoaPods landing page. It uses the official
CocoaPods Specs distribution, maintained by VideoLAN; no third-party SwiftPM
binary mirror is trusted. The official 3.7.4 source tag has no Package.swift.

Verified upstream metadata:

- [Official 3.7.4 podspec](https://raw.githubusercontent.com/CocoaPods/Specs/master/Specs/b/f/7/MobileVLCKit/3.7.4/MobileVLCKit.podspec.json)
- Artifact: https://download.videolan.org/pub/cocoapods/prod/MobileVLCKit-3.0-20260922-1512.tar.xz
- SHA-256 declared by that spec: `c649c4c47bd065b3a5511746361b5a9066a34033f2df9cbc9454409c0f363b52`
- Vendored product: `MobileVLCKit.xcframework`; Swift module: `MobileVLCKit`.
- The spec declares iOS 9+, VideoToolbox, OpenGLES, the other required Apple
  frameworks and C/C++ libraries. CocoaPods supplies linker settings; do not
  duplicate them manually in [project.yml](<../project.yml>).

On macOS, run `xcodegen generate`, then `pod install`, then build
`Orvian.xcworkspace` with scheme `Orvian`. Repeat `pod install` after regenerating
the project. CocoaPods is installed by Homebrew in both existing CI workflows;
all app/test builds use the workspace. Do not run a second CocoaPods/SPM copy of
VLCKit in the same target.

The exact pod version is pinned now. A genuine Podfile.lock must be generated
and committed from the first successful macOS `pod install`; none was fabricated
on Windows. After that, dependency updates must deliberately update both files.
The podspec SHA-256 protects the downloaded archive; the archive itself has not
been downloaded or inspected on this Windows host. macOS CocoaPods/XcodeGen
installation and Xcode linking remain to be validated without visual CI checks.

## Routing and user-visible limits

AVPlayer is always tried first. Only explicit AVFoundation `fileFormatNotRecognized`
(-11828) or `decoderNotFound` (-11833) errors enable VLC. Nested URL/authentication
errors and HTTP 4xx/5xx override these signals: they keep the existing native
retry path. Unknown, damaged-media and transient decoding failures are not
assumed to be codec incompatibility. File extensions do not select the engine.
After an incompatibility is confirmed, that viewer session keeps VLC for reloads.
Both engines use the same kDrive temporary signed HTTPS URL, never the account
bearer token. There is no local remux, transcode, or automatic full-file download.

VLC shares play/pause, seek, speed, mute, favorites and tag controls. Page departure,
backgrounding and audio interruptions pause/stop it through the existing lifecycle.
Opening/buffering is bounded to 20 seconds while playback is requested; a VLC
failure offers manual retry with a refreshed signed URL, not another engine switch.
The input/drawable stay retained until asynchronous stop completes. EOF replay
creates a fresh input rather than trying to reuse a dead one.

**VLC limitations:** native AirPlay video and the AVPlayer-specific automatic
speech/translation subtitles are disabled, with accessibility explanations.
Embedded VLC subtitles can render according to VLC defaults; no new track picker
is added here. Hardware acceleration is preferred, not guaranteed for all MPEG,
MKV codecs, profiles, or devices.

Nonvisual Windows validation: the Python regression suite and executable Swift
compatibility/controller checks pass. The controller harness uses controlled
libVLC stand-ins: it proves lifecycle and routing logic, not native binary linking,
decoding, rendering or energy use. The new hosted iOS policy tests additionally
check the actual Apple SDK error constants when run on macOS.

Before accepting playback on device, exercise a native MP4, MKV/H.264, MKV/HEVC,
MPEG-1/2 MPG, unsupported audio, invalid media, expired URLs, HTTP 403, airplane
mode, pause-before-opening, seeking, EOF replay, rapid paging and backgrounding.
Compare hardware decoding and battery use on physical iPhone, not a simulator.

## Playback API reference (3.7.4)

The public Objective-C headers and implementation were inspected at the exact
3.7.4 tag. Swift spellings below follow the Objective-C importer, but have not
been typechecked with the iOS SDK on Windows.

- `import MobileVLCKit`; `VLCMediaPlayer()` uses the shared VLCLibrary.
  `VLCMediaPlayer(options:)` creates a private library when options are nonempty
  and costs more memory.
- `VLCMedia(url: url)`; `media.addOption(":network-caching=1000")` or
  `media.addOptions(...)` before assigning/playing the media.
- `player.drawable = uiView` renders to a UIView. Keep it alive through stop.
- `player.time` and `player.media?.length` are VLCTime values in **milliseconds**;
  `VLCTime(int: milliseconds)` takes Int32, `intValue` returns Int32, and
  `value` is an optional NSNumber. `player.rate` is Float.
- `player.audio.isMuted` controls mute. Decoding continues while muted.
- `player.isSeekable` must be true before assigning time/position.
- VLCMediaPlayerDelegate uses `mediaPlayerStateChanged(_ notification:
  Notification)` and `mediaPlayerTimeChanged(_ notification: Notification)`.
  The player is `notification.object`; its `state` cases include `.stopped`,
  `.opening`, `.buffering`, `.ended`, `.error`, `.playing`, `.paused`.
  The default legacy events configuration dispatches asynchronously to main.
- **Stop is asynchronous in 3.7.4.** Retain the player and drawable until the
  `.stopped` event before clearing the drawable/delegate and releasing it.
  The implementation asserts that playback is stopped during deallocation.
- Hardware decoding is automatic where supported: VLC 3 declares `avcodec-hw`
  with default `any`. Do not set it to `none` or force software decoding.
  Automatic selection does not guarantee hardware support for every codec,
  profile, resolution or device. Real battery use needs a physical iPhone test.

Sources:
[VLCMediaPlayer.h](https://raw.githubusercontent.com/videolan/vlckit/3.7.4/Headers/Public/VLCMediaPlayer.h),
[VLCMediaPlayer.m](https://raw.githubusercontent.com/videolan/vlckit/3.7.4/Sources/VLCMediaPlayer.m),
[VLCMedia.h](https://raw.githubusercontent.com/videolan/vlckit/3.7.4/Headers/Public/VLCMedia.h),
[VLCTime.h](https://raw.githubusercontent.com/videolan/vlckit/3.7.4/Headers/Public/VLCTime.h),
[VLCAudio.h](https://raw.githubusercontent.com/videolan/vlckit/3.7.4/Headers/Public/VLCAudio.h),
[VLCEventsConfiguration.m](https://raw.githubusercontent.com/videolan/vlckit/3.7.4/Sources/VLCEventsConfiguration.m),
[VLC 3 hardware option](https://raw.githubusercontent.com/videolan/vlc/3.0.x/modules/codec/avcodec/avcodec.c).

## Notices and release checklist

MobileVLCKit and libVLC are Copyright VideoLAN and contributors, licensed under
GNU LGPL 2.1 or later, without warranty. The app's system Settings entry includes
a notice and source links. The post-build phase in
[project.yml](<../project.yml>) copies the **full CocoaPods-generated license
acknowledgements** into the Settings child pane; a missing generated license is
a build failure rather than silently shipping without it.

This notice is not a declaration of complete redistribution compliance. Before
publishing an IPA, review the [upstream licensing guidance](https://www.videolan.org/legal.html)
and [VLCKit license FAQ](https://github.com/videolan/vlckit/tree/3.7.4#faq):

1. Inspect the actual binary, license files, bundled codecs, source revisions,
   device/simulator architectures and privacy-manifest requirements. Preserve
   all required copyright and dependency notices.
2. Provide the exact corresponding sources, build instructions, modifications
   (if any), and any source offer required for that binary and its dependencies.
3. If the XCFramework is statically linked, fulfil the LGPL relinking obligations
   (for example suitable application object files/build materials); a source
   hyperlink alone is not enough. Validate the distribution/signing terms too.
4. Measure IPA size and memory impact and test LiveContainer compatibility.
   The XCFramework download contains more than the final device slice, but the
   additional decoder code still increases the shipped app. No size estimate
   or energy savings are claimed without measurements.
5. Compile both device Release and simulator tests on macOS. Do not trigger CI
   just for visual tests or screenshots. This integration did not trigger CI.
