import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import '../theme/app_theme.dart';
import '../widgets/fingerprint_camera_widget.dart';
import '../services/api_service.dart';
import '../models/capture_mode.dart';
import 'screens.dart' show ysShimmer, ysOfflineCard, regionDropdown;
import 'gesture_liveness_screen.dart';

class EnrollScreen extends StatefulWidget {
  final CaptureMode mode;
  const EnrollScreen({super.key, this.mode = CaptureMode.single});

  @override
  State<EnrollScreen> createState() => _EnrollScreenState();
}

class _EnrollScreenState extends State<EnrollScreen> {
  final _nameCtrl = TextEditingController();
  final _uidCtrl  = TextEditingController();
  String? _region;
  File?   _image;
  bool    _loading = false;
  Map<String, dynamic>? _result;
  bool _gesturePassed = false;
  String _handSide = 'right';
  static const bool _livenessEnabled = false;

  @override
  void dispose() { _nameCtrl.dispose(); _uidCtrl.dispose(); super.dispose(); }

  bool get _isSlap => widget.mode == CaptureMode.slap;

  Future<void> _enroll() async {
    if (_nameCtrl.text.trim().isEmpty || _uidCtrl.text.trim().isEmpty) {
      _snack('Fill all fields'); return;
    }
    if (_region == null) { _snack('Select a region'); return; }
    if (_image == null)  { _snack('Capture fingerprint first'); return; }
    setState(() { _loading = true; _result = null; });
    try {
      final r = _isSlap
          ? await ApiService.enrollSlap(
              image: _image!,
              name:  _nameCtrl.text.trim(),
              uid:   _uidCtrl.text.trim(),
              batch: _region!,
              handSide: _handSide,
            )
          : await ApiService.enrollPreprocessed(
              name:  _nameCtrl.text.trim(),
              uid:   _uidCtrl.text.trim(),
              batch: _region!,
              image: _image!,
            );
      setState(() { _result = r; _loading = false; });
      if (r['success'] == true || r['enrolled_fingers'] != null) {
        HapticFeedback.heavyImpact();
        _nameCtrl.clear(); _uidCtrl.clear();
        setState(() { _image = null; _region = null; _gesturePassed = false; });
      }
    } catch (e) {
      final isOffline = e.toString().contains('SocketException') ||
          e.toString().contains('Connection refused') ||
          e.toString().contains('timed out');
      setState(() {
        _result = {'success': false, 'error': e.toString(), 'offline': isOffline};
        _loading = false;
      });
    }
  }

  void _snack(String msg) => ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), backgroundColor: YS.red));

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: YS.bg,
      appBar: AppBar(
        leading: IconButton(icon: const Icon(Icons.arrow_back_rounded), onPressed: () => context.go('/')),
        title: Text(_isSlap ? 'Slap Enroll' : 'Enroll User',
            style: YS.label(17, w: FontWeight.w700)),
        bottom: PreferredSize(preferredSize: const Size.fromHeight(1),
            child: Container(height: 1, color: YS.stroke)),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          _badge(_isSlap ? 'SLAP ENROLLMENT' : 'FINGERPRINT ENROLLMENT',
              _isSlap ? YS.blue : YS.amber,
              _isSlap ? YS.blueBg : YS.amberSoft),
          const SizedBox(height: 20),
          _field(_nameCtrl, 'Full Name',   'e.g. Priya Sharma',   Icons.person_outline_rounded),
          const SizedBox(height: 12),
          _field(_uidCtrl,  'Aadhaar UID', 'e.g. 1234-5678-9012', Icons.badge_outlined),
          const SizedBox(height: 12),
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
          if (_livenessEnabled && !_gesturePassed)
            _livenessGate()
          else
            Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              if (_livenessEnabled) ...[
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  decoration: BoxDecoration(
                    color: YS.greenBg, borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: YS.green.withValues(alpha: 0.3)),
                  ),
                  child: Row(children: [
                    const Icon(Icons.verified_rounded, color: YS.green, size: 16),
                    const SizedBox(width: 8),
                    Text('Liveness check passed ✓',
                        style: YS.label(12, color: YS.green, w: FontWeight.w600)),
                    const Spacer(),
                    GestureDetector(
                      onTap: () => setState(() => _gesturePassed = false),
                      child: Text('Redo', style: YS.label(11, color: YS.green)),
                    ),
                  ]),
                ),
                const SizedBox(height: 10),
              ],
              FingerprintCameraWidget(
                onImageCaptured: (f) {
                  setState(() { _image = f; _result = null; });
                  ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                    content: Text(_isSlap ? 'Slap captured ✓' : 'Fingerprint captured ✓',
                        style: YS.label(13)),
                    backgroundColor: YS.green,
                    duration: const Duration(seconds: 2),
                  ));
                },
                disabled: _loading,
                mode: widget.mode,
                overlayStyle: _isSlap ? 'slap' : 'oval',
                handSide: _handSide,
              ),
            ]),
          const SizedBox(height: 20),
          if (_loading) ...[ysShimmer(height: 80), const SizedBox(height: 8)],
          if (!_loading && _result != null) ...[
            const SizedBox(height: 4),
            if (_result!['offline'] == true)
              ysOfflineCard(() => setState(() => _result = null))
            else
              _resultCard(_result!),
            const SizedBox(height: 16),
          ],
          ElevatedButton(
            onPressed: _loading ? null : _enroll,
            child: _loading
                ? const SizedBox(width: 18, height: 18,
                    child: CircularProgressIndicator(color: Colors.black, strokeWidth: 2))
                : Text(_isSlap ? 'Enroll Slap' : 'Enroll User'),
          ),
          const SizedBox(height: 40),
        ]),
      ),
    );
  }

  Widget _livenessGate() => Container(
    padding: const EdgeInsets.all(18),
    decoration: BoxDecoration(
      color: YS.amberSoft, borderRadius: BorderRadius.circular(16),
      border: Border.all(color: YS.amber.withValues(alpha: 0.4)),
    ),
    child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Row(children: [
        const Icon(Icons.back_hand_rounded, color: YS.amberDeep, size: 20),
        const SizedBox(width: 8),
        Text('Liveness Check Required',
            style: YS.label(14, color: YS.amberDeep, w: FontWeight.w700)),
      ]),
      const SizedBox(height: 6),
      Text('Complete the finger count challenge before capturing.',
          style: YS.label(12, color: YS.amberDeep)),
      const SizedBox(height: 14),
      ElevatedButton(
        onPressed: () => Navigator.of(context).push(MaterialPageRoute(
          builder: (_) => GestureLivenessScreen(
            onResult: (passed) {
              Navigator.of(context).pop();
              if (passed) setState(() => _gesturePassed = true);
            },
          ),
        )),
        child: const Text('Start Liveness Check'),
      ),
    ]),
  );

  Widget _field(TextEditingController c, String label, String hint, IconData icon) =>
      TextField(
        controller: c,
        style: YS.label(14),
        decoration: InputDecoration(
          labelText: label, hintText: hint,
          prefixIcon: Icon(icon, color: YS.inkLight, size: 18),
        ),
      );

  Widget _badge(String label, Color color, Color bg) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
    decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color.withValues(alpha: 0.3))),
    child: Text(label,
        style: YS.label(10, color: color, w: FontWeight.w700)
            .copyWith(letterSpacing: 1.5)),
  );

  Widget _handChip(String value, String label) {
    final sel = _handSide == value;
    return Expanded(
      child: GestureDetector(
        onTap: () => setState(() => _handSide = value),
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 12),
          decoration: BoxDecoration(
            color: sel ? YS.blueBg : YS.cardAlt,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: sel ? YS.blue : YS.stroke),
          ),
          child: Center(
              child: Text(label,
                  style: YS.label(13,
                      color: sel ? YS.blue : YS.inkMid,
                      w: FontWeight.w700))),
        ),
      ),
    );
  }

  Widget _resultCard(Map<String, dynamic> r) {
    final raw = r['enrolled_fingers'];
    final enrolledFingers = raw is List ? raw : null;
    final ok = r['success'] == true || enrolledFingers != null;
    final color = ok ? YS.green : YS.red;
    final bg    = ok ? YS.greenBg : YS.redBg;
    String msg  = ok
        ? (_isSlap
            ? '${enrolledFingers?.length ?? 0} finger(s) enrolled successfully!'
            : 'Enrolled successfully!')
        : (r['error'] ?? r['message'] ?? r['guidance'] ?? 'Enrollment failed');
    if (r['quality_failed'] == true) msg = r['guidance'] ?? 'Quality check failed';
    if (r['spoof_detected'] == true) msg = 'Spoof detected — use a live finger';
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(14),
          border: Border.all(color: color.withValues(alpha: 0.3))),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Icon(ok ? Icons.check_circle_rounded : Icons.error_rounded, color: color, size: 18),
          const SizedBox(width: 8),
          Expanded(child: Text(msg,
              style: YS.label(13, color: color, w: FontWeight.w600))),
        ]),
        if (ok) ...[
          const SizedBox(height: 10),
          if (_isSlap && enrolledFingers != null)
            ...enrolledFingers.map<Widget>((f) {
              final m = f is Map ? f : <String, dynamic>{};
              return _row(
                  (m['finger_position'] ?? '').toString().replaceAll('_', ' ').toUpperCase(),
                  '${m['minutiae_count'] ?? 0} minutiae',
                );
            })
          else ...[
            _row('Minutiae',  '${r['minutiae_count'] ?? 0}'),
            _row('Liveness',  (r['liveness'] is Map && r['liveness']['is_live'] == true) ? 'Live ✓' : 'Spoof'),
            _row('Detection', '${(((r['detection_conf'] ?? 0) as num) * 100).toStringAsFixed(1)}%'),
          ],
        ],
        if (r['issues'] != null && (r['issues'] is List) && (r['issues'] as List).isNotEmpty) ...[
          const SizedBox(height: 8),
          ...(r['issues'] as List).map((i) =>
              Text('• $i', style: YS.label(11, color: YS.orange))),
        ],
      ]),
    );
  }

  Widget _row(String k, String v) => Padding(
    padding: const EdgeInsets.only(bottom: 4),
    child: Row(children: [
      Text('$k: ', style: YS.label(12, color: YS.inkMid)),
      Text(v, style: YS.label(12, w: FontWeight.w700)),
    ]),
  );
}
