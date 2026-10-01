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
const char *crossdiff_photo_opencv_version(void);
#ifdef __cplusplus
}
#endif
#endif
