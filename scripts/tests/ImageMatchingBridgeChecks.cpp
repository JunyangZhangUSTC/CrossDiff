#include "ImageMatchingBridge.h"
#include <opencv2/core.hpp>
#include <opencv2/imgproc.hpp>
#include <chrono>
#include <cmath>
#include <cstring>
#include <iostream>
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
        std::cout << "Image matching native checks passed: " << assertions << " assertions in "
            << std::chrono::duration<double>(std::chrono::steady_clock::now()-started).count() << " seconds\n";
        return 0;
    } catch (const std::exception &error) {
        std::cerr << "FAIL: " << error.what() << '\n';
        return 1;
    }
}
