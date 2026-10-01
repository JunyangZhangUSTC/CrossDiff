# 0.9.0 photography validation

Checked on 2026-10-02 using macOS 26.6.2, Apple silicon and Swift 6.3.3. This is a local source preview, not a claim that 0.9.0 has been published or tested on every supported macOS version. Sources, build dependencies, downloaded fixtures, isolated sessions, logs, captures and applications stayed inside the project. No user photographs or real sessions were used.

## Behavior and native windows

- `scripts/check.sh`: all existing core checks passed, including the 196 Unicode/newline fixture pairs, merging, deletion projection, copying, search/replacement, folder operations and session persistence.
- `check-photography-plugin.sh`: 35 checks passed against the actual restricted JavaScript process. Coverage includes bounded histogram inputs, bilingual findings, malformed output rejection, plugin compatibility, persisted region pairs and older sessions.
- `check-photo-metadata.sh`: actual ImageIO parsing passed for absent, embedded and explicit XMP curves, arbitrary namespace prefixes, invalid point ordering and DTD rejection. Additional checks cover the held-file boundary, bounded reads, cancellation, symlink/FIFO refusal and immutable source snapshots.
- `check-photo-workflow.sh`: the real photography creation route, source preparation, plugin execution, independent/linked selections, saved region groups, session serialization, explicit XMP, Base installation and unchanged source bytes passed. Replacing a source externally leaves the loaded pixels and curves consistent until Reload. Rapid selection changes keep the final result; cancelled non-cooperative work does not run concurrently with its successor.
- Ten full native-window captures cover the default panel and expanded HSL, recorded-curve and information panels, Chinese/English, light/dark and 860-point width. Parent-window composites were visually inspected for text, images, selections, shared chart scales and controls. The first restricted AppKit launch could not connect to native services; that test process was stopped and the same isolated test reran successfully with service access.
- Existing official-plugin UI checks passed in Chinese/English, light/dark and the 650-point minimum plugin-window width. Existing new-comparison workflow checks passed 123 assertions, including typed input preparation, plugin handoff, draft isolation and legacy pairing.
- The 19 Python release safeguard tests and seven inventory tests passed. Base/Full use the same catalog and matching independent Photography package, with the correct bundled-plugin sets.

## Image pipeline

The engine suite passed 43 assertions: 28 deterministic assertions and three assertions for each of five actual RAW fixtures. Tests exercise the pinned upstream OpenCV 4.12.0 implementation, RGB/HLS primary colors and neutral handling, exact upper histogram endpoints, transparent and non-finite samples, partial-alpha colors, P3 conversion through Apple color management, 16-bit input, EXIF orientation, top-left regions, bounded sampling and non-regular-file refusal.

Real RAW fixtures were decoded through Apple CIRAWFilter and analyzed as floating-point image data. The following dimensions describe these specific files and the decoder output, not every encoding offered by each camera:

| Fixture | Decoded dimensions | Source |
| --- | --- | --- |
| iPhone 6s Plus DNG | 4032 × 3024 | [raw.pixls.us, item 915](https://raw.pixls.us/getfile.php/915/nice/Apple%20-%20iPhone%206s%20Plus%20-%2016bit%20(4:3).DNG) |
| Nikon D2H NEF | 2464 × 1632 | [raw.pixls.us, item 5227](https://raw.pixls.us/getfile.php/5227/nice/Nikon%20-%20D2H%20-%2012bit%2012bit%20compressed%20(Lossy%20(type%201))%20(3:2).NEF) |
| Sony ILCE-7S ARW, APS-C crop | 2768 × 1848 | [raw.pixls.us, item 1582](https://raw.pixls.us/getfile.php/1582/nice/Sony%20-%20ILCE-7S%20-%2014bit%2014bit%20compressed%20(3:2).ARW) |
| Canon EOS 7D CR2 | 5184 × 3456 | [raw.pixls.us, item 131](https://raw.pixls.us/getfile.php/131/nice/Canon%20-%20EOS%207D%20-%20RAW%20(3:2).CR2) |
| Nikon NEF, ISS fixture | 4256 × 2832 | [rawpy test fixture](https://github.com/letmaik/rawpy/blob/main/test/iss030e122639.NEF) |

Fixtures remain ignored and are not distributed. Source provenance and SHA-256 hashes are kept with local fixtures; the first four were listed under CC0 in the source catalog. Engine logs are in `.build/photo-deps/engine-results.log`.

The real Nikon files exposed an ImageIO/CIRAWFilter integration issue: a generic TIFF identifier could select a thumbnail with no active RAW decoder. The implementation now supplies the camera RAW type when available and requires a real decoder. A normal TIFF renamed to NEF is rejected. RAW metadata also omits an ambiguous thumbnail bit depth instead of labeling it sensor precision.

## Build and delivery

Both Full (`dist/CrossDiff.app`) and Base (`dist/editions/base/CrossDiff.app`) built successfully as version 0.9.0/build 18 and passed `codesign --verify --deep --strict`. These are ad-hoc signatures, not Developer ID signing or notarization. The independent Photography 0.1.0 package is generated under `dist/plugins/`; bundled and standalone packages, catalogs, app metadata and all license files were checked byte-for-byte.

The final source/history and both application publication audits passed their configured patterns. An earlier audit caught local paths in OpenCV header diagnostics and generated build-information strings. Compiler path mapping and sanitizing CMake-generated metadata before compilation resolved this; no shipped binary was patched. The freshly linked library passed the 28 deterministic engine assertions again. Retained third-party notices describe the build changes. The audit is heuristic, not a guarantee of the absence of every sensitive value.

The release build emitted debug-module-cache lookup warnings from the toolchain after path mapping; compilation/linking completed and the stripped application signatures verified. An earlier build interrupted by a source-file save was discarded and repeated after the sources stabilized. There was no release upload, global dependency installation, or installation into Applications.

## Scope of the evidence

Statistics describe bounded sRGB SDR data; they are not sensor measurements, editing recipes or an assessment of photographic quality. The 4096-pixel analysis limit and 2048-pixel display limit are explicit. Recorded curves retain real metadata control points and do not reproduce a proprietary interpolation/rendering engine.

Intel, macOS 14/15 runtime behavior, every RAW camera/encoding, HDR interpretation, pathological long-running GPU/decoder faults, VoiceOver and extended everyday use remain outside this local validation. CI includes deterministic engine/metadata/plugin checks and compiles the native photography workflow; no new remote Actions run is claimed here. Published 0.9.0 download availability remains a release step.
