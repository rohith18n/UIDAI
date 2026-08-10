import 'dart:async';
import 'package:flutter/services.dart';

/// Dart wrapper service interacting with the native Kotlin Fingerprint SDK via Platform Channels.
class OfflineSdkService {
  static const MethodChannel _channel =
      MethodChannel('com.yellowsense.uidai/fingerprint_sdk');

  /// Executes full 7-stage pipeline locally on device (< 5s on-device target).
  static Future<Map<String, dynamic>> processImageOffline(Uint8List imageBytes) async {
    try {
      final Map<dynamic, dynamic>? result = await _channel.invokeMethod(
        'processImageOffline',
        <String, dynamic>{
          'imageBytes': imageBytes,
        },
      );

      if (result != null) {
        return Map<String, dynamic>.from(result);
      }
    } on PlatformException catch (e) {
      return <String, dynamic>{
        'success': false,
        'message': 'Platform Channel Error: ${e.message}',
        'total_execution_time_ms': 0,
        'guidance': 'Native processing error',
      };
    }
    return <String, dynamic>{
      'success': false,
      'message': 'Unknown error executing offline SDK',
      'total_execution_time_ms': 0,
      'guidance': 'SDK execution failed',
    };
  }

  /// Verifies two minutiae templates 1:1 on-device (< 50ms matching target).
  static Future<Map<String, dynamic>> verifyOffline({
    required List<Map<String, dynamic>> minutiae1,
    required List<Map<String, dynamic>> minutiae2,
  }) async {
    try {
      final Map<dynamic, dynamic>? result = await _channel.invokeMethod(
        'verifyOffline',
        <String, dynamic>{
          'minutiae1': minutiae1,
          'minutiae2': minutiae2,
        },
      );

      if (result != null) {
        return Map<String, dynamic>.from(result);
      }
    } on PlatformException catch (e) {
      return <String, dynamic>{
        'matched': false,
        'confidence': 0.0,
        'message': 'Verification Error: ${e.message}',
      };
    }
    return <String, dynamic>{
      'matched': false,
      'confidence': 0.0,
      'message': 'Failed to execute native 1:1 verification',
    };
  }
}
