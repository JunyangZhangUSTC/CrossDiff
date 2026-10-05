# Photography normalization and default details — 0.15.0 build 37

Date: 2026-10-05. Apple silicon macOS; all development, fixtures, logs and bundles stayed in the main checkout. User-provided photograph originals were not available; reproductions use generated PNGs.

## Reproduction and cause

The reported `photography histogram normalization` error originates in strict host request validation. Its threshold and the equivalent JavaScript check remain unchanged.

A generated **8 × 1 PNG** containing RGBA `[255, 1, 1, 255]` reproduced the problem through `PhotoAnalysisEngine.load` and `analyze`: the saturation histogram summed to **0**, and `neutralFraction` was **1**, despite every pixel being saturated red. The original engine check failed before the production fix. A separate fixed-seed bridge probe with 131,072 valid samples and red fixed at 1 produced a saturation sum of **0.806640625** rather than 1.

Inspecting the pinned OpenCV 4.12 conversion distinguished the causes. Scalar conversion returned saturation 1; the SIMD path could return **1.00000012** because of floating-point evaluation order. That value reached the exclusive upper histogram edge and exceeded the chromatic mask's upper bound. Consequently, valid samples were both omitted from saturation bins and counted as neutral. RGB and lightness totals stayed correct, ruling out the shared valid-pixel denominator; the error existed before JSON or plugin execution.

The bridge now uses OpenCV `max`/`min` to restore H/L/S to their defined ranges immediately after conversion and before both masking and binning. The color conversion and histogram computation still use OpenCV. It does not renormalize a damaged histogram, relax validation, change neutral thresholds or alter source pixels. The library documents [HLS output ranges](https://docs.opencv.org/4.12.0/de/d25/imgproc_color_conversions.html) and [histogram range semantics](https://docs.opencv.org/4.12.0/d6/dc7/group__imgproc__hist.html).

## Default professional charts

New photography views start with the professional sections expanded. The native control can still hide/show them. Reanalysis, regions, language and appearance changes preserve a user's collapsed choice within the current view. No new persisted preference is introduced.

## Completed checks

| Check | Result |
| --- | --- |
| `bash scripts/tests/check-photo-engine.sh` | **124 checks passed**, including the real 8 × 1 PNG, 1,912 × 1,434 and 1,376 × 768 fixtures, transparent/partial-alpha samples, gradients, row blocks and regions, plus existing color-management/preview checks |
| `bash scripts/tests/check-photography-plugin.sh` | **35 checks passed**, preserving strict host and JavaScript validation |
| `bash scripts/tests/check-photo-workflow.sh` (build and native execution separately) | Passed: default expansion, collapse/reopen and retained choice; actual saturated PNG through the model and restricted plugin; channels/layouts, chart interactions, regions, persistence, XMP, stale-result protection and Base plugin installation |
| Native appearance | Default-expanded Chinese light/dark 860-point windows captured and visually reviewed; existing English and professional-section captures also completed |
| Source preservation | End-to-end PNG and existing image fixtures retain their source SHA-256 hashes |
| Full and Base builds | **0.15.0 build 37**, both passed `codesign --verify --deep --strict` |
| Publication scan | Configured heuristic checks passed for source candidates and the Full application; not a security certification |

The native workflow uses an isolated project-local data directory. Initial failing and corrected engine evidence lives in `.build-photo-checks/diagnostic/`; the standard engine result is `engine-final.log`. Native, plugin, packaging and audit logs use `.build/photo-normalization-*.log`. Default-expanded screenshots are `.build-photo-workflow/renders/photo-default-professional-{light,dark}-narrow.png`. These artifacts remain ignored.

This repair does not add RAW camera coverage, change photography format limits or modify the distributed plugin protocol. Minimum-system and Intel execution were not repeated. Applications are locally ad-hoc signed; no GitHub publication was performed for this change.
