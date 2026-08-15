import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import '../theme/app_theme.dart';
import '../widgets/fingerprint_camera_widget.dart';
import '../services/api_service.dart';
import '../models/capture_mode.dart';
import 'screens.dart' show ysShimmer, ysOfflineCard, regionDropdown;

class AuthenticateScreen extends StatefulWidget {
  final CaptureMode mode;
  const AuthenticateScreen({super.key, this.mode = CaptureMode.single});

  @override
  State<AuthenticateScreen> createState() => _AuthenticateScreenState();
}

class _AuthenticateScreenState extends State<AuthenticateScreen> {
  String? _region;
  bool _loading = false;
  Map<String, dynamic>? _result;
  String _handSide = 'right';

  bool get _isSlap => widget.mode == CaptureMode.slap;

  Future<void> _authenticate(File image) async {
    if (_region == null) {
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Select a region', style: YS.label(13)),
              backgroundColor: YS.red));
      return;
    }
    final sw = Stopwatch()..start();
    setState(() { _loading = true; _result = null; });
    try {
      final r = _isSlap
          ? await ApiService.authenticateSlap(
              batch: _region!, image: image, handSide: _handSide)
          : await ApiService.authenticatePreprocessed(batch: _region!, image: image);
      sw.stop();
      r['client_total_ms'] = sw.elapsedMilliseconds;
      setState(() { _result = r; _loading = false; });
      if (r['success'] == true) { HapticFeedback.heavyImpact(); }
      else { HapticFeedback.vibrate(); }
    } catch (e) {
      sw.stop();
      final isOffline = e.toString().contains('SocketException') ||
          e.toString().contains('Connection refused') ||
          e.toString().contains('timed out');
      setState(() {
        _result = {
          'success': false, 
          'error': e.toString(), 
          'offline': isOffline,
          'client_total_ms': sw.elapsedMilliseconds,
        };
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: YS.bg,
      appBar: AppBar(
        leading: IconButton(icon: const Icon(Icons.arrow_back_rounded), onPressed: () => context.go('/')),
        title: Text(_isSlap ? 'Slap Authenticate' : 'Authenticate',
            style: YS.label(17, w: FontWeight.w700)),
        bottom: PreferredSize(preferredSize: const Size.fromHeight(1),
            child: Container(height: 1, color: YS.stroke)),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(color: YS.greenBg, borderRadius: BorderRadius.circular(12),
                border: Border.all(color: YS.green.withValues(alpha: 0.3))),
            child: Row(children: [
              const Icon(Icons.info_outline_rounded, color: YS.green, size: 16),
              const SizedBox(width: 8),
              Expanded(child: Text(_isSlap
                      ? 'Matches all 4 fingers against enrolled slap users in batch'
                      : 'Matches against all enrolled users in the batch',
                  style: YS.label(12, color: YS.green))),
            ]),
          ),
          const SizedBox(height: 20),
          regionDropdown(
            value: _region,
            onChanged: (v) => setState(() => _region = v),
          ),
          if (_isSlap) ...[
            const SizedBox(height: 16),
            Text('HAND',
                style: YS.label(11, color: YS.inkLight, w: FontWeight.w700)
                    .copyWith(letterSpacing: 1.8)),
            const SizedBox(height: 8),
            Row(children: [
              _handChip('right', 'Right hand'),
              const SizedBox(width: 10),
              _handChip('left', 'Left hand'),
            ]),
          ],
          const SizedBox(height: 24),
          Text(_isSlap ? 'SLAP CAPTURE' : 'FINGERPRINT CAPTURE',
              style: YS.label(11, color: YS.inkLight, w: FontWeight.w700)
                  .copyWith(letterSpacing: 1.8)),
          const SizedBox(height: 10),
          FingerprintCameraWidget(
            onImageCaptured: _authenticate,
            disabled: _loading,
            mode: widget.mode,
            overlayStyle: _isSlap ? 'slap' : 'oval',
            handSide: _handSide,
          ),
          const SizedBox(height: 20),
          if (_loading) ...[ysShimmer(height: 80), const SizedBox(height: 8), ysShimmer(height: 60)],
          if (!_loading && _result != null) ...[const SizedBox(height: 16),
            if (_result!['offline'] == true)
              ysOfflineCard(() => setState(() => _result = null))
            else
              _resultCard(_result!)
          ],
          const SizedBox(height: 40),
        ]),
      ),
    );
  }

  Widget _handChip(String value, String label) {
    final sel = _handSide == value;
    return Expanded(
      child: GestureDetector(
        onTap: () => setState(() => _handSide = value),
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 12),
          decoration: BoxDecoration(
            color: sel ? YS.greenBg : YS.cardAlt,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: sel ? YS.green : YS.stroke),
          ),
          child: Center(
              child: Text(label,
                  style: YS.label(13,
                      color: sel ? YS.green : YS.inkMid,
                      w: FontWeight.w700))),
        ),
      ),
    );
  }

  Widget _resultCard(Map<String, dynamic> r) {
    final ok    = r['success'] == true;
    final color = ok ? YS.green : YS.red;
    final bg    = ok ? YS.greenBg : YS.redBg;
    String msg  = ok ? '' : (r['message'] ?? r['error'] ?? 'Not recognized');
    if (r['quality_failed'] == true) msg = r['guidance'] ?? 'Quality check failed';
    if (r['spoof_detected'] == true) msg = 'Spoof detected';
    final rawMatched = r['matched_fingers'];
    final matchedFingers = rawMatched is List ? rawMatched : null;
    final avgConf = r['avg_confidence'] ?? r['confidence'];
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(16),
          border: Border.all(color: color.withValues(alpha: 0.3))),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Icon(ok ? Icons.verified_rounded : Icons.cancel_rounded, color: color, size: 24),
          const SizedBox(width: 10),
          Text(ok ? 'AUTHENTICATED' : 'NOT RECOGNIZED',
              style: YS.display(16, color: color, w: FontWeight.w800)),
        ]),
        const SizedBox(height: 14),
        if (ok) ...[
          _row('Name', r['name'] ?? '—'),
          _row('UID', r['uid'] ?? '—'),
          if (avgConf != null)
            _row(
              'Confidence',
              '${((avgConf as num) * 100).toStringAsFixed(1)}%',
            ),
          if (r['minutiae_count'] != null)
            _row('Minutiae Extracted', '${r['minutiae_count']} points'),
          if (r['client_total_ms'] != null ||
              r['execution_time_ms'] != null ||
              r['total_execution_time_ms'] != null) ...[
            _row(
              'Complete Process Time',
              '${r['client_total_ms'] ?? r['total_execution_time_ms'] ?? r['execution_time_ms']} ms (${(((r['client_total_ms'] ?? r['total_execution_time_ms'] ?? r['execution_time_ms']) as num) / 1000.0).toStringAsFixed(2)}s)',
            ),
            if (r['total_execution_time_ms'] != null && r['client_total_ms'] != null && r['total_execution_time_ms'] != r['client_total_ms'])
              _row(
                'Model Pipeline Time',
                '${r['total_execution_time_ms']} ms',
              ),
          ],
          if (r['mode'] != null)
            _row(
              'Engine Mode',
              r['mode'] == 'offline_on_device'
                  ? 'Offline On-Device'
                  : 'Cloud Hybrid',
            ),
          if (matchedFingers != null && matchedFingers.isNotEmpty) ...[
            const SizedBox(height: 6),
            Text('Matched fingers:', style: YS.label(11, color: YS.inkMid)),
            const SizedBox(height: 4),
            ...matchedFingers.map<Widget>((f) {
              final m = f is Map ? f : <String, dynamic>{};
              return Padding(
                padding: const EdgeInsets.only(left: 8, bottom: 2),
                child: Text(
                  '•  ${(m['finger_position'] ?? m['matched_position'] ?? m['probe_position'] ?? '').toString().replaceAll('_', ' ').toUpperCase()}'
                  '  —  ${(((m['confidence'] ?? 0) as num) * 100).toStringAsFixed(1)}%',
                  style: YS.label(12, w: FontWeight.w600),
                ),
              );
            }),
          ],
        ] else
          Text(msg, style: YS.label(13, color: YS.inkMid)),
      ]),
    );
  }

  Widget _row(String k, String v) => Padding(
    padding: const EdgeInsets.only(bottom: 6),
    child: Row(children: [
      Text('$k: ', style: YS.label(13, color: YS.inkMid)),
      Text(v, style: YS.label(13, w: FontWeight.w700)),
    ]),
  );
}
