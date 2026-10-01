# Parity checklist: OrbitDrop vs. Tangerine: File Converter

OrbitDrop is an independent, original implementation. This page records the
public evidence about *Tangerine: File Converter* (Leap Studio, maker
thameem, @th2049), how each observed feature maps to OrbitDrop, and how far
each OrbitDrop feature has actually been verified. Nothing from Tangerine —
source, assets, icons, layout or interface text — was copied, and the
proprietary app was never installed, run or decompiled.

## Evidence

All items below were located and inspected locally by the project
coordinator; the research material itself is kept outside this repository.

| Ref | What | Location |
| --- | --- | --- |
| E1 | Maker's announcement post, 1 October 2026, 10:13 AM, with the demo clip (21.504 s; the "0:17" in the screenshot that started this project is the remaining time, not the length) | https://x.com/th2049/status/2105662442789581202 |
| E2 | Official website demo video (22.5 s) | https://tangerineformac.com/videos/tangerine-demo.mp4 |
| E3 | Official press page and press screenshots | https://tangerineformac.com/press |
| E4 | Official tools page | https://tangerineformac.com/tools |
| E5 | Official homepage, format list and interactive example | https://tangerineformac.com |
| E6 | Mac App Store listing and description | https://apps.apple.com/us/app/tangerine-file-converter/id6813034065 |

What the evidence shows is behaviour visible in videos, screenshots and
marketing text. It is not the result of running the app, so anything about
Tangerine's internals stays unknown (see the end of this page).

## How OrbitDrop's own status is labelled

| Label | Meaning |
| --- | --- |
| **Auto** | Covered by the XCTest suite (core library; no UI). |
| **CLI** | Additionally exercised by hand through `orbitdrop-cli` by the coordinator on one Mac with ffmpeg installed. |
| **Code** | Implemented in the core library but not exercised by a test or by hand. |
| **GUI** | Implemented in the app; **not verified** — there are no UI tests and no recorded manual pass. |
| **Partial** | A narrower form exists; the difference is stated. |
| **Missing** | Not implemented. |

A label describes verification, not quality: "GUI" features remain unverified.
The coordinator compiled both executables and ran all 127 tests successfully
after adding the frame tool, editors and bounds checks. Real CLI framing,
cropping and rejected oversized resize requests were also exercised. A release
app bundle was built and signed locally. These checks do not verify Finder
gesture or editor interactions.

## Interaction (E1, E2)

| Tangerine | OrbitDrop | Status |
| --- | --- | --- |
| Shift while dragging a file summons a radial format wheel | Wheel of circular format chips centred on the cursor; own design (system material, teal/blue accent) | GUI |
| Dropping on a format converts and leaves the result beside the source (MOV → MP4; PDF → JPG as `Page 001.jpg`) | Same flow; outputs are named from the source (`clip.mp4`, `report-p01.jpg`), never overwriting | Conversion and naming: Auto + CLI. Drop gesture: GUI |
| Progress panel during conversion | Per-file progress in the main window, shown without taking focus; no separate floating panel | Partial, GUI |
| Shift+Option switches the wheel to tools | Option toggles the wheel between formats and tools | GUI |
| Tool editors open from the wheel and save a separate copy | Tools with parameters open a sheet in the window; every tool writes a new file | Separate copy: Auto. Sheets: GUI |
| Source and intermediate copies stay in place | Sources are read-only; changed sources abort the job | Auto + CLI (hashes) |
| Works with Finder drags | Only drags carrying real file URLs; file promises are ignored | Partial, GUI |

## Image tools (E1, E3, E4)

| Tangerine | OrbitDrop | Status |
| --- | --- | --- |
| Background/canvas editor: padding, corners, shadow, output ratio, colour and gradient swatches, image backgrounds, blur; saves a PNG | `image-frame`: unchanged image on a larger **solid-colour** canvas with padding, rounded corners, shadow and optional aspect ratio. Live-preview editor with sliders, colour picker and shape presets. No gradients, image backgrounds or blur; keeps the source format rather than forcing PNG | Algorithm: Auto + CLI. Editor: GUI. Partial |
| Crop: drag selection, free or preset aspect ratio, exact pixel dimensions; saves a copy | `image-crop`: interactive selection with corner handles, move, redraw, aspect presets and pixel fields for a single image; numeric form for batches and the CLI. Cut from original pixels | Crop: Auto. Editor: GUI |
| Compress with size target and simultaneous resize | `image-compress`: quality and longest-side limit. No target file size | Auto, Partial |
| Metadata: inspect, search, edit, remove | `image-strip-metadata` removes; `inspect` reports which blocks exist. No editing | Auto, Partial |
| Adjust: live preview, light, colour, detail, dehaze, clarity, grain, noise | `image-adjust`: brightness, contrast, saturation, exposure via numeric form. No live preview, no detail tools | Auto, Partial |
| Annotate | `image-annotate`: one line of text and outlined boxes by coordinates | Auto, Partial |
| Redact: multiple movable solid, blur or pixelate regions | `image-redact`: solid black regions by coordinates; metadata dropped | Auto, Partial |
| Collage (grid, row, column, featured) | — | Missing |
| QR reading | `image-read-codes` | Auto where Vision is available (the test skips otherwise) |
| Create PDF from images | `images-to-pdf` and image → PDF | Auto |
| (not shown) | `image-resize`, `image-rotate`, subject isolation in `image-background` (macOS 14+) | Auto; subject isolation is Code |

## Video tools (E1, E2, E4)

All need a user-installed ffmpeg unless noted.

| Tangerine | OrbitDrop | Status |
| --- | --- | --- |
| Crop editor: aspect ratio, dimensions, timeline; exact size, preserves audio | `media-crop`: numeric rectangle validated against the real frame size; audio kept. No editor | CLI (80×60 crop keeping audio); geometry check Auto. Partial |
| Trim with frame stepping, precise start/end | `media-trim`: numeric times, frame-accurate re-encode or keyframe copy; AVFoundation for MOV/MP4 without ffmpeg | CLI (1 s trim); Auto on audio when ffmpeg is installed. Partial |
| Speed, preserving pitch; silent video supported | `media-speed` with `atempo`; silent input detected by real inspection | Code |
| Join mixed MOV/MP4/MKV, first clip sets the canvas | `media-join` (concat filter, first clip sets size); cannot mix clips with and without sound | Code, Partial |
| Snapshots: exact frames, full-resolution PNG | `media-snapshot`: one frame per run | Code, Partial |
| Split at custom points or equal parts into a folder | `media-split`: equal segments at keyframes, files beside the source | Code, Partial |
| Compress | `media-compress` | Code |
| Mute | `media-mute` | Code |
| Metadata: per-file, track and chapter data | `media-strip-metadata`: removes container tags and chapters only | Code, Partial |
| Redact regions over time ranges | — | Missing |

## Audio tools (E3, E4)

| Tangerine | OrbitDrop | Status |
| --- | --- | --- |
| Waveform trim; trim leading/trailing silence | `media-trim` with numeric times; no waveform, no silence detection | Partial |
| Channels: mono/stereo, per-side gain, preview | `audio-channels`: mono, stereo, left, right, swap | Code, Partial |
| Bleep with editable intervals and before/after playback | `audio-bleep` with numeric intervals | Filter construction: Auto. Run: Code. Partial |
| Normalize with loudness range, true peak, level readout | `audio-normalize`: single-pass target loudness | Code, Partial |
| Visualizer video from audio | — | Missing |

## PDF and documents (E1, E4, E5)

| Tangerine | OrbitDrop | Status |
| --- | --- | --- |
| PDF → JPG/PNG, all pages at 300 DPI | Every page, 300 dpi by default, `dpi` configurable | Auto + CLI |
| PDF → TXT | Text extraction | Auto |
| PDF → DOCX | — | Missing |
| PDF merge in Finder selection order, reorder documents | `pdf-merge` in list order | Auto |
| PDF organize: visual reorder, rotate, duplicate, remove pages | `pdf-reorder`, `pdf-rotate`, `pdf-split` by page numbers; no visual page grid | Auto, Partial |
| TXT → PDF | Yes, plus RTF/DOC/DOCX/ODT ↔ each other and HTML output | Auto + CLI |
| TXT → JPG/PNG/SRT/VTT, image → DOCX | — | Missing |
| SRT / VTT / TXT | SRT ↔ WebVTT, either → TXT, `subtitle-shift` | Auto + CLI |
| (not shown) | `pdf-redact-rasterize`: every page rasterized, no text survives | Auto |

## Formats and scope (E5, E6)

| Tangerine | OrbitDrop | Status |
| --- | --- | --- |
| "188 conversion options" | Not matched. OrbitDrop's list depends on ImageIO and on the installed ffmpeg (`orbitdrop-cli list-formats`). The complete Tangerine pair list is not published, so the claim is **unvalidated** and no count comparison is made | — |
| "25 advanced tools", listed on the tools page | 35 tool identifiers with ffmpeg, 26 without. The numbers count different things; compare the tables above instead | — |
| Named formats include images, MP3, MOV, PDF, SVG, HEIC, ZIP, AVIF, WMA | Images incl. HEIC and AVIF where ImageIO allows, MP3/MOV/WMA through ffmpeg, PDF. **No SVG.** ZIP: create and list only | Partial |
| Compatible batch conversion | Target list is the intersection across the batch; unsupported files reported; already-converted files skipped | Auto |
| Progress windows, Finder reveal | Progress in the window; *Reveal* button | GUI |
| Free for 20 files, one-time unlock | Not a parity target; OrbitDrop is MIT-licensed | — |

## Present in OrbitDrop without a known Tangerine counterpart

`orbitdrop-cli`, `pdf-redact-rasterize`, `subtitle-shift`, archive creation
(`archive-zip`, `archive-tar`, `archive-tgz`, `archive-gzip`) and
`archive-list`. Whether Tangerine has equivalents is not known.

## Unknown about Tangerine

- Its internal engines, codec coverage, sandboxing and the permissions it
  requests; how its gesture is detected and whether it handles file promises
  or cloud-only files.
- The full 188-pair conversion matrix.
- Its behaviour on name collisions, cancellation, hostile or malformed input,
  encrypted PDFs and animated images. OrbitDrop's rules for these are its own
  engineering requirements, not observed Tangerine behaviour.

## OrbitDrop gaps, in one place

- **Unverified:** the entire GUI — window, wheel, crop and framing editors —
  and the AVFoundation video paths.
- **Editors:** only crop and framing are interactive. No live-preview adjust,
  no movable redaction or annotation regions, no blur/pixelate redaction, no
  gradient or image canvases, no video crop/trim editors, no waveform.
- **Tools:** no collage, video redaction, audio visualizer, silence trimming,
  metadata editing, compression to a target size, multi-frame snapshots or
  custom split points.
- **Formats:** no SVG, no PDF → DOCX, no text → image/subtitle, no
  image → DOCX, no HTML/EPUB/spreadsheet/presentation input, no OCR, no PDF
  compression or passwords, no archive extraction or conversion, no RAR/7z
  creation; animation is not preserved.
- **Platform:** no file-promise drags, no folder input, no floating progress
  panel; most media work needs a user-installed ffmpeg.
