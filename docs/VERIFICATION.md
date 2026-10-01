# Verification record

Checked on 1 October 2026, Apple Silicon macOS 26.6.2, Apple Swift 6.3.2.
The package targets macOS 13+; the minimum OS and Intel architecture have
not been exercised. Fixtures are generated images, tones, video, text and
subtitles; proprietary app assets are excluded from this repository.

## Completed

- Debug app and CLI compile, including the interactive crop/framing views.
- `swift test`: **127 tests, zero failures**, including bounds, output naming,
  staging cleanup, cancellation, source changes, frame pixels, PDF resolution,
  subtitle parsing, media inspection and encoder availability.
- Release app bundle assembles, original icon generates, and local ad hoc
  signing succeeds. The bundle is not notarized or distributed as a release.
- Independent CLI checks: PNG → JPEG, Unicode TXT → PDF, PDF → JPEG,
  SRT → WebVTT, MOV → MP4, WAV → FLAC, ZIP creation.
- FFprobe confirms converted video contains video and audio; crop produces
  80×60 video with audio; precise trim produces one second.
- AVFoundation-only WAV → M4A and MOV → MP4 succeed when run normally on
  the host. The development sandbox initially blocked Apple media services.
- Framing produces a separate 544×408 image from a 480×320 input using
  32-pixel padding, rounded corners, shadow, solid colour and 4:3 canvas.
  The output was visually inspected. Image crop produces a separate copy.
- Repeat conversion preserves the first output and generates a suffixed name.
  Malformed PDF input fails without output. Absurd resize values return errors.
- All six original independent fixture SHA256 hashes remain unchanged;
  no abandoned job staging directories were found after failure checks.

## Pending

The current tool set lacks native computer-use controls, so **no live GUI
verification has been completed**: Finder Shift-drag, Shift+Option wheel,
editor handles and fields, progress/reveal, cancellation from the window,
background launch and multiple displays still need exercising. Compiling a
SwiftUI view does not validate its interactions.

A Mac Mini continuity snapshot taken while dependent files were being edited
failed compilation with missing helper symbols. All three symbols are present
in the final source and the complete revision builds on the authoritative Mac.
A fresh Mini build remains pending; the old snapshot is not a release artifact.

See [PARITY.md](PARITY.md) for observed product behaviour and remaining scope
such as gradients, collage, timed video redaction, audio visualizer, PDF → DOCX,
archive extraction and the unvalidated 188-conversion claim.

## Reproduce

```sh
swift test
bash scripts/build-app.sh --sign
.build/debug/orbitdrop-cli capabilities
.build/debug/orbitdrop-cli convert --to jpg /path/to/image.png
.build/debug/orbitdrop-cli tool --name image-frame \
  --options '{"padding":32,"cornerRadius":24,"shadow":50,"color":"#D9EEE9","aspect":"4:3"}' \
  /path/to/image.png
```

Optional media tests depend on a locally installed FFmpeg; unavailable engines
are reported or skipped. Image writers and media encoders are queried at runtime.
