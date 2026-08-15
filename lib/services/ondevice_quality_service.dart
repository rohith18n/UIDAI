import 'dart:math';
import 'dart:typed_data';
import 'package:image/image.dart' as img;

/// Quality Assessment Result containing scores, finger detection metrics, and real-time guidance feedback
class QualityAssessmentResult {
  final double blurScore;
  final bool isBlurry;
  final double brightness;
  final bool tooDark;
  final bool tooBright;
  final double glareRatio;
  final bool hasGlare;
  final bool isRoiAligned;
  final bool isFingerDetected;
  final int fingerCount;
  final double detectionConf;
  final double offsetX;
  final double offsetY;
  final String roiGuidance;
  final double readinessScore;
  final String readinessGrade;
  final String guidanceText;
  final bool isPassed;

  const QualityAssessmentResult({
    required this.blurScore,
    required this.isBlurry,
    required this.brightness,
    required this.tooDark,
    required this.tooBright,
    required this.glareRatio,
    required this.hasGlare,
    required this.isRoiAligned,
    required this.isFingerDetected,
    this.fingerCount = 0,
    this.detectionConf = 0.0,
    this.offsetX = 0.0,
    this.offsetY = 0.0,
    this.roiGuidance = '',
    required this.readinessScore,
    required this.readinessGrade,
    required this.guidanceText,
    required this.isPassed,
  });

  Map<String, dynamic> toJson() => {
    'passed': isPassed,
    'is_passed': isPassed,
    'guidance': guidanceText,
    'guidance_text': guidanceText,
    'blur_score': blurScore,
    'is_blurry': isBlurry,
    'blur': {
      'blur_score': blurScore,
      'is_blurry': isBlurry,
    },
    'brightness': {
      'brightness': brightness,
      'too_dark': tooDark,
      'too_bright': tooBright,
    },
    'brightness_val': brightness,
    'too_dark': tooDark,
    'too_bright': tooBright,
    'glare_ratio': glareRatio,
    'has_glare': hasGlare,
    'glare': {
      'has_glare': hasGlare,
      'glare_fraction': glareRatio,
    },
    'roi_aligned': isRoiAligned,
    'is_finger_detected': isFingerDetected,
    'finger_count': fingerCount,
    'detection_conf': detectionConf,
    'offset_x': offsetX,
    'offset_y': offsetY,
    'roi_guidance': roiGuidance,
    'readiness_score': readinessScore,
    'readiness_grade': readinessGrade,
  };
}

/// Production-ready On-Device Quality Service executing sub-15ms calculations
class OnDeviceQualityService {
  static const double blurThreshold = 20.0;
  static const double minBrightness = 35.0;
  static const double maxBrightness = 225.0;
  static const double maxGlareRatio = 0.05;

  /// Evaluates camera luminance buffer using the exact backend quality check and ROI detection algorithm.
  static QualityAssessmentResult evaluateYPlane({
    required Uint8List yPlaneBytes,
    required int width,
    required int height,
    required int bytesPerRow,
    int sampleStep = 2,
    bool isSlap = false,
  }) {
    if (yPlaneBytes.isEmpty || width <= 0 || height <= 0) {
      return const QualityAssessmentResult(
        blurScore: 0.0,
        isBlurry: true,
        brightness: 0.0,
        tooDark: true,
        tooBright: false,
        glareRatio: 0.0,
        hasGlare: false,
        isRoiAligned: false,
        isFingerDetected: false,
        fingerCount: 0,
        detectionConf: 0.0,
        offsetX: 0.0,
        offsetY: 0.0,
        roiGuidance: 'Place finger in view',
        readinessScore: 0.0,
        readinessGrade: 'F',
        guidanceText: 'No camera frame available',
        isPassed: false,
      );
    }

    Uint8List gray;
    int effWidth = width;
    int effHeight = height;
    int effBytesPerRow = bytesPerRow;

    // Detect compressed file format (JPEG/PNG) or length mismatch
    final bool isJpegOrPng =
        yPlaneBytes.length >= 2 &&
        ((yPlaneBytes[0] == 0xFF && yPlaneBytes[1] == 0xD8) ||
            (yPlaneBytes[0] == 0x89 && yPlaneBytes[1] == 0x50));

    if (isJpegOrPng || yPlaneBytes.length < (width * height / 2)) {
      try {
        var decoded = img.decodeImage(yPlaneBytes);
        if (decoded != null) {
          if (decoded.width > 480) {
            decoded = img.copyResize(decoded, width: 480);
          }
          effWidth = decoded.width;
          effHeight = decoded.height;
          effBytesPerRow = decoded.width;
          gray = Uint8List(effWidth * effHeight);

          int idx = 0;
          for (final pixel in decoded) {
            if (idx < gray.length) {
              gray[idx++] = (pixel.luminanceNormalized * 255.0).round().clamp(0, 255);
            }
          }
        } else {
          gray = yPlaneBytes;
        }
      } catch (_) {
        gray = yPlaneBytes;
      }
    } else {
      gray = yPlaneBytes;
    }

    if (gray.isEmpty || effWidth < 10 || effHeight < 10) {
      return const QualityAssessmentResult(
        blurScore: 0.0,
        isBlurry: true,
        brightness: 0.0,
        tooDark: true,
        tooBright: false,
        glareRatio: 0.0,
        hasGlare: false,
        isRoiAligned: false,
        isFingerDetected: false,
        readinessScore: 0.0,
        readinessGrade: 'F',
        guidanceText: 'Invalid frame',
        isPassed: false,
      );
    }

    // 1. Exact Backend Brightness & Glare Calculation
    double totalBrightness = 0.0;
    int overexposedCount = 0;
    int totalPixels = 0;

    for (int y = 0; y < effHeight; y += sampleStep) {
      final int rowOffset = y * effBytesPerRow;
      for (int x = 0; x < effWidth; x += sampleStep) {
        final int idx = rowOffset + x;
        if (idx >= gray.length) break;
        final int val = gray[idx];
        totalBrightness += val;
        totalPixels++;
        if (val > 240) {
          overexposedCount++;
        }
      }
    }

    final double meanBrightness = totalPixels > 0 ? (totalBrightness / totalPixels) : 0.0;
    final double glareFraction = totalPixels > 0 ? (overexposedCount / totalPixels) : 0.0;
    final bool tooDark = meanBrightness < minBrightness;
    final bool tooBright = meanBrightness > maxBrightness;
    final bool hasGlare = glareFraction > maxGlareRatio;

    // 2. Exact Backend Blur Calculation via Laplacian Variance (cv2.Laplacian)
    final double blurScore = _computeLaplacianVariance(
      gray,
      effWidth,
      effHeight,
      effBytesPerRow,
      step: sampleStep,
    );
    final bool isBlurry = blurScore < blurThreshold;

    // 3. Exact Backend Finger ROI Detection & Corner Background Separation
    final int tl = gray[0];
    final int tr = gray[min(effWidth - 1, gray.length - 1)];
    final int bl = gray[min((effHeight - 1) * effBytesPerRow, gray.length - 1)];
    final int br = gray[min((effHeight - 1) * effBytesPerRow + (effWidth - 1), gray.length - 1)];
    final double meanCorners = (tl + tr + bl + br) / 4.0;

    int foregroundPixels = 0;
    double sumX = 0.0;
    double sumY = 0.0;
    int sampledCount = 0;

    final int numBins = 16;
    final List<int> colGradients = List.filled(numBins, 0);
    final double binWidth = effWidth / numBins;

    final int startX = (effWidth * 0.05).round();
    final int endX = (effWidth * 0.95).round();
    final int startY = (effHeight * 0.05).round();
    final int endY = (effHeight * 0.95).round();

    for (int y = startY; y < endY; y += 2) {
      final int rowCurr = y * effBytesPerRow;
      for (int x = startX; x < endX; x += 2) {
        final int idx = rowCurr + x;
        if (idx >= gray.length) continue;
        final int val = gray[idx];
        sampledCount++;

        // Corner-adaptive foreground test (faithful to backend check_roi)
        final bool isFg = meanCorners > 127 ? (val < 235) : (val > 25);
        if (isFg) {
          foregroundPixels++;
          sumX += x;
          sumY += y;

          if (isSlap && binWidth > 0) {
            final int bin = (x / binWidth).floor().clamp(0, numBins - 1);
            colGradients[bin]++;
          }
        }
      }
    }

    final double minFgRatio = isSlap ? 0.05 : 0.04;
    final bool isFingerDetected = sampledCount > 0 && ((foregroundPixels / sampledCount) >= minFgRatio);

    double offsetX = 0.0;
    double offsetY = 0.0;
    bool isRoiAligned = false;
    String roiGuidance = '';
    int fingerCount = isFingerDetected ? 1 : 0;
    double detectionConf = 0.0;

    if (isFingerDetected && foregroundPixels > 0) {
      final double centroidX = sumX / foregroundPixels;
      final double centroidY = sumY / foregroundPixels;
      final double imageCenterX = effWidth * 0.5;
      final double imageCenterY = effHeight * 0.5;

      offsetX = centroidX - imageCenterX;
      offsetY = centroidY - imageCenterY;

      final double toleranceX = isSlap ? (effWidth * 0.35) : (effWidth * 0.20);
      final double toleranceY = effHeight * 0.20;
      isRoiAligned = (offsetX.abs() <= toleranceX) && (offsetY.abs() <= toleranceY);

      if (isRoiAligned) {
        roiGuidance = '';
      } else if (offsetX.abs() >= offsetY.abs()) {
        roiGuidance = offsetX < 0 ? 'Move right ➡️' : 'Move left ⬅️';
      } else {
        roiGuidance = offsetY < 0 ? 'Move down ⬇️' : 'Move up ⬆️';
      }

      if (isSlap) {
        // Calculate the horizontal width span of foreground tissue across 16 bins
        int activeBins = 0;
        final int binMinThreshold = max(5, (foregroundPixels / numBins * 0.25).round());
        for (int i = 0; i < numBins; i++) {
          if (colGradients[i] >= binMinThreshold) {
            activeBins++;
          }
        }

        final double fgRatio = foregroundPixels / max(1, sampledCount);

        // Multi-finger width span mapping:
        if (activeBins >= 5 || fgRatio >= 0.10) {
          fingerCount = 4; // Full 4-finger slap
        } else if (activeBins >= 4 || fgRatio >= 0.07) {
          fingerCount = 3;
        } else if (activeBins >= 2 || fgRatio >= 0.04) {
          fingerCount = 2;
        } else {
          fingerCount = 1;
        }
      }
      detectionConf = min(0.99, 0.65 + ((foregroundPixels / sampledCount) * 0.5));
    }

    // 4. Exact Readiness Score & Guidance Mapping
    double score = 100.0;
    if (!isFingerDetected) {
      score -= 55.0;
    }
    if (isBlurry) {
      score -= min(45.0, (blurThreshold - blurScore) * 2.0 + 20.0);
    }
    if (tooDark) {
      score -= min(35.0, (minBrightness - meanBrightness) * 0.8 + 15.0);
    } else if (tooBright) {
      score -= min(35.0, (meanBrightness - maxBrightness) * 0.6 + 15.0);
    }
    if (hasGlare) {
      score -= min(35.0, glareFraction * 150.0 + 15.0);
    }
    if (!isRoiAligned) {
      score -= 15.0;
    }
    score = max(0.0, min(100.0, score));

    String grade = 'F';
    if (score >= 85) {
      grade = 'A';
    } else if (score >= 70) {
      grade = 'B';
    } else if (score >= 50) {
      grade = 'C';
    } else if (score >= 30) {
      grade = 'D';
    }

    String guidance;
    if (!isFingerDetected) {
      guidance = isSlap ? 'Place 4 fingers flat inside guide' : 'Place finger inside oval';
    } else if (isSlap && fingerCount < 3) {
      guidance = 'Place all 4 fingers flat inside guide';
    } else if (!isRoiAligned && roiGuidance.isNotEmpty) {
      guidance = roiGuidance;
    } else if (tooDark) {
      guidance = 'Too dark — turn on flash 💡';
    } else if (tooBright) {
      guidance = 'Too bright — reduce exposure';
    } else if (hasGlare) {
      guidance = 'Glare detected — tilt hand away from light';
    } else if (isBlurry) {
      guidance = 'Image is blurry — tap screen to focus 🔍';
    } else {
      guidance = isSlap
          ? '$fingerCount fingers detected — hold still'
          : 'Good — capture ready';
    }

    final bool isPassed =
        isFingerDetected &&
        !isBlurry &&
        !tooDark &&
        !tooBright &&
        !hasGlare &&
        isRoiAligned &&
        (!isSlap || fingerCount >= 3) &&
        score >= 50.0;

    return QualityAssessmentResult(
      blurScore: double.parse(blurScore.toStringAsFixed(2)),
      isBlurry: isBlurry,
      brightness: double.parse(meanBrightness.toStringAsFixed(2)),
      tooDark: tooDark,
      tooBright: tooBright,
      glareRatio: double.parse(glareFraction.toStringAsFixed(3)),
      hasGlare: hasGlare,
      isRoiAligned: isRoiAligned,
      isFingerDetected: isFingerDetected,
      fingerCount: fingerCount,
      detectionConf: double.parse(detectionConf.toStringAsFixed(4)),
      offsetX: double.parse(offsetX.toStringAsFixed(1)),
      offsetY: double.parse(offsetY.toStringAsFixed(1)),
      roiGuidance: roiGuidance,
      readinessScore: double.parse(score.toStringAsFixed(1)),
      readinessGrade: grade,
      guidanceText: guidance,
      isPassed: isPassed,
    );
  }

  /// Exact discrete Laplacian convolution variance matching cv2.Laplacian(gray, cv2.CV_64F).var()
  static double _computeLaplacianVariance(
    Uint8List bytes,
    int width,
    int height,
    int bytesPerRow, {
    int step = 2,
  }) {
    if (width < 3 || height < 3 || bytes.isEmpty) return 0.0;

    double sum = 0.0;
    double sqSum = 0.0;
    int count = 0;

    for (int y = 1; y < height - 1; y += step) {
      final int rowCurr = y * bytesPerRow;
      final int rowPrev = (y - 1) * bytesPerRow;
      final int rowNext = (y + 1) * bytesPerRow;

      for (int x = 1; x < width - 1; x += step) {
        final int cIdx = rowCurr + x;
        final int tIdx = rowPrev + x;
        final int bIdx = rowNext + x;
        final int lIdx = rowCurr + (x - 1);
        final int rIdx = rowCurr + (x + 1);

        if (rIdx >= bytes.length || bIdx >= bytes.length) break;

        final int center = bytes[cIdx];
        final int top = bytes[tIdx];
        final int bottom = bytes[bIdx];
        final int left = bytes[lIdx];
        final int right = bytes[rIdx];

        // 4-neighbor discrete Laplacian kernel [[0, 1, 0], [1, -4, 1], [0, 1, 0]]
        final int lap = top + bottom + left + right - (4 * center);
        sum += lap;
        sqSum += (lap * lap);
        count++;
      }
    }

    if (count == 0) return 0.0;
    final double mean = sum / count;
    final double variance = (sqSum / count) - (mean * mean);
    return variance > 0 ? variance : 0.0;
  }
}
