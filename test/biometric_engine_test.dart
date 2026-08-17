import 'dart:math';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:yellowsense_uidai/services/local_biometric_engine.dart';
import 'package:yellowsense_uidai/services/ondevice_pipeline_service.dart';
import 'package:yellowsense_uidai/services/ondevice_quality_service.dart';

void main() {
  group('On-Device Biometric Engine & Matcher Verification', () {
    List<Map<String, dynamic>> generatePlausibleMinutiae({int count = 25, int seed = 42}) {
      final rng = Random(seed);
      final list = <Map<String, dynamic>>[];
      for (int i = 0; i < count; i++) {
        list.add({
          'x': 50.0 + rng.nextDouble() * 200.0,
          'y': 50.0 + rng.nextDouble() * 250.0,
          'direction': rng.nextDouble() * 2 * pi - pi,
          'type': rng.nextBool() ? 'RIG' : 'BIF',
          'confidence': 0.85 + rng.nextDouble() * 0.14,
        });
      }
      return list;
    }

    List<Map<String, dynamic>> rotateTemplate(List<Map<String, dynamic>> tmpl, double degrees) {
      final rad = degrees * pi / 180.0;
      final cosR = cos(rad);
      final sinR = sin(rad);
      return tmpl.map((m) {
        final double x = (m['x'] as num).toDouble();
        final double y = (m['y'] as num).toDouble();
        final double dir = (m['direction'] as num).toDouble();
        return {
          'x': x * cosR - y * sinR + 25.0,
          'y': x * sinR + y * cosR - 15.0,
          'direction': (dir + rad + pi) % (2 * pi) - pi,
          'type': m['type'],
          'confidence': m['confidence'],
        };
      }).toList();
    }

    List<Map<String, dynamic>> scaleTemplate(List<Map<String, dynamic>> tmpl, double factor) {
      return tmpl.map((m) {
        final double x = (m['x'] as num).toDouble();
        final double y = (m['y'] as num).toDouble();
        return {
          'x': x * factor,
          'y': y * factor,
          'direction': m['direction'],
          'type': m['type'],
          'confidence': m['confidence'],
        };
      }).toList();
    }

    test('1. Self-Match score is strong (>= 0.90)', () async {
      final tmpl = generatePlausibleMinutiae(count: 30, seed: 101);
      final score = LocalBiometricEngine.matchMinutiaeForTest(tmpl, tmpl);
      expect(score, greaterThanOrEqualTo(0.90));
    });

    test('2. Rotation Invariance: Rotated template (+20 deg) matches genuine template', () async {
      final tmplA = generatePlausibleMinutiae(count: 32, seed: 202);
      final tmplRotated = rotateTemplate(tmplA, 20.0);
      final score = LocalBiometricEngine.matchMinutiaeForTest(tmplA, tmplRotated);
      expect(score, greaterThanOrEqualTo(0.60));
    });

    test('3. Scale Robustness: Rescaled template (0.9x) matches genuine template', () async {
      final tmplA = generatePlausibleMinutiae(count: 30, seed: 303);
      final tmplScaled = scaleTemplate(tmplA, 0.90);
      final score = LocalBiometricEngine.matchMinutiaeForTest(tmplA, tmplScaled);
      expect(score, greaterThanOrEqualTo(0.55));
    });

    test('4. Impostor Discrimination: Completely unrelated templates yield near-zero score', () async {
      final tmplA = generatePlausibleMinutiae(count: 30, seed: 404);
      final tmplB = generatePlausibleMinutiae(count: 30, seed: 999);
      final score = LocalBiometricEngine.matchMinutiaeForTest(tmplA, tmplB);
      expect(score, lessThan(0.20));
    });

    test('5. On-Device Pipeline executes on synthetic image', () async {
      final synthetic = img.Image(width: 320, height: 420);
      img.fill(synthetic, color: img.ColorRgb8(195, 145, 120)); // skin tone
      // Draw some dark fingerprint lines
      for (int y = 50; y < 350; y += 8) {
        img.drawLine(synthetic, x1: 50, y1: y, x2: 270, y2: y, color: img.ColorRgb8(40, 30, 25));
      }

      final jpgBytes = img.encodeJpg(synthetic);
      final result = await OnDevicePipelineService.processBytesLocally(jpgBytes);

      expect(result['success'], isTrue);
      expect(result['images']?['cropped'], isNotEmpty);
      expect(result['images']?['preprocessed'], isNotEmpty);
      expect(result['images']?['visualization'], isNotEmpty);
    });

    test('6. Morphometrics: Classifies Thumb vs Slender Finger accurately', () async {
      // Create broad thumb silhouette
      final thumbImage = img.Image(width: 320, height: 480);
      img.fill(thumbImage, color: img.ColorRgb8(20, 20, 20)); // dark background
      img.fillRect(thumbImage, x1: 80, y1: 100, x2: 240, y2: 380, color: img.ColorRgb8(190, 140, 110)); // broad skin pad (W:160, H:280 -> AR: 0.57)

      final thumbJpg = img.encodeJpg(thumbImage);
      final thumbQc = OnDeviceQualityService.evaluateYPlane(
        yPlaneBytes: thumbJpg,
        width: 320,
        height: 480,
        bytesPerRow: 320,
        isSlap: false,
      );

      expect(thumbQc.isThumb, isTrue);
      expect(thumbQc.digitType, equals('thumb'));

      // Create slender index/little finger silhouette
      final slenderImage = img.Image(width: 320, height: 480);
      img.fill(slenderImage, color: img.ColorRgb8(20, 20, 20));
      img.fillRect(slenderImage, x1: 130, y1: 100, x2: 190, y2: 380, color: img.ColorRgb8(190, 140, 110)); // narrow finger (W:60, H:280 -> AR: 0.21)

      final slenderJpg = img.encodeJpg(slenderImage);
      final slenderQc = OnDeviceQualityService.evaluateYPlane(
        yPlaneBytes: slenderJpg,
        width: 320,
        height: 480,
        bytesPerRow: 320,
        isSlap: false,
      );

      expect(slenderQc.isThumb, isFalse);
      expect(slenderQc.digitType, equals('slender_finger'));
      expect(slenderQc.issues.any((s) => s.contains('Slender finger detected')), isTrue);
    });
  });
}
