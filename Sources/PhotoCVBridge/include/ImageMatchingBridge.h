#ifndef CROSSDIFF_IMAGE_MATCHING_BRIDGE_H
#define CROSSDIFF_IMAGE_MATCHING_BRIDGE_H
#include <stddef.h>
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif

enum CrossDiffImageMatchStatus {
    CrossDiffImageMatchAccepted = 0,
    CrossDiffImageMatchInsufficientFeatures = 1,
    CrossDiffImageMatchInsufficientMatches = 2,
    CrossDiffImageMatchUnreliable = 3,
    CrossDiffImageMatchUnsupportedTransform = 4,
    CrossDiffImageMatchCancelled = 5,
    CrossDiffImageMatchFailure = 6
};

typedef int (*CrossDiffImageMatchCancellation)(void *context);

typedef struct {
    double left_x, left_y, right_x, right_y;
} CrossDiffImageMatchPoint;

typedef struct {
    // Coordinates are analysis-image pixels, origin at top left. Right -> left:
    // x' = a*x - b*y + tx; y' = b*x + a*y + ty.
    double a, b, tx, ty;
    int32_t left_feature_count, right_feature_count;
    int32_t candidate_count, inlier_count;
    double median_residual;
    // Convex-hull area of inliers / visible image area on each side.
    double left_coverage, right_coverage;
    int32_t point_count;
} CrossDiffImageMatchResult;

// Input is premultiplied RGBA8. Dimensions must be 1...1600; row_stride >= width*4.
// Byte counts must cover the declared image. Source buffers are never changed.
// Cancellation is checked between OpenCV stages, never during one OpenCV call.
// Correspondences are a spatially ordered sample of verified inliers (max 128).
// Output transform is valid only when the return value is Accepted. This bridge
// validates geometry; the caller must also check its renderer's supported range.
int32_t crossdiff_image_match_rgba(
    const uint8_t *left_rgba, size_t left_byte_count, int32_t left_width,
    int32_t left_height, size_t left_row_stride,
    const uint8_t *right_rgba, size_t right_byte_count, int32_t right_width,
    int32_t right_height, size_t right_row_stride,
    CrossDiffImageMatchCancellation cancellation, void *context,
    CrossDiffImageMatchResult *result, CrossDiffImageMatchPoint *points,
    size_t point_capacity);


// Only locally verified cells are returned. Coordinates are in the left analysis
// image, origin at top left; region IDs are contiguous and start at 1. A region
// may contain holes. Neither a bounding box nor an inlier hull is similarity.
typedef struct {
    int32_t x, y, width, height, region_id;
} CrossDiffImageSimilarityCell;

typedef struct {
    double x, y;
} CrossDiffImageSimilarityPoint;

typedef struct {
    int32_t cell_count, region_count, compared_cell_count;
    // Intersection of source boundaries [0,width] x [0,height] under the
    // accepted transform, independent of alpha or verified image content.
    // Up to eight vertices in left-image coordinates. This is NOT similarity.
    int32_t overlap_point_count;
    CrossDiffImageSimilarityPoint overlap[8];
} CrossDiffImageSimilarityResult;

// Input layout and coordinate conventions match crossdiff_image_match_rgba.
// Pass an already accepted right -> left similarity transform. This function
// verifies image content at that placement; it does not estimate a new transform.
// At most 4096 cells and 12 connected regions are returned. Matching flat
// content can extend a region supported by textured evidence; standalone flat
// images, transparency and substantial pixel changes are left unmarked.
// Edge cells may be smaller than the nominal grid after clipping to valid bounds.
// Accepted with no cells is a valid empty result, not proof of dissimilarity.
// Capacity must accommodate the complete output (4096 is always sufficient).
// Failure/cancellation leave result zeroed and never publish a partial mask.
int32_t crossdiff_image_similarity_rgba(
    const uint8_t *left_rgba, size_t left_byte_count, int32_t left_width,
    int32_t left_height, size_t left_row_stride,
    const uint8_t *right_rgba, size_t right_byte_count, int32_t right_width,
    int32_t right_height, size_t right_row_stride,
    double a, double b, double tx, double ty,
    CrossDiffImageMatchCancellation cancellation, void *context,
    CrossDiffImageSimilarityResult *result, CrossDiffImageSimilarityCell *cells,
    size_t cell_capacity);

#ifdef __cplusplus
}
#endif
#endif
