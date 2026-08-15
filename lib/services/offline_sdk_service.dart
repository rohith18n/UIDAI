import 'dart:async';
import 'package:flutter/services.dart';

/// Dart wrapper service interacting with the native Kotlin Fingerprint SDK via Platform Channels.
class OfflineSdkService {
  static const MethodChannel _channel =
      MethodChannel('com.yellowsense.uidai/fingerprint_sdk');

  /// Executes full 7-stage pipeline locally on device in native Kotlin (< 50ms).
  static Future<Map<String, dynamic>> processImageOffline(Uint8List imageBytes) async {
    try {
      final dynamic result = await _channel.invokeMethod(
        'processImageOffline',
        <String, dynamic>{
          'imageBytes': imageBytes,
        },
      );

      if (result is Map) {
        return _deepCastMap(result);
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

  /// Executes full 4-finger slap pipeline locally on device in native Kotlin (< 80ms).
  static Future<Map<String, dynamic>> processSlapOffline(
    Uint8List imageBytes, {
    String handSide = 'right',
  }) async {
    try {
      final dynamic result = await _channel.invokeMethod(
        'processSlapOffline',
        <String, dynamic>{
          'imageBytes': imageBytes,
          'handSide': handSide,
        },
      );

      if (result is Map) {
        return _deepCastMap(result);
      }
    } on PlatformException catch (e) {
      return <String, dynamic>{
        'success': false,
        'message': 'Platform Channel Error: ${e.message}',
        'total_execution_time_ms': 0,
        'error': 'Native processing error: ${e.message}',
      };
    }
    return <String, dynamic>{
      'success': false,
      'message': 'Unknown error executing offline slap SDK',
      'total_execution_time_ms': 0,
      'error': 'SDK execution failed',
    };
  }

  /// Verifies two minutiae templates 1:1 on-device (< 50ms matching target).
  static Future<Map<String, dynamic>> verifyOffline({
    required List<Map<String, dynamic>> minutiae1,
    required List<Map<String, dynamic>> minutiae2,
  }) async {
    try {
      final dynamic result = await _channel.invokeMethod(
        'verifyOffline',
        <String, dynamic>{
          'minutiae1': minutiae1,
          'minutiae2': minutiae2,
        },
      );

      if (result is Map) {
        return _deepCastMap(result);
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

  static Map<String, dynamic> _deepCastMap(Map map) {
    final out = <String, dynamic>{};
    map.forEach((k, v) {
      final sk = k.toString();
      if (v is Map) {
        out[sk] = _deepCastMap(v);
      } else if (v is List) {
        out[sk] = _deepCastList(v);
      } else {
        out[sk] = v;
      }
    });
    return out;
  }

  static List<dynamic> _deepCastList(List list) {
    return list.map((item) {
      if (item is Map) {
        return _deepCastMap(item);
      } else if (item is List) {
        return _deepCastList(item);
      }
      return item;
    }).toList();
  }
}
