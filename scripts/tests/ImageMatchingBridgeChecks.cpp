#include "ImageMatchingBridge.h"
#include <opencv2/core.hpp>
#include <opencv2/imgproc.hpp>
#include <chrono>
#include <cmath>
#include <cstring>
#include <iostream>
#include <limits>
#include <vector>
#include <stdexcept>

namespace {
int assertions = 0;
void require(bool condition, const char *message) {
    ++assertions;
    if (!condition) throw std::runtime_error(message);
}
cv::Mat scene(int seed, int width = 900, int height = 700) {
    cv::Mat image(height, width, CV_8UC4, cv::Scalar(226, 230, 235, 255));
    cv::RNG rng(seed);
    for (int i = 0; i < 180; ++i) {
        const cv::Scalar color(rng.uniform(20, 230), rng.uniform(20, 230), rng.uniform(20, 230), 255);
        const cv::Point location(rng.uniform(12, width - 55), rng.uniform(12, height - 55));
        if (i % 3 == 0) cv::circle(image, location, rng.uniform(5, 24), color, 2, cv::LINE_AA);
        else if (i % 3 == 1) cv::rectangle(image, cv::Rect(location.x, location.y,
            rng.uniform(8, 45), rng.uniform(8, 45)), color, -1);
        else cv::putText(image, std::to_string(rng.uniform(0, 999)), location,
            cv::FONT_HERSHEY_SIMPLEX, 0.48, color, 1, cv::LINE_AA);
    }
    return image;
}
cv::Mat sparseScreenshot() {
    cv::Mat rgba(700, 900, CV_8UC4, cv::Scalar(236, 240, 244, 255));
    cv::RNG random(202610041);
    // Uniform screenshot-like background with separated marks of distinct shape,
    // colour and content. The right image below is an exact, unmodified crop.
    for (int item = 0; item < 110; ++item) {
        cv::Point point(random.uniform(30, 830), random.uniform(35, 655));
        cv::Scalar color(random.uniform(20, 160), random.uniform(20, 160), random.uniform(20, 160), 255);
        if (item % 3 == 0)
            cv::circle(rgba, point, random.uniform(7, 20), color, 2, cv::LINE_AA);
        else if (item % 3 == 1)
            cv::rectangle(rgba, cv::Rect(point.x, point.y, random.uniform(10, 35), random.uniform(8, 23)), color, -1);
        else
            cv::putText(rgba, std::to_string(random.uniform(0, 999)), point,
                        cv::FONT_HERSHEY_SIMPLEX, 0.46, color, 1, cv::LINE_AA);
    }
    return rgba;
}

struct Match {
    int status;
    CrossDiffImageMatchResult result{};
    CrossDiffImageMatchPoint points[128]{};
};
Match match(const cv::Mat &left, const cv::Mat &right,
            CrossDiffImageMatchCancellation callback = nullptr, void *context = nullptr) {
    Match output;
    output.status = crossdiff_image_match_rgba(left.ptr(), left.step * left.rows, left.cols, left.rows, left.step,
        right.ptr(), right.step * right.rows, right.cols, right.rows, right.step,
        callback, context, &output.result, output.points, 128);
    return output;
}
struct Similarity {
    int status;
    CrossDiffImageSimilarityResult result{};
    CrossDiffImageSimilarityCell cells[4096]{};
};
Similarity similarity(const cv::Mat &left, const cv::Mat &right,
                      double a = 1, double b = 0, double tx = 0, double ty = 0,
                      CrossDiffImageMatchCancellation callback = nullptr, void *context = nullptr) {
    Similarity output;
    output.status = crossdiff_image_similarity_rgba(left.ptr(), left.step * left.rows, left.cols, left.rows, left.step,
        right.ptr(), right.step * right.rows, right.cols, right.rows, right.step,
        a, b, tx, ty, callback, context, &output.result, output.cells, 4096);
    return output;
}
cv::Mat texture(int seed, int width = 480, int height = 384) {
    cv::Mat image(height, width, CV_8UC4);
    cv::RNG rng(seed);
    rng.fill(image, cv::RNG::UNIFORM, cv::Scalar(20, 20, 20, 255), cv::Scalar(230, 230, 230, 256));
    cv::GaussianBlur(image, image, cv::Size(5, 5), 1.1);
    return image;
}
bool intersects(const CrossDiffImageSimilarityCell &cell, const cv::Rect &rect) {
    return (cv::Rect(cell.x, cell.y, cell.width, cell.height) & rect).area() > 0;
}
double overlapArea(const CrossDiffImageSimilarityResult &result) {
    double twiceArea = 0;
    for (int index = 0; index < result.overlap_point_count; ++index) {
        const auto &point = result.overlap[index];
        const auto &next = result.overlap[(index + 1) % result.overlap_point_count];
        twiceArea += point.x * next.y - next.x * point.y;
    }
    return std::abs(twiceArea) / 2;
}
bool isZero(const CrossDiffImageSimilarityResult &result) {
    if (result.cell_count || result.region_count || result.compared_cell_count || result.overlap_point_count)
        return false;
    for (const auto &point : result.overlap) if (point.x != 0 || point.y != 0) return false;
    return true;
}
void verifySimilarity(const Similarity &output, int width, int height) {
    require(output.status == CrossDiffImageMatchAccepted, "local similarity must complete");
    require(output.result.cell_count >= 0 && output.result.cell_count <= 4096, "bounded cell count");
    require(output.result.region_count >= 0 && output.result.region_count <= 12, "bounded region count");
    require(output.result.compared_cell_count >= output.result.cell_count, "only verified cells may be published");
    require(output.result.overlap_point_count == 0 ||
        (output.result.overlap_point_count >= 3 && output.result.overlap_point_count <= 8), "bounded geometric polygon");
    for (int index = 0; index < output.result.overlap_point_count; ++index) {
        const auto &point = output.result.overlap[index];
        require(std::isfinite(point.x) && std::isfinite(point.y) &&
            point.x >= 0 && point.x <= width && point.y >= 0 && point.y <= height,
            "geometric overlap stays within continuous source bounds");
    }
    require(overlapArea(output.result) <= double(width) * height + 0.01, "geometric overlap area is bounded");

    cv::Mat covered = cv::Mat::zeros(height, width, CV_8UC1);
    std::vector<bool> regionSeen(output.result.region_count + 1, false);
    for (int i = 0; i < output.result.cell_count; ++i) {
        const auto &cell = output.cells[i];
        require(cell.x >= 0 && cell.y >= 0 && cell.width > 0 && cell.height > 0 &&
            cell.x + cell.width <= width && cell.y + cell.height <= height, "cell stays within source");
        require(cell.region_id >= 1 && cell.region_id <= output.result.region_count, "cell has valid region");
        const cv::Rect rect(cell.x, cell.y, cell.width, cell.height);
        require(cv::countNonZero(covered(rect)) == 0, "cells must not overlap");
        covered(rect).setTo(255);
        regionSeen[cell.region_id] = true;
    }
    for (int id = 1; id <= output.result.region_count; ++id)
        require(regionSeen[id], "region IDs are contiguous and nonempty");
}
void checkCompleteCrop() {
    const cv::Mat left = sparseScreenshot();
    const cv::Rect cropBounds(240, 180, 380, 310);
    const cv::Mat right = left(cropBounds).clone();
    const Match matched = match(left, right);
    require(matched.status == CrossDiffImageMatchAccepted, "sparse exact crop establishes reliable alignment");
    const auto output = similarity(left, right, matched.result.a, matched.result.b, matched.result.tx, matched.result.ty);
    verifySimilarity(output, left.cols, left.rows);
    cv::Mat highlighted = cv::Mat::zeros(left.size(), CV_8UC1);
    for (int index = 0; index < output.result.cell_count; ++index) {
        const auto &cell = output.cells[index];
        highlighted(cv::Rect(cell.x, cell.y, cell.width, cell.height)).setTo(255);
    }
    const cv::Rect interior(286, 226, 288, 218);
    const double coverage = double(cv::countNonZero(highlighted(cropBounds))) / cropBounds.area();
    const double interiorCoverage = double(cv::countNonZero(highlighted(interior))) / interior.area();
    std::cout << "sparse screenshot exact crop: regions=" << output.result.region_count
              << " cells=" << output.result.cell_count << " coverage=" << coverage
              << " interior_coverage=" << interiorCoverage << '\n';
    require(output.result.region_count == 1 && coverage >= 0.90 && interiorCoverage >= 0.99,
            "exact crop includes its matching uniform background in one continuous region");
    require(output.result.overlap_point_count == 4 && std::abs(overlapArea(output.result) - cropBounds.area()) < 1,
            "exact crop geometric outline covers the complete source boundary");
    for (int index = 0; index < output.result.overlap_point_count; ++index) {
        const auto &point = output.result.overlap[index];
        require(point.x >= cropBounds.x - 0.01 && point.x <= cropBounds.br().x + 0.01 &&
            point.y >= cropBounds.y - 0.01 && point.y <= cropBounds.br().y + 0.01,
            "crop geometric outline agrees with aligned source position");
    }
    const auto reverseMatch = match(right, left);
    require(reverseMatch.status == CrossDiffImageMatchAccepted, "reversed exact crop aligns");
    const auto reverse = similarity(right, left, reverseMatch.result.a, reverseMatch.result.b,
        reverseMatch.result.tx, reverseMatch.result.ty);
    verifySimilarity(reverse, right.cols, right.rows);
    require(reverse.result.region_count == 1 && std::abs(overlapArea(reverse.result) - cropBounds.area()) < 1,
            "full image on right produces the same complete geometric crop boundary");
    cv::Mat reverseMask = cv::Mat::zeros(right.size(), CV_8UC1);
    for (int index = 0; index < reverse.result.cell_count; ++index) {
        const auto &cell = reverse.cells[index];
        reverseMask(cv::Rect(cell.x, cell.y, cell.width, cell.height)).setTo(255);
    }
    require(cv::countNonZero(reverseMask) >= cropBounds.area() * 0.90,
            "reversed sparse crop retains matching uniform background");

    // The original colour is uniform but now has nearby strong texture seeds.
    // Changing that colour must still create a real hole in the accepted region.
    cv::Mat flatPatchSource = left.clone();
    const cv::Rect edit(92, 92, 92, 92);
    flatPatchSource(cv::Rect(cropBounds.tl() + edit.tl(), edit.size())).setTo(cv::Scalar(236, 240, 244, 255));
    cv::Mat changed = flatPatchSource(cropBounds).clone();
    cv::add(changed(edit), cv::Scalar(-12, -12, -12, 0), changed(edit));
    const auto withDarkPatch = similarity(flatPatchSource, changed, 1, 0, cropBounds.x, cropBounds.y);
    verifySimilarity(withDarkPatch, left.cols, left.rows);
    require(withDarkPatch.result.cell_count > 100, "crop still has similar content around a local brightness edit");
    const cv::Rect changedCenter(cropBounds.x + edit.x + 23, cropBounds.y + edit.y + 23,
                                edit.width - 46, edit.height - 46);
    for (int index = 0; index < withDarkPatch.result.cell_count; ++index)
        require(!intersects(withDarkPatch.cells[index], changedCenter),
                "uniform brightness edit cannot be erased by per-cell compensation");

}
void checkSimilarity() {
    const cv::Mat left = texture(891027);
    const cv::Mat unchanged = left.clone();
    const Similarity identical = similarity(left, left);
    verifySimilarity(identical, left.cols, left.rows);
    require(identical.result.cell_count > 500 && identical.result.region_count == 1,
            "identical textured images have a substantial connected region");
    require(identical.result.overlap_point_count == 4 &&
            overlapArea(identical.result) == double(left.cols) * left.rows,
            "identity geometric bounds use width and height, not last-pixel indices");

    cv::Mat brighter;
    cv::add(left, cv::Scalar(12, 12, 12, 0), brighter);
    const auto brightness = similarity(left, brighter);
    verifySimilarity(brightness, left.cols, left.rows);
    require(brightness.result.cell_count >= identical.result.cell_count * 0.98,
            "small neutral brightness shifts remain comparable");

    const cv::Rect edit(144, 112, 128, 128);
    cv::Mat occluded = left.clone();
    occluded(edit).setTo(cv::Scalar(45, 150, 215, 255));
    const auto withHole = similarity(left, occluded);
    verifySimilarity(withHole, left.cols, left.rows);
    require(withHole.result.cell_count > 300 && withHole.result.region_count == 1,
            "occlusion leaves connected verified content around it");
    for (int i = 0; i < withHole.result.cell_count; ++i)
        require(!intersects(withHole.cells[i], edit), "occlusion hole must never be filled by a bounding box");
    cv::Mat recolored = left.clone();
    cv::add(recolored(edit), cv::Scalar(50, 0, 0, 0), recolored(edit));
    const auto withRecolor = similarity(left, recolored);
    require(withRecolor.result.cell_count > 300, "unmodified content around colour edit remains verified");
    for (int i = 0; i < withRecolor.result.cell_count; ++i)
        require(!intersects(withRecolor.cells[i], edit), "grey structure alone must not hide a colour change");

    const cv::Rect cropRect(96, 64, 288, 256);
    const auto cropped = similarity(left, left(cropRect).clone(), 1, 0, cropRect.x, cropRect.y);
    verifySimilarity(cropped, left.cols, left.rows);
    require(cropped.result.cell_count > 150, "cropped source returns its verified overlap");
    for (int i = 0; i < cropped.result.cell_count; ++i) {
        const auto &cell = cropped.cells[i];
        require((cv::Rect(cell.x, cell.y, cell.width, cell.height) & cropRect).area() == cell.width * cell.height,
                "cropped source never paints nonoverlap");
    }
    const cv::Mat forward = cv::getRotationMatrix2D(cv::Point2f(240, 192), 17, 0.87);
    cv::Mat transformed, inverse;
    cv::warpAffine(left, transformed, forward, left.size(), cv::INTER_LINEAR,
        cv::BORDER_CONSTANT, cv::Scalar(0, 0, 0, 0));
    cv::invertAffineTransform(forward, inverse);
    const auto rotated = similarity(left, transformed, inverse.at<double>(0, 0), inverse.at<double>(1, 0),
        inverse.at<double>(0, 2), inverse.at<double>(1, 2));
    verifySimilarity(rotated, left.cols, left.rows);
    std::cout << "local rotated/scaled cells=" << rotated.result.cell_count << '\n';
    require(rotated.result.cell_count > 250, "rotation and resampling retain substantial verified texture");

    const auto unrelated = similarity(left, texture(381027));
    verifySimilarity(unrelated, left.cols, left.rows);
    require(unrelated.result.cell_count == 0, "unrelated images must not be highlighted");
    const cv::Mat blank(left.size(), CV_8UC4, cv::Scalar(140, 140, 140, 255));
    const auto flat = similarity(blank, blank);
    require(flat.status == CrossDiffImageMatchAccepted && flat.result.cell_count == 0, "flat templates cannot produce normalized-correlation false positives");
    require(flat.result.overlap_point_count == 4 && overlapArea(flat.result) == double(left.cols) * left.rows,
            "geometry is available even when flat content supplies no similarity evidence");
    cv::Mat invisible = left.clone();
    cv::Mat alpha = cv::Mat::zeros(left.size(), CV_8UC1);
    cv::insertChannel(alpha, invisible, 3);
    const auto transparentGeometry = similarity(invisible, invisible);
    require(transparentGeometry.result.cell_count == 0, "hidden RGB must not generate similar cells");
    require(transparentGeometry.result.overlap_point_count == 4 &&
            overlapArea(transparentGeometry.result) == double(left.cols) * left.rows,
            "geometric source boundaries must not pretend to be alpha content bounds");
    cv::Mat transparentHole = left.clone();
    cv::insertChannel(alpha(edit), transparentHole(edit), 3);
    const auto transparency = similarity(left, transparentHole);
    require(transparency.result.cell_count > 300, "opaque texture survives alongside transparency");
    for (int i = 0; i < transparency.result.cell_count; ++i)
        require(!intersects(transparency.cells[i], edit), "transparent hole stays unmarked");
    cv::Mat contourOnly(left.size(), CV_8UC4, cv::Scalar(0, 0, 0, 0));
    cv::rectangle(contourOnly, cv::Rect(64, 64, 320, 240), cv::Scalar(140, 140, 140, 255), -1);
    require(similarity(contourOnly, contourOnly).result.cell_count == 0,
            "matching alpha silhouette is not local image content evidence");
    const auto absent = similarity(left, left, 1, 0, 500, 0);
    require(absent.status == CrossDiffImageMatchAccepted && absent.result.cell_count == 0 &&
            absent.result.overlap_point_count == 0, "valid nonoverlapping transform produces empty evidence");
    const cv::Mat overlapRotation = cv::getRotationMatrix2D(cv::Point2f(240, 192), 45, 1);
    const auto eightCorner = similarity(left, left, overlapRotation.at<double>(0, 0),
        overlapRotation.at<double>(1, 0), overlapRotation.at<double>(0, 2), overlapRotation.at<double>(1, 2));
    verifySimilarity(eightCorner, left.cols, left.rows);
    require(eightCorner.result.overlap_point_count == 8 && overlapArea(eightCorner.result) > 100000 &&
            overlapArea(eightCorner.result) < double(left.cols) * left.rows,
            "rotated partial overlap returns the clipped eight-corner polygon");

    int checks = 0;
    auto cancel = [](void *context) { return ++*static_cast<int *>(context) >= 7 ? 1 : 0; };
    const auto cancelled = similarity(left, left, 1, 0, 0, 0, cancel, &checks);
    require(cancelled.status == CrossDiffImageMatchCancelled && isZero(cancelled.result),
            "row-level cancellation publishes neither partial regions nor partial geometry");
    require(similarity(left, left, std::numeric_limits<double>::quiet_NaN()).status == CrossDiffImageMatchFailure,
            "nonfinite transform rejected");
    require(similarity(left, left, 0).status == CrossDiffImageMatchFailure, "degenerate transform rejected");
    require(similarity(left, left, 1, 0, 1e100).status == CrossDiffImageMatchFailure, "unbounded translation rejected");
    CrossDiffImageSimilarityResult result{91, 92, 93, 8};
    for (auto &point : result.overlap) point = {94, 95};
    CrossDiffImageSimilarityCell sentinel{91, 92, 93, 94, 95};
    require(crossdiff_image_similarity_rgba(left.ptr(), left.step * left.rows, left.cols, left.rows, left.step,
        left.ptr(), left.step * left.rows, left.cols, left.rows, left.step, 1, 0, 0, 0,
        nullptr, nullptr, &result, &sentinel, 1) == CrossDiffImageMatchFailure,
        "insufficient capacity cannot silently truncate regions");
    require(isZero(result) && sentinel.x == 91 && sentinel.region_id == 95,
            "short output capacity clears all metadata and writes no partial output");
    require(crossdiff_image_similarity_rgba(left.ptr(), 1, left.cols, left.rows, left.step,
        left.ptr(), left.step * left.rows, left.cols, left.rows, left.step, 1, 0, 0, 0,
        nullptr, nullptr, &result, nullptr, 0) == CrossDiffImageMatchFailure, "short similarity input rejected");
    require(crossdiff_image_similarity_rgba(left.ptr(), left.step * left.rows, left.cols, left.rows, left.step,
        left.ptr(), left.step * left.rows, left.cols, left.rows, left.step, 1, 0, 0, 0,
        nullptr, nullptr, &result, nullptr, 4096) == CrossDiffImageMatchFailure, "missing output pointer rejected");
    const cv::Mat tiny(8, 8, CV_8UC4, cv::Scalar(40, 50, 60, 255));
    require(similarity(tiny, tiny).status == CrossDiffImageMatchAccepted && similarity(tiny, tiny).result.cell_count == 0,
            "sub-tile images have no verified regions");
    cv::Mat gradient(left.size(), CV_8UC4);
    for (int y = 0; y < gradient.rows; ++y)
        for (int x = 0; x < gradient.cols; ++x)
            gradient.at<cv::Vec4b>(y, x) = cv::Vec4b(x / 2, x / 2, x / 2, 255);
    require(similarity(gradient, gradient).result.cell_count == 0,
            "smooth low-texture gradients do not become false matching evidence");
    const cv::Mat islandTexture = texture(871920, 640, 640);
    cv::Mat islands(islandTexture.size(), CV_8UC4, cv::Scalar(0, 0, 0, 0));
    for (int row = 0; row < 4; ++row) {
        for (int column = 0; column < 5; ++column) {
            const cv::Rect island(16 + column * 112, 16 + row * 144, 48, 64);
            islandTexture(island).copyTo(islands(island));
        }
    }
    const auto separated = similarity(islands, islands);
    verifySimilarity(separated, islands.cols, islands.rows);
    require(separated.result.region_count == 12, "fragmented evidence is bounded to twelve complete regions");
    require(separated.result.compared_cell_count > separated.result.cell_count,
            "discarded smaller regions are not inflated into retained regions");
    const cv::Mat maximum = texture(431751, 1600, 1600);
    const auto maximumOutput = similarity(maximum, maximum);
    verifySimilarity(maximumOutput, maximum.cols, maximum.rows);
    require(maximumOutput.result.cell_count > 1300 && maximumOutput.result.cell_count <= 1600,
            "largest supported preview has a bounded grid with useful evidence");
    require(cv::norm(left, unchanged, cv::NORM_INF) == 0, "local verification must not modify source buffers");
    std::cout << "Local similarity cells: identity=" << identical.result.cell_count
              << " occlusion=" << withHole.result.cell_count << " crop=" << cropped.result.cell_count << '\n';
}
void verifyTransform(const Match &match, const cv::Mat &expected, const char *message) {
    std::cout << message << " status=" << match.status << " candidates=" << match.result.candidate_count
        << " inliers=" << match.result.inlier_count << " residual=" << match.result.median_residual
        << " coverage=" << match.result.left_coverage << "," << match.result.right_coverage << '\n';
    require(match.status == CrossDiffImageMatchAccepted, message);
    require(std::abs(match.result.a - expected.at<double>(0, 0)) < 0.008, "scale/cosine error");
    require(std::abs(match.result.b - expected.at<double>(1, 0)) < 0.008, "rotation/sine error");
    require(std::abs(match.result.tx - expected.at<double>(0, 2)) < 2.0, "horizontal translation error");
    require(std::abs(match.result.ty - expected.at<double>(1, 2)) < 2.0, "vertical translation error");
    require(match.result.point_count > 0 && match.result.point_count <= 128, "verified correspondence count");
    for (int i = 0; i < match.result.point_count; ++i) {
        const auto &point = match.points[i];
        require(std::hypot(match.result.a * point.right_x - match.result.b * point.right_y + match.result.tx - point.left_x,
                           match.result.b * point.right_x + match.result.a * point.right_y + match.result.ty - point.left_y) < 5,
                "returned correspondence must fit transform");
    }
}
}

int main() {
    try {
        const auto started = std::chrono::steady_clock::now();
        const cv::Mat left = scene(20261004);
        const cv::Mat identity = (cv::Mat_<double>(2, 3) << 1, 0, 0, 0, 1, 0);
        verifyTransform(match(left, left), identity, "identity");
        const cv::Mat forward = cv::getRotationMatrix2D(cv::Point2f(450, 350), 22, 0.82);
        cv::Mat transformed, inverse;
        cv::warpAffine(left, transformed, forward, left.size(), cv::INTER_LINEAR,
            cv::BORDER_CONSTANT, cv::Scalar(245, 245, 245, 255));
        cv::invertAffineTransform(forward, inverse);
        verifyTransform(match(left, transformed), inverse, "rotation and scaling");
        cv::rectangle(transformed, cv::Rect(230, 180, 280, 170), cv::Scalar(20, 30, 180, 255), -1);
        verifyTransform(match(left, transformed), inverse, "rotation with local edit/occlusion");
        const cv::Mat crop = left(cv::Rect(240, 180, 380, 310)).clone();
        const cv::Mat cropExpected = (cv::Mat_<double>(2, 3) << 1, 0, 240, 0, 1, 180);
        verifyTransform(match(left, crop), cropExpected, "crop");
        cv::Mat scaledCrop;
        cv::resize(crop, scaledCrop, cv::Size(), 1.5, 1.5, cv::INTER_LINEAR);
        const cv::Mat scaledExpected = (cv::Mat_<double>(2, 3) << 1.0/1.5, 0, 240 - 1.0/6,
                                                                         0, 1.0/1.5, 180 - 1.0/6);
        verifyTransform(match(left, scaledCrop), scaledExpected, "enlarged crop");
        const cv::Mat blank(700, 900, CV_8UC4, cv::Scalar(255, 255, 255, 255));
        require(match(blank, blank).status == CrossDiffImageMatchInsufficientFeatures, "blank is not a reliable match");
        const Match unrelated = match(left, scene(91427));
        std::cout << "unrelated status=" << unrelated.status << " candidates=" << unrelated.result.candidate_count << '\n';
        require(unrelated.status != CrossDiffImageMatchAccepted, "unrelated scenes must not align");
        cv::Mat repeating(700, 900, CV_8UC4, cv::Scalar(240, 240, 240, 255));
        for (int y = 0; y < 680; y += 40)
            for (int x = 0; x < 880; x += 40)
                cv::circle(repeating, cv::Point(x+20, y+20), 10, cv::Scalar(10, 10, 10, 255), -1);
        const auto repeatedMatch = match(repeating, repeating(cv::Rect(160, 120, 480, 440)).clone());
        std::cout << "repeated status=" << repeatedMatch.status << " features=" << repeatedMatch.result.left_feature_count << " candidates=" << repeatedMatch.result.candidate_count << " inliers=" << repeatedMatch.result.inlier_count << " coverage=" << repeatedMatch.result.left_coverage << "," << repeatedMatch.result.right_coverage << '\n';
        require(repeatedMatch.status != CrossDiffImageMatchAccepted, "repeated texture must not guess placement");
        cv::Mat invisible = left.clone();
        for (int y=0; y<invisible.rows; ++y)
            for (int x=0; x<invisible.cols; ++x) invisible.at<cv::Vec4b>(y,x)[3] = 0;
        require(match(invisible, invisible).status == CrossDiffImageMatchInsufficientFeatures, "hidden RGB is not evidence");
        cv::Mat transparentShapes(700, 900, CV_8UC4, cv::Scalar(0, 0, 0, 0));
        for (int i = 0; i < 20; ++i) {
            const int x = 35 + (i % 5) * 170, y = 25 + (i / 5) * 160;
            cv::rectangle(transparentShapes, cv::Rect(x, y, 100 + i, 85 + i), cv::Scalar(150, 150, 150, 255), -1);
        }
        const auto borderOnly = match(transparentShapes, transparentShapes);
        std::cout << "transparent borders status=" << borderOnly.status << " features=" << borderOnly.result.left_feature_count << '\n';
        require(borderOnly.status != CrossDiffImageMatchAccepted, "transparent silhouette borders alone are not image evidence");
        cv::Mat stretched;
        const cv::Mat stretch = (cv::Mat_<double>(2, 3) << 0.8, 0, 20, 0, 1.0, 0);
        cv::warpAffine(left, stretched, stretch, left.size(), cv::INTER_LINEAR,
                       cv::BORDER_CONSTANT, cv::Scalar(255, 255, 255, 255));
        require(match(left, stretched).status == CrossDiffImageMatchUnsupportedTransform,
                "anisotropic stretch must not silently use local similarity");
        cv::Mat alternate = left.clone();
        left(cv::Rect(450, 0, 450, 700)).copyTo(alternate(cv::Rect(0, 0, 450, 700)));
        left(cv::Rect(0, 0, 450, 700)).copyTo(alternate(cv::Rect(450, 0, 450, 700)));
        require(match(left, alternate).status != CrossDiffImageMatchAccepted, "competing pasted placements must be ambiguous");
        int checks = 0;
        auto cancel = [](void *value) { return ++*static_cast<int *>(value) >= 2 ? 1 : 0; };
        require(match(left, left, cancel, &checks).status == CrossDiffImageMatchCancelled, "cancel between stages");
        CrossDiffImageMatchResult result{};
        require(crossdiff_image_match_rgba(left.ptr(), 1, left.cols, left.rows, left.step,
            left.ptr(), left.step*left.rows, left.cols, left.rows, left.step,
            nullptr, nullptr, &result, nullptr, 0) == CrossDiffImageMatchFailure, "short buffer rejected");
        require(result.point_count == 0 && result.a == 0, "failure leaves no accepted transform");
        checkCompleteCrop();
        checkSimilarity();
        std::cout << "Image matching native checks passed: " << assertions << " assertions in "
            << std::chrono::duration<double>(std::chrono::steady_clock::now()-started).count() << " seconds\n";
        return 0;
    } catch (const std::exception &error) {
        std::cerr << "FAIL: " << error.what() << '\n';
        return 1;
    }
}
