# Image similarity regions

The **Similar Regions / 相似区域** toggle helps users inspect common content after Smart Align. It defaults off, remains visible until hidden and offers linked selection through numbered regions and previous/next buttons. Persistent evidence gives users time to inspect an area; a timed flash alone is easy to miss. Version 0.13.2 separates a dashed geometric extent from translucent verified content, so a crop reads as one corresponding portion instead of scattered texture islands. The overlays are view-only and never change alignment controls, pixel-difference results or source files.

## Evidence and presentation

Sparse SIFT correspondences establish the existing registration. They do not establish that every pixel inside their bounding box or convex hull is similar. The separate region analysis verifies local content using the accepted registration and immutable, oriented sRGB analysis images (longest edge at most 1600 pixels).

OpenCV `intersectConvexConvex` computes the intersection of the left source rectangle and the transformed right source rectangle (pixel-edge coordinates). Its at-most-eight vertices form a dashed extent, independent of alpha or content verification. This establishes where the images correspond geometrically, not that everything within is identical.

OpenCV `warpAffine` resamples the right image into left source coordinates. Each image must be opaque across a cell and its filtering footprint. Textured cells use OpenCV `matchTemplate` with `TM_CCOEFF_NORMED` plus RGB residual checks. If both sides are low-texture, a stricter absolute RGB check replaces normalized correlation, without compensating a brightness offset. Matching flat areas can join a region supported by at least three verified textured cells; they cannot independently establish a match. This keeps a correctly aligned screenshot’s equal background continuous without treating a constant-template correlation score as evidence. These operations use the existing OpenCV `core` and `imgproc` modules. See the upstream [geometric transformations](https://docs.opencv.org/4.12.0/da/d54/group__imgproc__transform.html) and [template matching API](https://docs.opencv.org/4.12.0/df/dfb/group__imgproc__object.html).

OpenCV `connectedComponentsWithStats` groups accepted cells with four-way connectivity. At least three verified textured seed cells are required per group; the largest twelve groups are retained, ordered by cell count. Regions retain their actual cells and holes. Display geometry removes shared cell edges to draw the outer and hole boundaries without an internal grid; labels sit inside a verified cell. No hull filling, bounding-box expansion or morphological closing inflates the verified fill. The separate dashed extent may enclose edits or transparent holes and must never be used as that fill. See the upstream [connected components API](https://docs.opencv.org/4.12.0/d3/dc0/group__imgproc__shape.html).

Each group is stored in left source coordinates with an inverse mapping to the right source. The geometric extent and content regions are both transformed with the current display geometry, including manual resizing, rotation and flips. Side by Side displays both counterparts; Wipe clips each side at the divider. Overlay and Pixel Difference use the selected image's evidence to avoid duplicate overlays. A restrained tint identifies regions, and the selected region has a stronger contour. There are no automatic flashing effects; selection animation respects Reduce Motion.

## Current bounds and thresholds

These are conservative product heuristics for preview inspection, not a calibrated similarity probability:

- Fixed-transform verification only, after an accepted global similarity registration. No new independent region transforms or semantic object recognition.
- Cell edge: `max(16, ceil(longest left-image edge / 40))`. Grid cells intersect the bounding rectangle of the valid alpha mask; each retained cell must remain entirely valid, have width and height at least 4 pixels and area at least 64 pixels. At most 1600 evaluated grid positions; bridge output capacity is bounded at 4096 cells. `comparedCellCount` counts all eligible cells, including flat candidates.
- Both alpha values must be at least 254/255; a 5×5 erosion keeps the filter footprint clear of transparent or cropped edges.
- Both RGB previews use a 5×5 Gaussian filter with sigma 0.8 to tolerate small resampling errors. Textured seeds require grayscale standard deviation at least 6/255 on both sides and normalized correlation at least 0.94. If both sides are below that deviation, maximum per-channel mean absolute RGB residual must be at most 1.5/255 and the maximum absolute channel residual at most 5/255. One flat and one textured side is rejected.
- For textured cells only, a neutral mean brightness offset up to 24/255 is allowed. RGB mean-offset spread must be at most 8/255 and residual channel standard deviations at most 9/255. After neutral-offset compensation, mean absolute channel residuals must be at most 6/255; pixels with any channel residual above 20/255 must cover at most 2.5% of the cell.

Small edits, fine details lost during thumbnailing and subtle color changes can remain inside a displayed region. Flat skies or backgrounds with meaningful color changes, or without connected texture support, can remain unmarked. The UI distinguishes geometric extent from similar content and explains that unmarked areas are inconclusive. It reports neither a whole-image similarity percentage nor “identical” areas. Wipe and Pixel Difference remain available for closer inspection.

## Lifecycle and verification

Analysis runs on demand in a cancellable background task, with serialized retries and a request identity check before publication. Hiding cancels unfinished work but retains completed evidence. A new automatic alignment, restoring the earlier alignment or reloading sources clears the cache and selection. Tab switching retains its model; manual transforms move existing source-coordinate overlays without rerunning analysis.

The C++ bridge checks cover exact screenshot crops with uniform backgrounds, separate geometric extents, strict low-texture color validation, fixed-transform crops, rotation/scale resampling, occlusion, alpha holes, brightness/color edits, unrelated images, flat/gradient inputs, cancellation, capacity, region limits and 1600-pixel inputs. Swift checks cover coordinate mapping, preserved holes, selection, caching and obsolete-result rejection. The full native image workflow exercises controls, source immutability and bilingual light/dark windows at normal and 860-pixel widths. Tests use project-local fixtures rather than user images.

## Crop regression

The 0.13.1 crop diagnostic established correct registration (0.000011-pixel median residual) but only 24.25% highlighted coverage and four fragments: 135 of 195 eligible cells were rejected for low texture even though their aligned RGB values matched exactly. The 0.13.2 regression verifies one continuous region, high total crop coverage and complete coverage away from safety margins, while edited or transparent cells stay unfilled. These generated fixtures are deterministic behavior checks, not a broad accuracy benchmark.
