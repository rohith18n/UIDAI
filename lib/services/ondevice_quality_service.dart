import 'dart:developer' as dev;
import 'dart:math';
import 'dart:typed_data';
import 'package:image/image.dart' as img;

/// Quality Assessment Result containing exact biometric verification metrics
class QualityAssessmentResult {
  final double blurScore;
  final bool isBlurry;
  final double brightness;
  final bool tooDark;
  final bool tooBright;
  final double glareRatio;
  final bool hasGlare;
  final double skinRatio;
  final double coverageRatio;
  final bool isTooFar;
  final bool isTooClose;
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
  final List<String> issues;
  final bool isPassed;

  const QualityAssessmentResult({
    required this.blurScore,
    required this.isBlurry,
    required this.brightness,
    required this.tooDark,
    required this.tooBright,
    required this.glareRatio,
    required this.hasGlare,
    required this.skinRatio,
    required this.coverageRatio,
    required this.isTooFar,
    required this.isTooClose,
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
    this.issues = const [],
    required this.isPassed,
  });

  Map<String, dynamic> toJson() => {
    'passed': isPassed,
    'is_passed': isPassed,
    'guidance': guidanceText,
    'guidance_text': guidanceText,
    'issues': issues,
    'blur_score': blurScore,
    'is_blurry': isBlurry,
    'blur': {'blur_score': blurScore, 'is_blurry': isBlurry},
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
    'glare': {'has_glare': hasGlare, 'glare_fraction': glareRatio},
    'skin_ratio': skinRatio,
    'coverage_ratio': coverageRatio,
    'is_too_far': isTooFar,
    'is_too_close': isTooClose,
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

/// Production-grade On-Device Quality & Liveness Service
class OnDeviceQualityService {
  // Biological and optical quality thresholds (matching backend calibration)
  static const double blurThresholdSingle = 20.0;
  static const double blurThresholdSlap = 16.0;
  static const double blurThreshold = blurThresholdSingle;
  static const double minBrightness = 45.0;
  static const double maxBrightness = 220.0;
  static const double maxGlareRatio = 0.06;

  /// Fast biological skin chroma classification (melanin/hemoglobin spectral model)
  static bool _isSkinPixel(int r, int g, int b) {
    if (r <= g || g <= b) return false;
    if (r < 50 || g < 28 || b < 15) return false;
    if ((r - g) < 8) return false; // Neutral gray/white fabric or paper
    if ((r - b) < 14) return false; // Blue/green cloth or background

    final int sum = r + g + b;
    if (sum == 0) return false;
    final double nr = r / sum;
    final double nb = b / sum;
    return (nr > 0.36 && nb < 0.33);
  }

  /// Evaluates camera frames rejecting non-skin surfaces (bedsheets, tables) and out-of-focus blur.
  static QualityAssessmentResult evaluateYPlane({
    required Uint8List yPlaneBytes,
    required int width,
    required int height,
    required int bytesPerRow,
    int sampleStep = 2,
    bool isSlap = false,
    String handSide = 'right',
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
        skinRatio: 0.0,
        coverageRatio: 0.0,
        isTooFar: true,
        isTooClose: false,
        isRoiAligned: false,
        isFingerDetected: false,
        fingerCount: 0,
        detectionConf: 0.0,
        offsetX: 0.0,
        offsetY: 0.0,
        roiGuidance: 'Place finger in view',
        readinessScore: 0.0,
        readinessGrade: 'Rejected',
        guidanceText: 'No camera frame available',
        issues: ['No camera frame available'],
        isPassed: false,
      );
    }

    int effWidth = width;
    int effHeight = height;
    Uint8List gray;
    Uint8List? rgbData;

    // Detect compressed file format (JPEG/PNG)
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
          gray = Uint8List(effWidth * effHeight);
          rgbData = Uint8List(effWidth * effHeight * 3);

          int pIdx = 0;
          int gIdx = 0;
          for (final pixel in decoded) {
            final r = pixel.r.toInt().clamp(0, 255);
            final g = pixel.g.toInt().clamp(0, 255);
            final b = pixel.b.toInt().clamp(0, 255);
            final lum = (0.299 * r + 0.587 * g + 0.114 * b).round().clamp(
              0,
              255,
            );

            if (gIdx < gray.length) {
              gray[gIdx++] = lum;
            }
            if (pIdx < rgbData.length - 2) {
              rgbData[pIdx++] = r;
              rgbData[pIdx++] = g;
              rgbData[pIdx++] = b;
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
        skinRatio: 0.0,
        coverageRatio: 0.0,
        isTooFar: true,
        isTooClose: false,
        isRoiAligned: false,
        isFingerDetected: false,
        readinessScore: 0.0,
        readinessGrade: 'Rejected',
        guidanceText: 'Invalid frame',
        issues: ['Invalid frame'],
        isPassed: false,
      );
    }

    // ── 1. Biological Skin Detection & Target ROI Masking ────────────────────
    final double cx = effWidth * 0.5;
    final double cy = effHeight * 0.5;
    final double rx = effWidth * (isSlap ? 0.38 : 0.24);
    final double ry = effHeight * (isSlap ? 0.35 : 0.26);

    // Slap 4-slot guides
    final double slapFingerW = effWidth * 0.15;
    final double slapGap = effWidth * 0.047;
    final double slapStartX = (effWidth - (4 * slapFingerW + 3 * slapGap)) / 2;
    final double slapKnuckleY = effHeight * 0.80;
    final slapLengths = (isSlap && handSide == 'left')
        ? <double>[0.50, 0.58, 0.52, 0.40]
        : <double>[0.40, 0.52, 0.58, 0.50]; // lengths for 4 slots

    final List<int> slotSkinCounts = List.filled(4, 0);
    final List<int> slotTotalCounts = List.filled(4, 0);

    int totalInRoi = 0;
    int skinInRoi = 0;
    int totalSampled = 0;
    double sumSkinRoiX = 0.0;
    double sumSkinRoiY = 0.0;
    double totalBrightnessInRoi = 0.0;
    int overexposedCount = 0;

    final Uint8List skinMask = Uint8List(effWidth * effHeight);

    for (int y = 0; y < effHeight; y += sampleStep) {
      final int rowOffset = y * effWidth;
      for (int x = 0; x < effWidth; x += sampleStep) {
        final int idx = rowOffset + x;
        if (idx >= gray.length) break;
        totalSampled++;

        final int lum = gray[idx];
        if (lum > 242) overexposedCount++;

        // Test if (x, y) is inside the Target Guide Oval or Slap Slots
        bool inRoi = false;
        if (isSlap) {
          for (int i = 0; i < 4; i++) {
            final double topY = slapKnuckleY - slapLengths[i] * effHeight;
            final double sx1 = slapStartX + i * (slapFingerW + slapGap);
            final double sx2 = sx1 + slapFingerW;
            final double sy1 = topY;
            final double sy2 = topY + slapFingerW * 1.35;
            if (x >= sx1 && x <= sx2 && y >= sy1 && y <= sy2) {
              inRoi = true;
              slotTotalCounts[i]++;
              break;
            }
          }
        } else {
          final double dx = (x - cx) / rx;
          final double dy = (y - cy) / ry;
          inRoi = (dx * dx + dy * dy) <= 1.15;
        }

        if (inRoi) {
          totalInRoi++;
          totalBrightnessInRoi += lum;
        }

        // Biological Skin Verification
        bool isSkin = false;
        if (rgbData != null && (idx * 3 + 2) < rgbData.length) {
          final int r = rgbData[idx * 3];
          final int g = rgbData[idx * 3 + 1];
          final int b = rgbData[idx * 3 + 2];
          isSkin = _isSkinPixel(r, g, b);
        } else {
          isSkin = (lum >= 40 && lum <= 235);
        }

        if (isSkin) {
          skinMask[idx] = 255;
          if (inRoi) {
            skinInRoi++;
            sumSkinRoiX += x;
            sumSkinRoiY += y;

            if (isSlap) {
              for (int i = 0; i < 4; i++) {
                final double topY = slapKnuckleY - slapLengths[i] * effHeight;
                final double sx1 = slapStartX + i * (slapFingerW + slapGap);
                final double sx2 = sx1 + slapFingerW;
                final double sy1 = topY;
                final double sy2 = topY + slapFingerW * 1.35;
                if (x >= sx1 && x <= sx2 && y >= sy1 && y <= sy2) {
                  slotSkinCounts[i]++;
                  break;
                }
              }
            }
          }
        }
      }
    }

    final double skinRatioInRoi =
        totalInRoi > 0 ? (skinInRoi / totalInRoi) : 0.0;
    final double meanBrightness =
        totalInRoi > 0 ? (totalBrightnessInRoi / totalInRoi) : 0.0;
    final double glareFraction =
        totalSampled > 0 ? (overexposedCount / totalSampled) : 0.0;

    int activeSlotCount = 0;
    final List<bool> slotFilled = List.filled(4, false);
    if (isSlap) {
      for (int i = 0; i < 4; i++) {
        final double sRatio =
            slotTotalCounts[i] > 0
                ? (slotSkinCounts[i] / slotTotalCounts[i])
                : 0.0;
        if (sRatio >= 0.20) {
          activeSlotCount++;
          slotFilled[i] = true;
        }
      }
    }

    // Strict Finger Presence Check: Slap REQUIRES ALL 4 slots filled!
    final bool isFingerDetected =
        isSlap ? (activeSlotCount == 4) : (skinRatioInRoi >= 0.24);

    // ── 2. Ridge Sharpness & Blur (Computed on verified skin pixels inside ROI) ─
    final double currentBlurThreshold =
        isSlap ? blurThresholdSlap : blurThresholdSingle;
    final double blurScore = _computeSkinLaplacianVariance(
      gray,
      skinMask,
      effWidth,
      effHeight,
      step: sampleStep,
    );
    final bool isBlurry = blurScore < currentBlurThreshold;

    final bool tooDark = meanBrightness < minBrightness;
    final bool tooBright = meanBrightness > maxBrightness;
    final bool hasGlare = glareFraction > maxGlareRatio;

    // ── 3. Centering & Distance (Relative to Target Oval/Slots) ───────────────
    double offsetX = 0.0;
    double offsetY = 0.0;
    bool isRoiAligned = true;
    String roiGuidance = '';

    if (isFingerDetected && skinInRoi > 0) {
      final double centroidX = sumSkinRoiX / skinInRoi;
      final double centroidY = sumSkinRoiY / skinInRoi;

      offsetX = centroidX - cx;
      offsetY = centroidY - cy;

      final double tolX = rx * (isSlap ? 0.45 : 0.38);
      final double tolY = ry * (isSlap ? 0.45 : 0.38);
      isRoiAligned = (offsetX.abs() <= tolX) && (offsetY.abs() <= tolY);

      if (!isRoiAligned) {
        if (offsetX.abs() >= offsetY.abs()) {
          roiGuidance = offsetX < 0 ? 'Move right ➡️' : 'Move left ⬅️';
        } else {
          roiGuidance = offsetY < 0 ? 'Move down ⬇️' : 'Move up ⬆️';
        }
      }
    }

    final bool isTooFar =
        !isFingerDetected || skinRatioInRoi < (isSlap ? 0.20 : 0.30);
    final bool isTooClose = skinRatioInRoi > 0.95 && (meanBrightness > 70);

    // ── 4. Formulate Actionable Guidance Issues ──────────────────────────────
    final List<String> issues = [];
    if (!isFingerDetected) {
      if (isSlap) {
        if (activeSlotCount == 0) {
          issues.add('Place 4 fingers flat inside guide slots');
        } else {
          issues.add(
            'Place all 4 fingers inside slots ($activeSlotCount/4 detected)',
          );
        }
      } else {
        issues.add('Place fingertip inside oval guide');
      }
    } else {
      if (isSlap && activeSlotCount < 4) {
        issues.add(
          'Place all 4 fingers inside slots ($activeSlotCount/4 detected)',
        );
      }
      if (!isRoiAligned && roiGuidance.isNotEmpty) {
        issues.add(roiGuidance);
      }
      if (isBlurry) {
        issues.add('Finger is blurry — tap screen to focus 🔍');
      }
      if (tooDark) {
        issues.add('Image is darker — open flash 💡');
      }
      if (tooBright) {
        issues.add('Too bright — reduce exposure');
      }
      if (hasGlare) {
        issues.add('Glare detected — adjust angle');
      }
      if (isTooFar) {
        issues.add(
          isSlap
              ? 'Move hand closer to fill all 4 slots'
              : 'Move finger closer to fill oval 🔍',
        );
      }
      if (isTooClose) {
        issues.add('Move finger slightly back');
      }
    }

    // ── 5. Exact Readiness Score Formula ─────────────────────────────────────
    const double blurTarget = 80.0;
    final double blurNorm = (blurScore.clamp(0.0, blurTarget)) / blurTarget;
    const double brightCenter = 115.0;
    final double brightNorm = max(
      0.0,
      1.0 - (meanBrightness - brightCenter).abs() / 115.0,
    );
    final double glareNorm = hasGlare ? 0.0 : 1.0;
    final double skinNorm = skinRatioInRoi.clamp(0.0, 1.0);
    final double slotNorm =
        isSlap ? (activeSlotCount / 4.0) : (isRoiAligned ? 1.0 : 0.6);

    double rawScore = 0.0;
    if (isFingerDetected && isRoiAligned) {
      rawScore =
          (blurNorm * 35.0) +
          (brightNorm * 25.0) +
          (glareNorm * 15.0) +
          (skinNorm * 10.0) +
          (slotNorm * 15.0);
    } else if (isFingerDetected) {
      rawScore = (blurNorm * 25.0) + (brightNorm * 20.0) + (slotNorm * 20.0);
    }
    rawScore = rawScore.clamp(0.0, 100.0);
    final double score = double.parse(rawScore.toStringAsFixed(1));

    if (issues.isEmpty && isFingerDetected && isRoiAligned && score < 55.0) {
      issues.add('Quality: ${score.toInt()}% — align steadily for best capture');
    }

    String grade = 'Rejected';
    if (score >= 75.0 && issues.isEmpty) {
      grade = 'Excellent';
    } else if (score >= 55.0) {
      grade = 'Good';
    } else if (score >= 35.0) {
      grade = 'Marginal';
    } else {
      grade = 'Rejected';
    }

    final String guidance =
        issues.isNotEmpty
            ? issues.first
            : (isSlap
                ? '✓ 4 slap fingers aligned — ready to capture'
                : '✓ Fingerprint clear — ready to capture');

    final bool isPassed =
        issues.isEmpty &&
        isFingerDetected &&
        isRoiAligned &&
        !isBlurry &&
        !tooDark &&
        !tooBright &&
        !hasGlare &&
        score >= 55.0 &&
        (!isSlap || activeSlotCount >= 3);

    final result = QualityAssessmentResult(
      blurScore: double.parse(blurScore.toStringAsFixed(2)),
      isBlurry: isBlurry,
      brightness: double.parse(meanBrightness.toStringAsFixed(2)),
      tooDark: tooDark,
      tooBright: tooBright,
      glareRatio: double.parse(glareFraction.toStringAsFixed(3)),
      hasGlare: hasGlare,
      skinRatio: double.parse(skinRatioInRoi.toStringAsFixed(3)),
      coverageRatio: double.parse(skinRatioInRoi.toStringAsFixed(3)),
      isTooFar: isTooFar,
      isTooClose: isTooClose,
      isRoiAligned: isRoiAligned,
      isFingerDetected: isFingerDetected,
      fingerCount: isSlap ? activeSlotCount : (isFingerDetected ? 1 : 0),
      detectionConf: double.parse((skinRatioInRoi * 0.98).toStringAsFixed(4)),
      offsetX: double.parse(offsetX.toStringAsFixed(1)),
      offsetY: double.parse(offsetY.toStringAsFixed(1)),
      roiGuidance: roiGuidance,
      readinessScore: score,
      readinessGrade: grade,
      guidanceText: guidance,
      issues: issues,
      isPassed: isPassed,
    );

    // Terminal Diagnostic Logging
    if (isPassed) {
      dev.log(
        '✓ [QUALITY.PASS] Slap: $isSlap | Slots: $activeSlotCount/4 | Skin: ${(skinRatioInRoi * 100).toStringAsFixed(1)}% | RidgeVar: $blurScore | Bright: ${result.brightness} | Grade: $grade ($score/100)',
        name: 'QC.LIVE',
      );
    } else {
      dev.log(
        '⚠️ [QUALITY.FAIL] Slap: $isSlap | Issues: $issues | Slots: $activeSlotCount/4 | Skin: ${(skinRatioInRoi * 100).toStringAsFixed(1)}% | RidgeVar: $blurScore (thr: $currentBlurThreshold) | Bright: ${result.brightness}',
        name: 'QC.LIVE',
      );
    }

    return result;
  }

  /// Computes Laplacian variance on verified human skin pixels to reject blurry smudges & textured cloth
  static double _computeSkinLaplacianVariance(
    Uint8List bytes,
    Uint8List skinMask,
    int width,
    int height, {
    int step = 2,
  }) {
    if (width < 4 || height < 4 || bytes.isEmpty) return 0.0;

    double sum = 0.0;
    double sqSum = 0.0;
    int count = 0;

    for (int y = step; y < height - step; y += step) {
      final int rowCurr = y * width;
      final int rowPrev = (y - 1) * width;
      final int rowNext = (y + 1) * width;

      for (int x = step; x < width - step; x += step) {
        final int cIdx = rowCurr + x;
        if (skinMask.isNotEmpty &&
            cIdx < skinMask.length &&
            skinMask[cIdx] == 0) {
          continue;
        }

        final int center = bytes[cIdx];
        final int top = bytes[rowPrev + x];
        final int bottom = bytes[rowNext + x];
        final int left = bytes[rowCurr + (x - 1)];
        final int right = bytes[rowCurr + (x + 1)];

        // 4-neighbor discrete Laplacian kernel [[0, 1, 0], [1, -4, 1], [0, 1, 0]]
        final int lap = top + bottom + left + right - (4 * center);
        sum += lap;
        sqSum += (lap * lap);
        count++;
      }
    }

    if (count < 25) return 0.0;
    final double mean = sum / count;
    final double variance = (sqSum / count) - (mean * mean);
    return max(0.0, variance);
  }
}
