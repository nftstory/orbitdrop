# OrbitDrop

Early implementation: core operations are tested; live gesture and editor
interactions still await verification. Full Tangerine feature parity is not claimed.

OrbitDrop is a small, native macOS menu-bar utility that converts files
offline. Hold **Shift** while dragging files anywhere on screen and a radial
wheel of target formats appears at the cursor; drop on a chip and the
converted file is saved beside the original. A regular window with a file
list, format and tool pickers does the same job without the gesture, and
`orbitdrop-cli` exposes everything to scripts.

- macOS 13 or later, Swift 5.9+, AppKit and SwiftUI
- No third-party packages, no bundled binaries, no network access
- MIT licensed, original code and artwork

OrbitDrop is an independent project inspired by the idea of a drag-to-convert
wheel as shown publicly for *Tangerine: File Converter* (Leap Studio). It is
not affiliated with that product and shares no code, assets or interface text
with it. [docs/PARITY.md](docs/PARITY.md) lists the public evidence, compares
the two feature by feature, and separates what is automatically tested, what
was exercised by hand from the command line, what is implemented but not yet
verified in the GUI, and what is missing.

[Verification record](docs/VERIFICATION.md) documents the build and real-file checks.

## Build and run

```sh
swift build                      # debug build of the library, app and CLI
swift test                       # unit tests (no UI, no network)
swift run OrbitDrop              # run the menu-bar app from the terminal
swift run orbitdrop-cli help     # command-line usage

bash scripts/build-app.sh        # assemble dist/OrbitDrop.app (release)
bash scripts/build-app.sh --sign # same, plus an ad hoc code signature
```

`build-app.sh` writes only inside `.build/` and `dist/`. It creates the
bundle (`life.nftstory.orbitdrop`, `LSUIElement`), copies the CLI to
`Contents/Helpers/orbitdrop-cli`, and draws an icon natively when possible.
It does not install or launch anything.

## Using the app

**Menu bar.** The status item offers *Open OrbitDrop*, *Pause Shift-Drag
Monitor* and *Quit*. The first launch opens the converter window; if the app
was started in the background the window appears without taking the focus.
Afterwards the app stays in the menu bar; the menu item or opening the app
again brings the window forward and activates it.

**Window (always available).** Drop files on the window or use *Add Files…*.
Pick a target in *Convert to* and press *Convert*, or pick a *Tool* and press
*Run Tool…*, which shows a sheet with that tool's parameters. Each row shows
its status and progress; *Cancel* stops the batch, *Reveal* shows the outputs
in Finder. *Save to* switches between "beside each source" and a folder you
choose. Images and playable media get a preview.

**Image editors.** Two tools open an interactive editor instead of the plain
form. *Frame on Canvas* shows a live preview with sliders for padding, corner
rounding and shadow, a colour picker for the canvas and canvas-shape presets.
*Crop Image* (for a single image) shows the picture with a selection you can
move, resize by its corner handles or redraw, aspect presets, and exact pixel
fields. Both editors only collect settings: the result is produced from the
original, full-resolution pixels and saved as a separate copy. With several
images selected, cropping falls back to the numeric form.

**Shift-drag wheel (optional).** While dragging files from Finder or another
app, hold Shift. The wheel appears centred on the cursor and stays put so its
chips are reachable. Hold Option to switch the wheel to tools. Drop on a chip
to start; release anywhere else to do nothing. Tools that need parameters open
their sheet in the window.

The gesture uses passive `NSEvent` mouse monitors and polls the modifier
keys. It installs no event tap and requests no Accessibility, Input
Monitoring or other permission; if macOS does not deliver the events, the
wheel simply does not appear and the window remains fully usable. It can be
paused from the menu. A watchdog checks the real mouse-button state while a
drag is tracked, so a missed mouse-up cannot leave the wheel on screen.
Limits: only real file URLs on the drag pasteboard are recognised (no file
promises, so some apps' drags are ignored), and Escape dismisses the wheel
only while OrbitDrop itself is receiving key events.

## Command line

```sh
orbitdrop-cli inspect photo.heic clip.mov
orbitdrop-cli list-formats                 # everything offered on this Mac
orbitdrop-cli list-formats a.png b.pdf     # formats both files can become
orbitdrop-cli list-tools                   # every tool with its options
orbitdrop-cli convert --to jpg --options '{"quality":0.8}' *.png
orbitdrop-cli convert --to jpg report.pdf                       # every page, 300 dpi
orbitdrop-cli convert --to png --options '{"dpi":150}' report.pdf
orbitdrop-cli tool --name image-crop --options '{"x":0,"y":0,"width":640,"height":480}' shot.png
orbitdrop-cli tool --name image-frame --options '{"paddingPercent":10,"cornerPercent":6,"shadow":50,"color":"#1C7ED6","aspect":"16:9"}' shot.png
orbitdrop-cli tool --name pdf-reorder --options '{"order":"3,1,2"}' doc.pdf
orbitdrop-cli tool --name pdf-merge a.pdf b.pdf c.pdf
orbitdrop-cli tool --name archive-zip --output-dir ~/Desktop notes.txt photo.png
```

Output file URLs are printed to stdout, one per line; notes and errors go to
stderr. Exit status is 0 on success, 1 if any job failed or was cancelled,
2 for usage errors. `--ffmpeg PATH` selects an ffmpeg binary, `--ffmpeg none`
forces the native engines. Ctrl-C cancels cleanly.

## What it can do

A format or tool is offered only when it can actually run on the current
machine: image formats are queried from ImageIO at runtime, media formats
from the installed ffmpeg's encoder and muxer lists.

| Input | Convert to | Engine |
| --- | --- | --- |
| Images (PNG, JPEG, HEIC, TIFF, GIF, BMP, WebP, RAW, …) | PNG, JPEG, HEIC, TIFF, GIF, BMP, JPEG 2000, WebP, AVIF, ICO, PSD, TGA — each only if ImageIO reports it writable on this Mac; PDF | ImageIO, Core Graphics |
| PDF | PNG / JPEG / TIFF (one file per page at 300 dpi; `dpi` option 36–600), plain text | PDFKit, Core Graphics |
| TXT, Markdown (as text), RTF, DOC, DOCX, ODT | TXT, RTF, DOCX, ODT, DOC, HTML, PDF | NSAttributedString, Core Text |
| SRT, WebVTT | SRT, WebVTT, plain text | built-in parser |
| Video | MP4, MOV, MKV, WebM, GIF, and audio extraction | ffmpeg; without it MOV/MP4/M4V → MP4/MOV via AVFoundation |
| Audio | MP3, M4A, WAV, FLAC, Ogg Vorbis, Opus, AIFF | ffmpeg; without it common formats → M4A/WAV/AIFF via AVFoundation |

| Tools | Notes |
| --- | --- |
| `image-compress`, `image-strip-metadata`, `image-resize`, `image-crop`, `image-rotate`, `image-adjust`, `image-annotate`, `image-redact`, `image-frame`, `image-background`, `image-read-codes`, `images-to-pdf` | Native. `image-frame` puts the unchanged image on a larger solid canvas (padding, rounded corners, shadow, optional aspect ratio). `image-background` mode `remove` (subject isolation) needs macOS 14. |
| `pdf-merge`, `pdf-split`, `pdf-reorder`, `pdf-rotate`, `pdf-redact-rasterize` | Native. |
| `media-compress`, `media-trim`, `media-mute`, `media-crop`, `media-speed`, `media-snapshot`, `media-split`, `media-join`, `media-strip-metadata`, `audio-normalize`, `audio-channels`, `audio-bleep` | Need ffmpeg. Without it, `media-trim`, `media-mute` and `media-snapshot` remain for MOV/MP4/M4V through AVFoundation. |
| `subtitle-shift` | Native. |
| `archive-zip`, `archive-tar`, `archive-tgz`, `archive-gzip`, `archive-list` | System `ditto`, `tar`, `gzip`. |

Run `orbitdrop-cli list-tools` for every option of every tool.

In a batch, the format list is the intersection of what every supported file
can become. Files with no conversion are reported, not silently dropped, and a
file already in the target format is skipped.

## Safety model

- **Sources are read-only.** Inputs must be existing regular local files;
  folders, file promises and non-file URLs are rejected.
- **Nothing is overwritten.** Every job writes into a hidden
  `.orbitdrop-staging-<UUID>` folder next to its destination and commits each
  finished file with an exclusive operation: a hard link, or
  `renamex_np(RENAME_EXCL)` on volumes without hard links. If a volume
  supports neither, the job fails rather than risk replacing a file; a plain
  rename is never used. A taken name gets a counter: `photo.jpg`,
  `photo-2.jpg`, `photo-3.jpg`.
- **Output names come from the source's base name only**, plus a fixed tool
  suffix (`-cropped`, `-merged`, `-p01`, …). Options never influence paths,
  and only files inside the job's own staging folder can be committed.
- **Outputs are reopened before commit**: images through ImageIO, PDFs
  through PDFKit, media through ffprobe, or ffmpeg's own stream report when
  ffprobe is missing, or AVFoundation when there is no ffmpeg at all.
- **Each job is all-or-nothing.** On failure or cancellation the job's own
  staging folder and any of its own already-committed files are removed (a
  committed path is deleted only while it is still the file the job put
  there). Cancellation is checked for the last time immediately before the
  commit: a cancel that arrives after the engine finished but before commit
  does not commit and is reported as cancelled, never as success. The commit
  itself, a few link calls, is not interruptible.
- **Sizes are bounded.** Images and rendered pages are limited to 30 000
  pixels per side and 100 megapixels in total, checked from file headers and
  before any allocation; numeric options are validated as finite and in range
  before use.
- **Sound is not dropped silently.** A video container is offered only when
  the installed ffmpeg can also encode audio for it, and stream information
  always comes from real inspection of the file, never from a guess. GIF is
  the one explicit exception and the job notes that the sound was left out.
- **A batch is partial by design.** Files finished before a failure or a
  cancel stay; the rest are reported as failed or cancelled.
- **Changed sources are detected.** If a source's size, modification date or
  inode changes during a job, the job fails without saving.
- **Combined jobs** (merge, join, archive, images-to-PDF) are saved beside the
  first source unless an output folder is chosen.
- **Unwritable folders are reported** with the system's reason; choose
  another output folder in the window or with `--output-dir`.
- **No shell.** Helper programs (`ffmpeg`, `ffprobe`, `ditto`, `tar`, `gzip`)
  run with argument arrays, a minimal environment and no stdin. Cancelling
  terminates only the process OrbitDrop started. stdout and stderr are drained
  continuously.
- **ffmpeg input is restricted.** Every input gets
  `-nostdin -protocol_whitelist file,pipe`; playlists, concat scripts, SDP and
  similar stream descriptions are rejected by a header check and again by
  ffprobe's reported format. Joining uses the concat *filter*, never a script
  file. Outputs are relative names inside the staging folder.
- **Archives are never extracted.** OrbitDrop creates ZIP/TAR/TAR.GZ/GZ and
  lists contents; it does not unpack or convert archives.
- **Documents never run macros**, and HTML is write-only because importing
  HTML could fetch remote resources.
- **Redaction is real or not offered.** Image redaction writes new pixels and
  drops metadata. PDF redaction rasterizes *every* page and rebuilds the PDF
  from images, so no text layer survives; there is no "cover it with a box"
  PDF redaction.

A crash or power loss can leave a `.orbitdrop-staging-*` folder behind; it
contains only that job's partial output and can be deleted.

## Privacy

OrbitDrop makes no network connections, has no analytics and no update
check. Files are processed locally by system frameworks and, for media, by
the ffmpeg you installed. Preferences are three values in the app's own
defaults domain (monitor paused, first launch done, optional ffmpeg path).

## ffmpeg and third-party software

OrbitDrop contains no third-party code and does not bundle, download or
install ffmpeg. If you want the full media feature set, install ffmpeg
yourself (for example with Homebrew). OrbitDrop looks for it at a path you
configure (*Locate ffmpeg…*, `--ffmpeg`, or `ORBITDROP_FFMPEG`), then in
`/opt/homebrew/bin` and `/usr/local/bin`.

ffmpeg is licensed under the LGPL or GPL depending on how your copy was
built, and some codecs carry patent considerations. Those terms apply to your
ffmpeg installation, which OrbitDrop runs as a separate process; OrbitDrop's
MIT licence covers only OrbitDrop. H.264 output prefers the hardware
`h264_videotoolbox` encoder; when it is missing or fails, OrbitDrop falls
back to `libx264` or `mpeg4` and says so in the job's notes.

## Known limitations

- Animated images (GIF, APNG, HEIC sequences) and multi-page TIFFs: only the
  first frame is converted, and the job says so.
- Image tools produce 8-bit sRGB; wide-gamut or HDR data is converted.
  Formats without transparency are flattened onto white.
- Document → PDF uses simple Core Text pagination on US Letter: fonts and
  paragraphs carry over, images and text colours do not. Scanned PDFs have no
  extractable text and OCR is not included.
- Without ffmpeg there is no MKV/WebM/AVI support, no audio tools, and video
  conversion is limited to what AVFoundation can re-export.
- Stream-copy tools (`media-split`, non-precise trim, `media-mute`,
  `media-strip-metadata`) cut at keyframes and keep the source codecs.
- `media-join` re-encodes, scales every clip to the first clip's frame size,
  and cannot mix clips with and without sound.
- `media-strip-metadata` removes container tags and chapters; it does not
  rewrite data embedded inside the audio or video streams.
- Archive creation copies the inputs into the staging folder first
  (instant on APFS, a real copy on other volumes). Archive extraction,
  archive-to-archive conversion and RAR creation are not available.
- PDF pages too large for the pixel limit at 300 dpi are rendered at the
  highest resolution that fits, with a note; an explicitly requested `dpi`
  that does not fit is an error instead.
- Only cropping and framing have interactive editors. Annotate, redact,
  adjust and the media tools take numeric parameters; there is no waveform,
  timeline or on-video crop UI.
- The drag wheel shows at most ten chips; larger sets end with a chip that
  opens the window.
- Folders cannot be dropped; add the files inside them instead.

## Tests

`swift test` generates its own fixtures (a four-colour image, a text PDF, a
sine-wave WAV, subtitle and text files) and checks, among other things: pixel
dimensions and colours after convert/crop/rotate/redact, PDF page order and
text, rasterized redaction leaving no text, subtitle timestamp conversion,
no-overwrite collisions and concurrent commits, batch intersection and mixed
unsupported input, cancellation and failure cleanup, source-change detection,
malformed files, archive contents, process output draining and termination,
the ffmpeg argument builders, the frame tool's geometry, and the limits on
image, page, time and crop values. Tests open no UI and use no network. The
live ffmpeg test and the Vision QR test skip themselves where ffmpeg or
Vision is unavailable.

Verification status, stated plainly:

- **Automated:** the XCTest suite above (core library only).
- **Exercised by hand from the CLI** by the project coordinator on one Mac
  with ffmpeg: MOV → MP4, an 80×60 video crop that kept its audio, a
  one-second trim, WAV → FLAC, native WAV → M4A, TXT → PDF, PDF → JPG,
  SRT → VTT, name-collision outputs, and unchanged source hashes.
- **Not verified:** the GUI as a whole — the window, the Shift-drag wheel,
  the crop and framing editors, previews — and the AVFoundation video paths
  have no automated tests. Treat them as implemented but unproven until they
  are checked on your machine.

## Layout

```
Sources/OrbitCore      engines, safety layer, format and tool registries
Sources/OrbitDrop      menu-bar app, window, drag monitor, radial panel
Sources/orbitdrop-cli  command-line front end
Tests/OrbitCoreTests   XCTest suite
scripts/               build-app.sh, make-icon.swift
docs/PARITY.md         feature comparison and gaps
```

## License

MIT — see [LICENSE](LICENSE).
