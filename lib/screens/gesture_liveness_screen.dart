import 'dart:io';
import 'dart:math';
import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../theme/app_theme.dart';
import '../services/api_service.dart';

class GestureLivenessScreen extends StatefulWidget {
  /// Called with true if challenge passed, false if failed/skipped
  final void Function(bool passed) onResult;

  const GestureLivenessScreen({super.key, required this.onResult});

  @override
  State<GestureLivenessScreen> createState() => _GestureLivenessScreenState();
}

class _GestureLivenessScreenState extends State<GestureLivenessScreen> {
  CameraController? _ctrl;
  bool _initializing = false;
  bool _live = false;
  bool _checking = false;
  String? _error;

  // Challenge
  late int _expectedCount;
  Map<String, dynamic>? _result;

  @override
  void initState() {
    super.initState();
    _expectedCount = Random().nextInt(5) + 1; // 1–5
    _startCamera();
  }

  @override
  void dispose() {
    _ctrl?.dispose();
    super.dispose();
  }

  Future<void> _startCamera() async {
    setState(() { _initializing = true; _error = null; });
    try {
      final cams = await availableCameras();
      if (cams.isEmpty) throw Exception('No camera found');
      // Use back camera for gesture liveness
      final cam = cams.firstWhere(
          (c) => c.lensDirection == CameraLensDirection.back,
          orElse: () => cams.first);
      _ctrl = CameraController(cam, ResolutionPreset.medium,
          enableAudio: false, imageFormatGroup: ImageFormatGroup.jpeg);
      await _ctrl!.initialize();
      if (mounted) setState(() { _live = true; _initializing = false; });
    } catch (e) {
      if (mounted) setState(() { _error = e.toString(); _initializing = false; });
    }
  }

  Future<void> _capture() async {
    if (_ctrl == null || !_ctrl!.value.isInitialized || _checking) return;
    setState(() { _checking = true; _result = null; });
    try {
      final xf  = await _ctrl!.takePicture();
      final file = File(xf.path);
      final r = await ApiService.livenessGesture(
          image: file, expectedCount: _expectedCount);
      if (mounted) {
        setState(() { _result = r; _checking = false; });
        if (r['passed'] == true) {
          HapticFeedback.heavyImpact();
          await Future.delayed(const Duration(milliseconds: 1200));
          widget.onResult(true);
        } else {
          HapticFeedback.vibrate();
        }
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _result = {'success': false, 'error': e.toString()};
          _checking = false;
        });
      }
    }
  }

  void _newChallenge() {
    setState(() {
      _expectedCount = Random().nextInt(5) + 1;
      _result = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: YS.bg,
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.close_rounded),
          onPressed: () => widget.onResult(false),
        ),
        title: Text('Liveness Check', style: YS.label(17, w: FontWeight.w700)),
        bottom: PreferredSize(
            preferredSize: const Size.fromHeight(1),
            child: Container(height: 1, color: YS.stroke)),
      ),
      body: Column(children: [
        // Challenge banner
        Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(vertical: 20, horizontal: 24),
          color: YS.amberSoft,
          child: Column(children: [
            Text('Show this many fingers',
                style: YS.label(13, color: YS.amberDeep)),
            const SizedBox(height: 8),
            Text('$_expectedCount',
                style: YS.display(64, color: YS.amberDeep, w: FontWeight.w800)),
            const SizedBox(height: 4),
            Text('Hold your hand up clearly in front of the camera',
                style: YS.label(12, color: YS.amberDeep),
                textAlign: TextAlign.center),
          ]),
        ),

        // Camera
        Expanded(
          child: Container(
            color: const Color(0xFF1A1A1A),
            child: _live && _ctrl != null && _ctrl!.value.isInitialized
                ? CameraPreview(_ctrl!)
                : _initializing
                    ? const Center(child: CircularProgressIndicator(
                        color: YS.amber, strokeWidth: 2))
                    : Center(child: Text(_error ?? 'Starting camera...',
                        style: YS.label(13, color: Colors.white54))),
          ),
        ),

        // Result + controls
        Container(
          color: YS.card,
          padding: const EdgeInsets.all(20),
          child: Column(children: [
            // Result card
            if (_result != null) ...[
              _resultCard(_result!),
              const SizedBox(height: 12),
            ],

            // Buttons
            if (_checking)
              Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(vertical: 16),
                decoration: BoxDecoration(
                  color: YS.amberSoft,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                  const SizedBox(width: 16, height: 16,
                      child: CircularProgressIndicator(
                          color: YS.amberDeep, strokeWidth: 2)),
                  const SizedBox(width: 10),
                  Text('Checking...', style: YS.label(14, color: YS.amberDeep, w: FontWeight.w600)),
                ]),
              )
            else if (_result?['passed'] != true) ...[
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed: _live ? _capture : null,
                  child: const Text('Capture & Check'),
                ),
              ),
              const SizedBox(height: 10),
              Row(children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: _newChallenge,
                    child: const Text('New Challenge'),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: OutlinedButton(
                    onPressed: () => widget.onResult(false),
                    child: const Text('Skip'),
                  ),
                ),
              ]),
            ],
          ]),
        ),
      ]),
    );
  }

  Widget _resultCard(Map<String, dynamic> r) {
    if (r['success'] != true) {
      return Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(color: YS.redBg, borderRadius: BorderRadius.circular(12),
            border: Border.all(color: YS.red.withValues(alpha: 0.3))),
        child: Text(r['error'] ?? 'Check failed', style: YS.label(13, color: YS.red)),
      );
    }
    final passed   = r['passed'] == true;
    final detected = r['detected_count'] ?? 0;
    final color    = passed ? YS.green : YS.red;
    final bg       = passed ? YS.greenBg : YS.redBg;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(12),
          border: Border.all(color: color.withValues(alpha: 0.3))),
      child: Row(children: [
        Icon(passed ? Icons.check_circle_rounded : Icons.cancel_rounded,
            color: color, size: 22),
        const SizedBox(width: 10),
        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(passed ? 'Challenge passed!' : 'Try again',
              style: YS.label(14, color: color, w: FontWeight.w700)),
          Text('Detected: $detected finger${detected == 1 ? '' : 's'} '
              '(expected: $_expectedCount)',
              style: YS.label(12, color: color)),
        ])),
      ]),
    );
  }
}
