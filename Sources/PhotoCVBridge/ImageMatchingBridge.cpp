#include "ImageMatchingBridge.h"
#include <opencv2/core.hpp>
#include <opencv2/imgproc.hpp>
#include <opencv2/features2d.hpp>
#include <opencv2/calib3d.hpp>
#include <algorithm>
#include <cmath>
#include <cstring>
#include <limits>
#include <vector>

namespace {
constexpr int minimumEvidence = 12;
constexpr double ratioThreshold = 0.75;
constexpr double reprojectionThreshold = 3.0;

bool validInput(const uint8_t *data, size_t count, int width, int height, size_t stride) {
    return data && width > 0 && height > 0 && width <= 1600 && height <= 1600 &&
        stride >= static_cast<size_t>(width) * 4 &&
        stride <= std::numeric_limits<size_t>::max() / static_cast<size_t>(height) &&
        count >= stride * static_cast<size_t>(height);
}

struct Features {
    std::vector<cv::KeyPoint> keypoints;
    cv::Mat descriptors;
    double visibleArea = 0;
};

Features detect(const uint8_t *data, int width, int height, size_t stride) {
    cv::Mat rgba(height, width, CV_8UC4, const_cast<uint8_t *>(data), stride);
    cv::Mat gray, alpha, mask;
    cv::cvtColor(rgba, gray, cv::COLOR_RGBA2GRAY);
    cv::extractChannel(rgba, alpha, 3);
    // Premultiplied colours near transparency do not represent image content.
    // Erosion also prevents cutout/padding boundaries becoming match evidence.
    cv::threshold(alpha, mask, 249, 255, cv::THRESH_BINARY);
    const bool hasTransparency = cv::countNonZero(mask) != width * height;
    cv::erode(mask, mask, cv::getStructuringElement(cv::MORPH_RECT, cv::Size(7, 7)),
              cv::Point(-1, -1), 1, cv::BORDER_CONSTANT, cv::Scalar(0));
    Features result;
    result.visibleArea = cv::countNonZero(mask);
    if (result.visibleArea < 256) return result;
    auto sift = cv::SIFT::create(4000, 3, 0.03, 10, 1.6);
    sift->detectAndCompute(gray, mask, result.keypoints, result.descriptors);
    if (hasTransparency && !result.keypoints.empty()) {
        // A valid keypoint centre alone is not sufficient: the gradient support
        // of a large SIFT feature can still consist entirely of an alpha edge.
        // OpenCV's distance field excludes features whose scale reaches cutouts.
        cv::Mat distances;
        cv::distanceTransform(mask, distances, cv::DIST_L2, cv::DIST_MASK_PRECISE);
        std::vector<cv::KeyPoint> retained;
        cv::Mat descriptors;
        for (size_t i = 0; i < result.keypoints.size(); ++i) {
            const auto &keypoint = result.keypoints[i];
            const int x = std::clamp(cvRound(keypoint.pt.x), 0, width - 1);
            const int y = std::clamp(cvRound(keypoint.pt.y), 0, height - 1);
            if (distances.at<float>(y, x) < keypoint.size * 3.0) continue;
            retained.push_back(keypoint);
            descriptors.push_back(result.descriptors.row(static_cast<int>(i)));
        }
        result.keypoints = std::move(retained);
        result.descriptors = std::move(descriptors);
    }
    // SIFT retains equal-response ties beyond nfeatures. Bound the BF matcher
    // input explicitly so repeating textures cannot expand quadratic matching.
    if (result.keypoints.size() > 4000) {
        result.keypoints.resize(4000);
        result.descriptors = result.descriptors.rowRange(0, 4000).clone();
    }
    return result;
}

bool goodPair(const std::vector<cv::DMatch> &pair) {
    return pair.size() == 2 && pair[1].distance > 0 &&
        pair[0].distance < ratioThreshold * pair[1].distance;
}

struct Support {
    double area = 0;
    double fill = 0;
};
Support support(const std::vector<cv::Point2f> &points) {
    if (points.size() < 3) return {};
    std::vector<cv::Point2f> hull;
    cv::convexHull(points, hull);
    const double area = cv::contourArea(hull);
    const auto bounds = cv::boundingRect(hull);
    return {area, area / std::max(1.0, static_cast<double>(bounds.area()))};
}

int inlierCount(const cv::Mat &mask) {
    return mask.empty() ? 0 : cv::countNonZero(mask);
}
}

int32_t crossdiff_image_match_rgba(
    const uint8_t *leftRGBA, size_t leftByteCount, int32_t leftWidth,
    int32_t leftHeight, size_t leftStride,
    const uint8_t *rightRGBA, size_t rightByteCount, int32_t rightWidth,
    int32_t rightHeight, size_t rightStride,
    CrossDiffImageMatchCancellation cancellation, void *context,
    CrossDiffImageMatchResult *result, CrossDiffImageMatchPoint *points,
    size_t pointCapacity) {
    if (!result) return CrossDiffImageMatchFailure;
    *result = {};
    if (!validInput(leftRGBA, leftByteCount, leftWidth, leftHeight, leftStride) ||
        !validInput(rightRGBA, rightByteCount, rightWidth, rightHeight, rightStride) ||
        (pointCapacity != 0 && !points)) return CrossDiffImageMatchFailure;
    auto cancelled = [&]() { return cancellation && cancellation(context) != 0; };
    try {
        if (cancelled()) return CrossDiffImageMatchCancelled;
        const Features left = detect(leftRGBA, leftWidth, leftHeight, leftStride);
        result->left_feature_count = static_cast<int32_t>(left.keypoints.size());
        if (cancelled()) return CrossDiffImageMatchCancelled;
        const Features right = detect(rightRGBA, rightWidth, rightHeight, rightStride);
        result->right_feature_count = static_cast<int32_t>(right.keypoints.size());
        if (cancelled()) return CrossDiffImageMatchCancelled;
        if (left.keypoints.size() < minimumEvidence || right.keypoints.size() < minimumEvidence)
            return CrossDiffImageMatchInsufficientFeatures;

        cv::BFMatcher matcher(cv::NORM_L2);
        std::vector<std::vector<cv::DMatch>> forward, reverse;
        matcher.knnMatch(right.descriptors, left.descriptors, forward, 2);
        if (cancelled()) return CrossDiffImageMatchCancelled;
        matcher.knnMatch(left.descriptors, right.descriptors, reverse, 2);
        if (cancelled()) return CrossDiffImageMatchCancelled;
        std::vector<cv::Point2f> source, destination;
        for (const auto &pair : forward) {
            if (!goodPair(pair)) continue;
            const cv::DMatch &match = pair[0];
            const auto &back = reverse[match.trainIdx];
            if (!goodPair(back) || back[0].trainIdx != match.queryIdx) continue;
            source.push_back(right.keypoints[match.queryIdx].pt);
            destination.push_back(left.keypoints[match.trainIdx].pt);
        }
        result->candidate_count = static_cast<int32_t>(source.size());
        if (source.size() < minimumEvidence) return CrossDiffImageMatchInsufficientMatches;
        cv::Mat inliers;
        const cv::Mat transform = cv::estimateAffinePartial2D(source, destination, inliers,
            cv::RANSAC, reprojectionThreshold, 3000, 0.995, 10);
        if (cancelled()) return CrossDiffImageMatchCancelled;
        if (transform.empty()) return CrossDiffImageMatchUnreliable;
        result->inlier_count = inlierCount(inliers);
        const double a = transform.at<double>(0, 0), b = transform.at<double>(1, 0);
        const double tx = transform.at<double>(0, 2), ty = transform.at<double>(1, 2);
        const double scale = std::hypot(a, b);
        if (!std::isfinite(a) || !std::isfinite(b) || !std::isfinite(tx) ||
            !std::isfinite(ty) || scale < 0.05 || scale > 20)
            return CrossDiffImageMatchUnsupportedTransform;

        // An affine fit can diagnose a strong anisotropic/sheared candidate;
        // never silently approximate it with a plausible local similarity.
        cv::Mat affineInliers;
        const cv::Mat affine = cv::estimateAffine2D(source, destination, affineInliers,
            cv::RANSAC, reprojectionThreshold, 1500, 0.99, 10);
        if (cancelled()) return CrossDiffImageMatchCancelled;
        if (!affine.empty() && inlierCount(affineInliers) >= minimumEvidence &&
            inlierCount(affineInliers) > result->inlier_count * 1.35) {
            cv::SVD decomposition(affine(cv::Rect(0, 0, 2, 2)), cv::SVD::NO_UV);
            const double largest = decomposition.w.at<double>(0);
            const double smallest = decomposition.w.at<double>(1);
            if (smallest <= 0 || largest / smallest > 1.10 ||
                cv::determinant(affine(cv::Rect(0, 0, 2, 2))) <= 0)
                return CrossDiffImageMatchUnsupportedTransform;
        }
        if (result->inlier_count < minimumEvidence ||
            result->inlier_count < static_cast<double>(source.size()) * 0.45)
            return CrossDiffImageMatchUnreliable;

        std::vector<cv::Point2f> leftInliers, rightInliers, leftOther, rightOther;
        std::vector<double> residuals;
        for (size_t i = 0; i < source.size(); ++i) {
            if (inliers.at<uint8_t>(static_cast<int>(i))) {
                leftInliers.push_back(destination[i]); rightInliers.push_back(source[i]);
                residuals.push_back(std::hypot(a * source[i].x - b * source[i].y + tx - destination[i].x,
                                               b * source[i].x + a * source[i].y + ty - destination[i].y));
            } else {
                leftOther.push_back(destination[i]); rightOther.push_back(source[i]);
            }
        }
        std::sort(residuals.begin(), residuals.end());
        result->median_residual = residuals[residuals.size() / 2];
        const Support leftSupport = support(leftInliers), rightSupport = support(rightInliers);
        result->left_coverage = std::min(1.0, leftSupport.area / left.visibleArea);
        result->right_coverage = std::min(1.0, rightSupport.area / right.visibleArea);
        // A crop may occupy a small part of one side, but must explain a useful,
        // two-dimensional part of the other. Collinear/point-sized evidence fails.
        if (result->median_residual > 2.0 || leftSupport.area < 256 || rightSupport.area < 256 ||
            leftSupport.fill < 0.12 || rightSupport.fill < 0.12 ||
            std::min(result->left_coverage, result->right_coverage) < 0.003 ||
            std::max(result->left_coverage, result->right_coverage) < 0.12)
            return CrossDiffImageMatchUnreliable;

        // Two similarly supported but incompatible placements are ambiguous;
        // a global registration must not choose one pasted/repeated region silently.
        if (rightOther.size() >= minimumEvidence &&
            rightOther.size() >= static_cast<size_t>(result->inlier_count * 0.65)) {
            cv::Mat alternativeInliers;
            const cv::Mat alternative = cv::estimateAffinePartial2D(rightOther, leftOther,
                alternativeInliers, cv::RANSAC, reprojectionThreshold, 1500, 0.99, 10);
            if (!alternative.empty() && inlierCount(alternativeInliers) >= minimumEvidence &&
                inlierCount(alternativeInliers) >= result->inlier_count * 0.65)
                return CrossDiffImageMatchUnreliable;
        }
        if (cancelled()) return CrossDiffImageMatchCancelled;
        result->a = a; result->b = b; result->tx = tx; result->ty = ty;
        const size_t outputCount = std::min({pointCapacity, size_t(128), leftInliers.size()});
        std::vector<size_t> order(leftInliers.size());
        for (size_t i = 0; i < order.size(); ++i) order[i] = i;
        std::sort(order.begin(), order.end(), [&](size_t i, size_t j) {
            if (leftInliers[i].y != leftInliers[j].y) return leftInliers[i].y < leftInliers[j].y;
            return leftInliers[i].x < leftInliers[j].x;
        });
        for (size_t i = 0; i < outputCount; ++i) {
            const size_t index = order[i * order.size() / outputCount];
            points[i] = {leftInliers[index].x, leftInliers[index].y,
                         rightInliers[index].x, rightInliers[index].y};
        }
        result->point_count = static_cast<int32_t>(outputCount);
        return CrossDiffImageMatchAccepted;
    } catch (const cv::Exception &) {
        return CrossDiffImageMatchFailure;
    } catch (...) {
        return CrossDiffImageMatchFailure;
    }
}
