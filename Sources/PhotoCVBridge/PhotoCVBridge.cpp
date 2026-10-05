#include "PhotoCVBridge.h"
#include <opencv2/core.hpp>
#include <opencv2/imgproc.hpp>
#include <algorithm>
#include <cfloat>
#include <cmath>
#include <vector>

namespace {
constexpr int legacyHistogramCount = 256 * 5 + 360;

void boundedRGB(const cv::Mat &source, cv::Mat &rgb, cv::Mat &mask) {
    // Equal weight for valid visible samples; alpha is not a statistical weight.
    cv::inRange(source, cv::Scalar(-FLT_MAX, -FLT_MAX, -FLT_MAX, std::nextafter(0.0f, 1.0f)),
                cv::Scalar(FLT_MAX, FLT_MAX, FLT_MAX, 1), mask);
    cv::cvtColor(source, rgb, cv::COLOR_RGBA2RGB);
    rgb.setTo(cv::Scalar(0, 0, 0), ~mask);
    // All metrics describe the current bounded sRGB SDR rendering, never RAW clipping.
    cv::max(rgb, 0, rgb);
    cv::min(rgb, 1, rgb);
}

float binEdge(int index, int bins, float maximum) {
    return index == bins ? std::nextafter(maximum, INFINITY) : maximum * index / bins;
}

void addHistogram(const cv::Mat &input, int channel, int bins, float maximum,
                  const cv::Mat &selection, double *output) {
    // Only the final edge extends: internal edges such as HSL L=0.5 stay exact.
    std::vector<float> edges(bins + 1);
    for (int i = 0; i <= bins; ++i) edges[i] = binEdge(i, bins, maximum);
    const float *ranges[] = {edges.data()};
    cv::Mat result;
    cv::calcHist(&input, 1, &channel, selection, result, 1, &bins, ranges, false, false);
    for (int i = 0; i < bins; ++i) output[i] += static_cast<double>(result.at<float>(i));
}

int histograms(const float *rgba, int width, int height, double *output, size_t output_count,
               int *valid_count, double *neutral_fraction, bool includeLab) {
    const size_t required = legacyHistogramCount + (includeLab ? 256 : 0);
    if (!rgba || !output || !valid_count || !neutral_fraction || width <= 0 || height <= 0 ||
        width > 4096 || height > 4096 || output_count != required) return 1;
    try {
        std::fill(output, output + output_count, 0);
        *valid_count = 0;
        *neutral_fraction = 0;
        int chromaticCount = 0;
        // Row blocks bound temporary OpenCV allocations independently of image area.
        for (int row = 0; row < height; row += 128) {
            const cv::Mat source(std::min(128, height - row), width, CV_32FC4,
                                 const_cast<float *>(rgba + static_cast<size_t>(row) * width * 4));
            cv::Mat rgb, mask;
            boundedRGB(source, rgb, mask);
            const int count = cv::countNonZero(mask);
            if (count == 0) continue;
            *valid_count += count;
            cv::Mat hls, chromatic;
            cv::cvtColor(rgb, hls, cv::COLOR_RGB2HLS);
            // SIMD conversion can round saturated sRGB to S=1+ULP. Restore
            // the documented H/L/S bounds before both masking and binning;
            // otherwise these valid pixels are lost and mislabeled neutral.
            cv::max(hls, cv::Scalar(0, 0, 0), hls);
            cv::min(hls, cv::Scalar(360, 1, 1), hls);
            cv::inRange(hls, cv::Scalar(0, 0, 0.02), cv::Scalar(360, 1, 1), chromatic);
            cv::bitwise_and(chromatic, mask, chromatic);
            chromaticCount += cv::countNonZero(chromatic);
            addHistogram(rgb, 0, 256, 1, mask, output);
            addHistogram(rgb, 1, 256, 1, mask, output + 256);
            addHistogram(rgb, 2, 256, 1, mask, output + 512);
            addHistogram(hls, 1, 256, 1, mask, output + 768);
            addHistogram(hls, 2, 256, 1, mask, output + 1024);
            addHistogram(hls, 0, 360, 360, chromatic, output + 1280);
            if (includeLab) {
                cv::Mat lab;
                // OpenCV's float sRGB -> Lab produces L* in 0...100 (D65).
                cv::cvtColor(rgb, lab, cv::COLOR_RGB2Lab);
                addHistogram(lab, 0, 256, 100, mask, output + legacyHistogramCount);
            }
        }
        if (*valid_count == 0) return 2;
        *neutral_fraction = 1.0 - static_cast<double>(chromaticCount) / *valid_count;
        for (size_t i = 0; i < output_count; ++i) output[i] /= *valid_count;
        return 0;
    } catch (const cv::Exception &) { return 3; }
      catch (...) { return 4; }
}
}

const char *crossdiff_photo_opencv_version(void) { return CV_VERSION; }

int crossdiff_photo_histograms(const float *rgba, int width, int height,
    double *output, size_t output_count, int *valid_count, double *neutral_fraction) {
    return histograms(rgba, width, height, output, output_count, valid_count, neutral_fraction, false);
}

int crossdiff_photo_histograms_v2(const float *rgba, int width, int height,
    double *output, size_t output_count, int *valid_count, double *neutral_fraction) {
    return histograms(rgba, width, height, output, output_count, valid_count, neutral_fraction, true);
}

int crossdiff_photo_preview(const float *rgba, int width, int height, int display_channel,
    int brush_channel, int lower_bin, int upper_bin, int roi_x, int roi_y, int roi_width, int roi_height,
    unsigned char *output, size_t output_count) {
    if (!rgba || !output || width <= 0 || height <= 0 || width > 2048 || height > 128 ||
        display_channel < 0 || display_channel > 3 || brush_channel < -1 || brush_channel > 3 ||
        lower_bin < 0 || upper_bin > 255 || lower_bin > upper_bin ||
        roi_x < 0 || roi_y < 0 || roi_width < 0 || roi_height < 0 ||
        roi_x > width || roi_y > height || roi_width > width - roi_x || roi_height > height - roi_y ||
        output_count != static_cast<size_t>(width) * height * 4) return 1;
    try {
        const cv::Mat source(height, width, CV_32FC4, const_cast<float *>(rgba));
        cv::Mat rgb, valid, selected;
        boundedRGB(source, rgb, valid);
        if (brush_channel >= 0 && roi_width > 0 && roi_height > 0) {
            cv::Mat metric;
            if (brush_channel == 0) {
                cv::Mat lab;
                cv::cvtColor(rgb, lab, cv::COLOR_RGB2Lab);
                cv::extractChannel(lab, metric, 0);
            } else {
                cv::extractChannel(rgb, metric, brush_channel - 1);
            }
            const float maximum = brush_channel == 0 ? 100 : 1;
            cv::Mat belowUpper;
            cv::compare(metric, binEdge(lower_bin, 256, maximum), selected, cv::CMP_GE);
            cv::compare(metric, binEdge(upper_bin + 1, 256, maximum), belowUpper, cv::CMP_LT);
            cv::bitwise_and(selected, belowUpper, selected);
            cv::bitwise_and(selected, valid, selected);
            cv::Mat roiMask = cv::Mat::zeros(height, width, CV_8UC1);
            roiMask(cv::Rect(roi_x, roi_y, roi_width, roi_height)).setTo(255);
            cv::bitwise_and(selected, roiMask, selected);
        }
        if (display_channel > 0) {
            cv::Mat channel;
            cv::extractChannel(rgb, channel, display_channel - 1);
            cv::cvtColor(channel, rgb, cv::COLOR_GRAY2RGB);
        }
        if (!selected.empty()) {
            // Blend only the display pixels; preserve local texture and source alpha.
            const cv::Mat amber(rgb.size(), rgb.type(), cv::Scalar(1, 0.72, 0.05));
            cv::Mat highlighted;
            cv::addWeighted(rgb, 0.68, amber, 0.32, 0, highlighted);
            highlighted.copyTo(rgb, selected);
        }
        cv::Mat rgb8, alpha, alpha8;
        rgb.convertTo(rgb8, CV_8UC3, 255);
        cv::extractChannel(source, alpha, 3);
        alpha.setTo(0, ~valid);
        alpha.convertTo(alpha8, CV_8UC1, 255);
        cv::Mat destination(height, width, CV_8UC4, output);
        const cv::Mat inputs[] = {rgb8, alpha8};
        const int channels[] = {0, 0, 1, 1, 2, 2, 3, 3};
        cv::mixChannels(inputs, 2, &destination, 1, channels, 4);
        return 0;
    } catch (const cv::Exception &) { return 3; }
      catch (...) { return 4; }
}
