#ifndef CROSSDIFF_PHOTO_CV_BRIDGE_H
#define CROSSDIFF_PHOTO_CV_BRIDGE_H
#include <stddef.h>
#ifdef __cplusplus
extern "C" {
#endif
/// RGBA floats in non-linear sRGB, unpremultiplied. Library clamps finite RGB
/// to the stated SDR analysis range; fully transparent/non-finite pixels are excluded.
/// Output is six consecutive histograms: R/G/B/L/S (256 each), H (360).
int crossdiff_photo_histograms(const float *rgba, int width, int height,
    double *histograms, size_t histogram_count, int *valid_count, double *neutral_fraction);
/// Legacy histograms plus 256 Lab L* bins spanning 0...100, appended at offset 1640.
int crossdiff_photo_histograms_v2(const float *rgba, int width, int height,
    double *histograms, size_t histogram_count, int *valid_count, double *neutral_fraction);
/// Bounded RGBA8 preview. Display channel: 0 original, 1 R, 2 G, 3 B.
/// Brush channel: -1 none, 0 Lab L*, 1 R, 2 G, 3 B. Bins are inclusive.
/// ROI uses the same row order as the input/output buffer; only it is highlighted.
/// Invalid/transparent input is excluded. The caller can process row blocks for cancellation.
int crossdiff_photo_preview(const float *rgba, int width, int height, int display_channel,
    int brush_channel, int lower_bin, int upper_bin, int roi_x, int roi_y, int roi_width, int roi_height,
    unsigned char *output, size_t output_count);
const char *crossdiff_photo_opencv_version(void);
#ifdef __cplusplus
}
#endif
#endif
