#include "PhotoCVBridge.h"
#include <opencv2/core.hpp>
#include <opencv2/imgproc.hpp>
#include <cfloat>
#include <cmath>
#include <vector>

const char *crossdiff_photo_opencv_version(void) { return CV_VERSION; }

int crossdiff_photo_histograms(const float *rgba, int width, int height,
    double *histograms, size_t histogram_count, int *valid_count, double *neutral_fraction) {
    if (!rgba || !histograms || !valid_count || !neutral_fraction || width <= 0 || height <= 0 ||
        width > 4096 || height > 4096 || histogram_count != 256 * 5 + 360) return 1;
    try {
        const cv::Mat source(height, width, CV_32FC4, const_cast<float *>(rgba));
        cv::Mat mask;
        // inRange rejects NaN/infinite RGB as well as alpha <= 0. Every remaining
        // sample has equal weight, independent of its partial alpha coverage.
        cv::inRange(source, cv::Scalar(-FLT_MAX, -FLT_MAX, -FLT_MAX, std::nextafter(0.0f, 1.0f)),
                    cv::Scalar(FLT_MAX, FLT_MAX, FLT_MAX, 1), mask);
        const int count = cv::countNonZero(mask);
        if (count == 0) return 2;
        cv::Mat rgb;
        cv::cvtColor(source, rgb, cv::COLOR_RGBA2RGB);
        // HSL is explicitly a bounded SDR analysis. This is not RAW clipping detection.
        cv::max(rgb, 0, rgb);
        cv::min(rgb, 1, rgb);
        cv::Mat hls;
        cv::cvtColor(rgb, hls, cv::COLOR_RGB2HLS);
        cv::Mat chromatic;
        cv::inRange(hls, cv::Scalar(0, 0, 0.02), cv::Scalar(360, 1, 1), chromatic);
        cv::bitwise_and(chromatic, mask, chromatic);
        *valid_count = count;
        *neutral_fraction = 1.0 - static_cast<double>(cv::countNonZero(chromatic)) / count;
        auto histogram = [&](const cv::Mat &input, int channel, int bins, float maximum,
                             const cv::Mat &selection, double *output) {
            // Keep every internal bin edge exact (including HSL L=0.5). Only the
            // last edge is extended because calcHist's upper endpoint is exclusive.
            std::vector<float> edges(bins + 1);
            for (int i = 0; i <= bins; ++i) edges[i] = maximum * i / bins;
            edges[bins] = std::nextafter(maximum, INFINITY);
            const float *ranges[] = {edges.data()};
            cv::Mat result;
            cv::calcHist(&input, 1, &channel, selection, result, 1, &bins, ranges, false, false);
            for (int i = 0; i < bins; ++i) output[i] = static_cast<double>(result.at<float>(i)) / count;
        };
        histogram(rgb, 0, 256, 1, mask, histograms);
        histogram(rgb, 1, 256, 1, mask, histograms + 256);
        histogram(rgb, 2, 256, 1, mask, histograms + 512);
        histogram(hls, 1, 256, 1, mask, histograms + 768);
        histogram(hls, 2, 256, 1, mask, histograms + 1024);
        histogram(hls, 0, 360, 360, chromatic, histograms + 1280);
        return 0;
    } catch (const cv::Exception &) { return 3; }
      catch (...) { return 4; }
}
