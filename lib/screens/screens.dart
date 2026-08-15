import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:shimmer/shimmer.dart';
import '../theme/app_theme.dart';
import '../widgets/fingerprint_camera_widget.dart';
import '../services/api_service.dart';
import '../models/capture_mode.dart';

const List<String> kIndiaRegions = [
  'Andhra Pradesh', 'Arunachal Pradesh', 'Assam', 'Bihar', 'Chhattisgarh',
  'Goa', 'Gujarat', 'Haryana', 'Himachal Pradesh', 'Jharkhand', 'Karnataka',
  'Kerala', 'Madhya Pradesh', 'Maharashtra', 'Manipur', 'Meghalaya', 'Mizoram',
  'Nagaland', 'Odisha', 'Punjab', 'Rajasthan', 'Sikkim', 'Tamil Nadu',
  'Telangana', 'Tripura', 'Uttar Pradesh', 'Uttarakhand', 'West Bengal',
  'Andaman & Nicobar Islands', 'Chandigarh',
  'Dadra & Nagar Haveli and Daman & Diu', 'Delhi', 'Jammu & Kashmir',
  'Ladakh', 'Lakshadweep', 'Puducherry',
];

Widget regionDropdown({
  required String? value,
  required ValueChanged<String?> onChanged,
}) =>
    DropdownButtonFormField<String>(
      initialValue: value,
      decoration: InputDecoration(
        labelText: 'Region / State',
        hintText: 'Select state or UT',
        prefixIcon: const Icon(Icons.location_on_outlined, size: 18),
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
      ),
      isExpanded: true,
      items: kIndiaRegions
          .map((r) => DropdownMenuItem(value: r, child: Text(r)))
          .toList(),
      onChanged: onChanged,
    );

Widget ysShimmer({double height = 80, double? width, double radius = 14}) =>
    Shimmer.fromColors(
      baseColor: YS.stroke,
      highlightColor: YS.cardAlt,
      child: Container(
        width: width,
        height: height,
        decoration: BoxDecoration(
          color: YS.card,
          borderRadius: BorderRadius.circular(radius),
        ),
      ),
    );

Widget ysOfflineCard(VoidCallback onRetry) => Container(
  padding: const EdgeInsets.all(24),
  decoration: BoxDecoration(
    color: YS.card,
    borderRadius: BorderRadius.circular(16),
    border: Border.all(color: YS.stroke),
  ),
  child: Column(children: [
    const Icon(Icons.wifi_off_rounded, size: 40, color: YS.inkLight),
    const SizedBox(height: 12),
    Text('Cannot reach server', style: YS.label(14, color: YS.inkMid, w: FontWeight.w600)),
    const SizedBox(height: 4),
    Text('Check Settings → Server URLs', style: YS.label(12, color: YS.inkLight)),
    const SizedBox(height: 16),
    SizedBox(
      width: double.infinity,
      child: ElevatedButton(
        onPressed: onRetry,
        child: const Text('Retry'),
      ),
    ),
  ]),
);

// ══════════════════════════════════════════════════════════════════════════════
// VERIFY  1:1  (mode-aware)
// ══════════════════════════════════════════════════════════════════════════════

class VerifyScreen extends StatefulWidget {
  final CaptureMode mode;
  const VerifyScreen({super.key, this.mode = CaptureMode.single});

  @override
  State<VerifyScreen> createState() => _VerifyScreenState();
}

class _VerifyScreenState extends State<VerifyScreen> {
  final _uidCtrl = TextEditingController();
  String? _region;
  bool _loading = false;
  Map<String, dynamic>? _result;
  String _handSide = 'right';

  @override
  void dispose() { _uidCtrl.dispose(); super.dispose(); }

  bool get _isSlap => widget.mode == CaptureMode.slap;

  Future<void> _verify(File image) async {
    if (_uidCtrl.text.trim().isEmpty || _region == null) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('Enter UID and select region', style: YS.label(13)),
          backgroundColor: YS.red));
      return;
    }
    setState(() { _loading = true; _result = null; });
    try {
      final r = _isSlap
          ? await ApiService.verifySlap(
              uid: _uidCtrl.text.trim(),
              batch: _region!,
              image: image,
              handSide: _handSide)
          : await ApiService.verify(
              uid: _uidCtrl.text.trim(),
              batch: _region!,
              image: image);
      setState(() { _result = r; _loading = false; });
      if (r['matched'] == true) { HapticFeedback.heavyImpact(); }
      else { HapticFeedback.vibrate(); }
    } catch (e) {
      final msg = e.toString();
      final isOffline = msg.contains('SocketException') ||
          msg.contains('Connection refused') ||
          msg.contains('timed out');
      setState(() {
        _result = {'success': false, 'error': e.toString(), 'offline': isOffline};
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
        title: Text(_isSlap ? 'Slap Verify' : 'Verify Identity',
            style: YS.label(17, w: FontWeight.w700)),
        bottom: PreferredSize(preferredSize: const Size.fromHeight(1),
            child: Container(height: 1, color: YS.stroke)),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(color: YS.blueBg, borderRadius: BorderRadius.circular(12),
                border: Border.all(color: YS.blue.withValues(alpha: 0.3))),
            child: Row(children: [
              const Icon(Icons.info_outline_rounded, color: YS.blue, size: 16),
              const SizedBox(width: 8),
              Expanded(child: Text(_isSlap
                      ? 'Verifies slap fingerprint against a specific Aadhaar UID'
                      : 'Verifies fingerprint against a specific Aadhaar UID',
                  style: YS.label(12, color: YS.blue))),
            ]),
          ),
          const SizedBox(height: 20),
          regionDropdown(
            value: _region,
            onChanged: (v) => setState(() => _region = v),
          ),
          const SizedBox(height: 12),
          TextField(controller: _uidCtrl, style: YS.label(14),
            decoration: InputDecoration(labelText: 'Aadhaar UID',
                prefixIcon: Icon(Icons.badge_outlined, color: YS.inkLight, size: 18))),
          if (_isSlap) ...[
            const SizedBox(height: 16),
            Text('HAND',
                style: YS.label(11, color: YS.inkLight, w: FontWeight.w700)
                    .copyWith(letterSpacing: 1.8)),
            const SizedBox(height: 8),
            Row(children: [
              _handChip('right', 'Right hand', YS.blueBg, YS.blue),
              const SizedBox(width: 10),
              _handChip('left', 'Left hand', YS.blueBg, YS.blue),
            ]),
          ],
          const SizedBox(height: 24),
          Text(_isSlap ? 'SLAP CAPTURE' : 'FINGERPRINT CAPTURE',
              style: YS.label(11, color: YS.inkLight, w: FontWeight.w700)
                  .copyWith(letterSpacing: 1.8)),
          const SizedBox(height: 10),
          FingerprintCameraWidget(
            onImageCaptured: _verify,
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

  Widget _handChip(String value, String label, Color bg, Color color) {
    final sel = _handSide == value;
    return Expanded(
      child: GestureDetector(
        onTap: () => setState(() => _handSide = value),
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 12),
          decoration: BoxDecoration(
            color: sel ? bg : YS.cardAlt,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: sel ? color : YS.stroke),
          ),
          child: Center(
              child: Text(label,
                  style: YS.label(13,
                      color: sel ? color : YS.inkMid,
                      w: FontWeight.w700))),
        ),
      ),
    );
  }

  Widget _resultCard(Map<String, dynamic> r) {
    final ok    = r['success'] == true && r['matched'] == true;
    final color = ok ? YS.green : YS.red;
    final bg    = ok ? YS.greenBg : YS.redBg;
    final score = (r['confidence'] ?? r['avg_confidence'] ?? 0.0) as num;
    String msg  = r['error'] ?? '';
    if (r['quality_failed'] == true) msg = r['guidance'] ?? 'Quality failed';
    if (r['spoof_detected'] == true) msg = 'Spoof detected';
    final raw = r['matched_fingers'];
    final matchedFingers = raw is List ? raw : null;
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(16),
          border: Border.all(color: color.withValues(alpha: 0.3))),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Icon(ok ? Icons.verified_rounded : Icons.cancel_rounded, color: color, size: 24),
          const SizedBox(width: 10),
          Text(ok ? 'IDENTITY VERIFIED' : 'MISMATCH',
              style: YS.display(16, color: color, w: FontWeight.w800)),
        ]),
        const SizedBox(height: 14),
        if (r['success'] == true) ...[
          _row('Name', r['name'] ?? '—'),
          _row('UID',  r['uid']  ?? '—'),
          const SizedBox(height: 10),
          Text('Match Score', style: YS.label(11, color: YS.inkLight, w: FontWeight.w600)
              .copyWith(letterSpacing: 0.5)),
          const SizedBox(height: 6),
          ClipRRect(borderRadius: BorderRadius.circular(6),
            child: LinearProgressIndicator(value: score.toDouble().clamp(0, 1),
                backgroundColor: YS.stroke, color: color, minHeight: 8)),
          const SizedBox(height: 4),
          Text('${(score * 100).toStringAsFixed(1)}%  (threshold 25%)',
              style: YS.label(11, color: YS.inkLight)),
          if (matchedFingers != null && matchedFingers.isNotEmpty) ...[
            const SizedBox(height: 12),
            Text('Matched fingers:', style: YS.label(11, color: YS.inkMid)),
            const SizedBox(height: 4),
            ...matchedFingers.map<Widget>((f) => Padding(
                  padding: const EdgeInsets.only(left: 8, bottom: 2),
                  child: Text('•  ${(f['finger_position'] ?? f['matched_position'] ?? f['probe_position'] ?? '').toString().replaceAll('_', ' ').toUpperCase()}'
                      '  —  ${(((f['confidence'] ?? 0) as num) * 100).toStringAsFixed(1)}%',
                      style: YS.label(12, w: FontWeight.w600)),
                )),
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

// ══════════════════════════════════════════════════════════════════════════════
// QC SCREEN  (mode-aware)
// ══════════════════════════════════════════════════════════════════════════════

class QcScreen extends StatefulWidget {
  final CaptureMode mode;
  const QcScreen({super.key, this.mode = CaptureMode.single});

  @override
  State<QcScreen> createState() => _QcScreenState();
}

class _QcScreenState extends State<QcScreen> {
  bool _loading = false;
  Map<String, dynamic>? _result;
  Map<String, dynamic>? _readiness;
  String _handSide = 'right';

  bool get _isSlap => widget.mode == CaptureMode.slap;

  Future<void> _run(File image) async {
    setState(() { _loading = true; _result = null; _readiness = null; });
    try {
      final results = _isSlap
          ? [await ApiService.processSlap(image: image, handSide: _handSide, vis: true)]
          : await Future.wait([
              ApiService.process(image),
              ApiService.readiness(image),
            ]);
      setState(() {
        if (_isSlap) {
          _result = results[0];
        } else {
          _result    = results[0];
          _readiness = results[1];
        }
        _loading   = false;
      });
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: YS.bg,
      appBar: AppBar(
        leading: IconButton(icon: const Icon(Icons.arrow_back_rounded), onPressed: () => context.go('/')),
        title: Text('QC Pipeline', style: YS.label(17, w: FontWeight.w700)),
        bottom: PreferredSize(preferredSize: const Size.fromHeight(1),
            child: Container(height: 1, color: YS.stroke)),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          if (_isSlap) ...[
            Text('HAND',
                style: YS.label(11, color: YS.inkLight, w: FontWeight.w700)
                    .copyWith(letterSpacing: 1.8)),
            const SizedBox(height: 8),
            Row(children: [
              _qcHandChip('right', 'Right hand'),
              const SizedBox(width: 10),
              _qcHandChip('left', 'Left hand'),
            ]),
            const SizedBox(height: 16),
          ],
          FingerprintCameraWidget(
            onImageCaptured: _run,
            disabled: _loading,
            mode: widget.mode,
            overlayStyle: _isSlap ? 'slap' : 'oval',
            handSide: _handSide,
          ),
          const SizedBox(height: 20),
          if (_loading) ...[ysShimmer(height: 80), const SizedBox(height: 8), ysShimmer(height: 200)],
          if (!_loading && _result?['offline'] == true) ...[const SizedBox(height: 16),
            ysOfflineCard(() => setState(() { _result = null; _readiness = null; }))],
          if (!_loading && _readiness != null) ...[const SizedBox(height: 16), _readinessCard(_readiness!)],
          if (!_loading && _result != null && _result!['offline'] != true) ...[
            const SizedBox(height: 16),
            _isSlap ? _slapQcCard(_result!) : _qcCard(_result!),
          ],
          const SizedBox(height: 40),
        ]),
      ),
    );
  }

  Widget _qcHandChip(String value, String label) {
    final sel = _handSide == value;
    return Expanded(
      child: GestureDetector(
        onTap: () => setState(() => _handSide = value),
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 12),
          decoration: BoxDecoration(
            color: sel ? YS.orangeBg : YS.cardAlt,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: sel ? YS.orange : YS.stroke),
          ),
          child: Center(child: Text(label,
              style: YS.label(13, color: sel ? YS.orange : YS.inkMid, w: FontWeight.w700))),
        ),
      ),
    );
  }

  Widget _readinessCard(Map<String, dynamic> r) {
    final score = (r['readiness_score'] as num?)?.toInt() ?? 0;
    final grade = r['grade'] as String? ?? '—';
    final breakdown = r['breakdown'] as Map<String, dynamic>? ?? {};
    final gradeColor = grade == 'Excellent' ? YS.green
        : grade == 'Good'     ? YS.green
        : grade == 'Marginal' ? YS.orange
        : YS.red;
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: YS.card, borderRadius: BorderRadius.circular(16),
        border: Border.all(color: YS.stroke), boxShadow: YS.cardShadow,
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
          Text('Readiness Score', style: YS.display(16, w: FontWeight.w700)),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
            decoration: BoxDecoration(
              color: gradeColor.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: gradeColor.withValues(alpha: 0.3)),
            ),
            child: Text(grade, style: YS.label(12, color: gradeColor, w: FontWeight.w700)),
          ),
        ]),
        const SizedBox(height: 16),
        Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
          Text('$score', style: YS.display(40, color: gradeColor, w: FontWeight.w800)),
          Padding(padding: const EdgeInsets.only(bottom: 6, left: 4),
            child: Text('/100', style: YS.label(14, color: YS.inkLight))),
        ]),
        const SizedBox(height: 10),
        ClipRRect(
          borderRadius: BorderRadius.circular(6),
          child: LinearProgressIndicator(
            value: score / 100.0,
            minHeight: 8,
            backgroundColor: YS.stroke,
            color: gradeColor,
          ),
        ),
        const SizedBox(height: 16),
        Row(children: [
          _miniStat('Blur',       '${breakdown['blur'] ?? '—'}'),
          _miniStat('Brightness', '${breakdown['brightness'] ?? '—'}'),
          _miniStat('Glare',      breakdown['glare'] == true ? 'Yes' : 'No'),
          _miniStat('Minutiae',   '${breakdown['minutiae'] ?? '—'}'),
        ]),
      ]),
    );
  }

  Widget _miniStat(String k, String v) => Expanded(
    child: Container(
      margin: const EdgeInsets.only(right: 8),
      padding: const EdgeInsets.symmetric(vertical: 10),
      decoration: BoxDecoration(
        color: YS.cardAlt, borderRadius: BorderRadius.circular(10)),
      child: Column(children: [
        Text(v, style: YS.label(13, w: FontWeight.w700)),
        const SizedBox(height: 2),
        Text(k, style: YS.label(10, color: YS.inkLight)),
      ]),
    ),
  );

  Widget _qcCard(Map<String, dynamic> r) {
    if (r['success'] != true) {
      return Container(padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(color: YS.redBg, borderRadius: BorderRadius.circular(14),
            border: Border.all(color: YS.red.withValues(alpha: 0.3))),
        child: Text('Error: ${r['error']}', style: YS.label(13, color: YS.red)));
    }
    final qc       = r['quality']  as Map<String, dynamic>? ?? {};
    final liveness = r['liveness'] as Map<String, dynamic>? ?? {};
    final qcPassed = qc['passed'] == true;
    final isLive   = liveness['is_live'] == true;
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(color: YS.card, borderRadius: BorderRadius.circular(16),
          border: Border.all(color: YS.stroke), boxShadow: YS.cardShadow),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('Pipeline Results', style: YS.display(16, w: FontWeight.w700)),
        const SizedBox(height: 16),
        _qcRow('Quality Gate',   qcPassed ? 'PASSED' : 'FAILED',   qcPassed ? YS.green : YS.red),
        if (!qcPassed && qc['guidance'] != null)
          Padding(padding: const EdgeInsets.only(left: 16, bottom: 8),
            child: Text('→ ${qc['guidance']}', style: YS.label(12, color: YS.orange))),
        _qcRow('Blur Score',  '${qc['blur']?['blur_score'] ?? '—'}',  YS.inkMid),
        _qcRow('Brightness',  '${qc['brightness']?['brightness'] ?? '—'}', YS.inkMid),
        _qcRow('Glare',       qc['glare']?['has_glare'] == true ? 'Detected' : 'None',
            qc['glare']?['has_glare'] == true ? YS.red : YS.green),
        Divider(color: YS.stroke, height: 24),
        _qcRow('Detection',   '${((r['detection_conf'] ?? 0) * 100).toStringAsFixed(1)}%', YS.inkMid),
        _qcRow('Liveness',    isLive ? 'LIVE' : 'SPOOF', isLive ? YS.green : YS.red),
        _qcRow('Liveness Conf', '${((liveness['confidence'] ?? 0) * 100).toStringAsFixed(1)}%', YS.inkMid),
        Divider(color: YS.stroke, height: 24),
        _qcRow('Minutiae',    '${r['minutiae_count'] ?? 0}', YS.amber),
      ]),
    );
  }

  Widget _slapQcCard(Map<String, dynamic> r) {
    final rawF = r['fingers'];
    final fingers = (rawF is List ? rawF.whereType<Map>().toList() : <Map>[]);
    final count = r['finger_count'] ?? 0;
    if (count == 0) {
      return Container(padding: const EdgeInsets.all(18),
        decoration: BoxDecoration(color: YS.redBg, borderRadius: BorderRadius.circular(14),
            border: Border.all(color: YS.red.withValues(alpha: 0.3))),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: const [
            Icon(Icons.error_outline_rounded, color: YS.red, size: 20),
            SizedBox(width: 8),
            Text('No fingers detected', style: TextStyle(color: YS.red, fontSize: 15, fontWeight: FontWeight.w800)),
          ]),
          const SizedBox(height: 6),
          Text(r['error'] ?? 'Move closer and present your fingers to the camera.',
              style: YS.label(12, color: YS.inkMid)),
        ]),
      );
    }
    final totalMinutiae = fingers.fold<int>(0, (s, f) => s + ((f['minutiae_count'] ?? 0) as int));
    final allLive = fingers.every((f) => (f['liveness'] as Map?)?['is_live'] == true);
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(color: YS.card, borderRadius: BorderRadius.circular(16),
          border: Border.all(color: YS.stroke), boxShadow: YS.cardShadow),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('Slap Pipeline Results', style: YS.display(16, w: FontWeight.w700)),
        const SizedBox(height: 12),
        Row(children: [
          _statPill('$count fingers', YS.amberDeep, YS.amberSoft),
          const SizedBox(width: 8),
          _statPill('$totalMinutiae total min', YS.orange, YS.orangeBg),
          const SizedBox(width: 8),
          _statPill(allLive ? 'ALL LIVE' : 'SPOOF MIX',
              allLive ? YS.green : YS.red, allLive ? YS.greenBg : YS.redBg),
        ]),
        const SizedBox(height: 14),
        ...fingers.map<Widget>((f) => _fingerQcRow(f)),
      ]),
    );
  }

  Widget _statPill(String text, Color color, Color bg) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
    decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(20)),
    child: Text(text, style: YS.label(11, color: color, w: FontWeight.w700)),
  );

  Widget _fingerQcRow(Map f) {
    final pos = (f['finger_position'] ?? '—').toString().replaceAll('_', ' ');
    final conf = (((f['detection_conf'] ?? 0) as num) * 100).toStringAsFixed(0);
    final mins = f['minutiae_count'] ?? 0;
    final live = (f['liveness'] as Map?)?['is_live'] == true;
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(color: YS.cardAlt, borderRadius: BorderRadius.circular(10)),
      child: Row(children: [
        Icon(Icons.fingerprint_rounded, size: 16, color: YS.amber),
        const SizedBox(width: 8),
        Expanded(child: Text(pos.toUpperCase(), style: YS.label(13, w: FontWeight.w700))),
        Text('$conf%', style: YS.label(11, color: YS.inkLight)),
        const SizedBox(width: 12),
        Text('$mins min', style: YS.label(11, color: YS.amberDeep, w: FontWeight.w700)),
        const SizedBox(width: 12),
        Text(live ? 'LIVE' : 'SPOOF',
            style: YS.label(11, color: live ? YS.green : YS.red, w: FontWeight.w700)),
      ]),
    );
  }

  Widget _qcRow(String k, String v, Color vc) => Padding(
    padding: const EdgeInsets.only(bottom: 10),
    child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
      Text(k, style: YS.label(13, color: YS.inkMid)),
      Text(v, style: YS.label(13, color: vc, w: FontWeight.w700)),
    ]),
  );
}

// ══════════════════════════════════════════════════════════════════════════════
// HISTORY  (unified: Single / Slap / All tabs)
// ══════════════════════════════════════════════════════════════════════════════

class HistoryScreen extends StatefulWidget {
  const HistoryScreen({super.key});

  @override
  State<HistoryScreen> createState() => _HistoryScreenState();
}

class _HistoryScreenState extends State<HistoryScreen> with SingleTickerProviderStateMixin {
  late TabController _tabCtrl;
  String? _region;
  List<dynamic> _singleHistory = [];
  List<dynamic> _slapHistory = [];
  bool _loading = false;
  bool _offline = false;

  @override
  void initState() {
    super.initState();
    _tabCtrl = TabController(length: 3, vsync: this);
  }

  @override
  void dispose() {
    _tabCtrl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() { _loading = true; _offline = false; });
    try {
      final results = await Future.wait([
        ApiService.getHistory(batch: _region ?? ''),
        ApiService.getSlapHistory(batch: _region ?? ''),
      ]);
      setState(() {
        _singleHistory = results[0];
        _slapHistory = results[1];
        _loading = false;
      });
    } catch (e) {
      final isOffline = e.toString().contains('SocketException') ||
          e.toString().contains('Connection refused') ||
          e.toString().contains('timed out');
      setState(() { _loading = false; _offline = isOffline; });
    }
  }

  List<dynamic> get _visibleList {
    switch (_tabCtrl.index) {
      case 0: return [..._singleHistory, ..._slapHistory]..sort((a, b) {
          final ta = a['timestamp'] ?? '';
          final tb = b['timestamp'] ?? '';
          return tb.toString().compareTo(ta.toString());
        });
      case 1: return _singleHistory;
      case 2: return _slapHistory;
      default: return [];
    }
  }

  bool _isSlapEntry(Map h) => h['type'] == 'slap' || h.containsKey('matched_fingers') || h.containsKey('finger_count');

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: YS.bg,
      appBar: AppBar(
        leading: IconButton(icon: const Icon(Icons.arrow_back_rounded), onPressed: () => context.go('/')),
        title: Text('Auth History', style: YS.label(17, w: FontWeight.w700)),
        bottom: PreferredSize(preferredSize: const Size.fromHeight(48),
          child: Column(children: [
            Container(height: 1, color: YS.stroke),
            TabBar(
              controller: _tabCtrl,
              onTap: (_) => setState(() {}),
              labelColor: YS.amberDeep,
              unselectedLabelColor: YS.inkLight,
              indicatorColor: YS.amber,
              labelStyle: YS.label(12, w: FontWeight.w700),
              unselectedLabelStyle: YS.label(12, w: FontWeight.w600),
              tabs: const [
                Tab(text: 'All'),
                Tab(text: 'Single'),
                Tab(text: 'Slap'),
              ],
            ),
          ]),
        ),
      ),
      body: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(children: [
          Row(children: [
            Expanded(child: regionDropdown(
              value: _region,
              onChanged: (v) => setState(() => _region = v),
            )),
            const SizedBox(width: 12),
            ElevatedButton(onPressed: _load, child: const Text('Load')),
          ]),
          const SizedBox(height: 16),
          if (_loading) ...[const SizedBox(height: 8), ysShimmer(height: 70), const SizedBox(height: 8), ysShimmer(height: 70), const SizedBox(height: 8), ysShimmer(height: 70)],
          const SizedBox(height: 8),
          Expanded(
            child: _offline
                ? ysOfflineCard(_load)
                : _visibleList.isEmpty && !_loading
                    ? Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
                        const Icon(Icons.history_rounded, size: 48, color: YS.inkFaint),
                        const SizedBox(height: 12),
                        Text('No records yet', style: YS.label(14, color: YS.inkLight)),
                        const SizedBox(height: 4),
                        Text('Tap Load to fetch history', style: YS.label(12, color: YS.inkFaint)),
                      ]))
                    : ListView.separated(
                        itemCount: _visibleList.length,
                        separatorBuilder: (_, s) => Divider(color: YS.stroke, height: 1),
                        itemBuilder: (_, i) {
                          final h = _visibleList[i] as Map<String, dynamic>;
                          final isSlap = _isSlapEntry(h);
                          final conf = ((((h['avg_confidence'] ?? h['confidence']) ?? 0) as num) * 100).toStringAsFixed(1);
                          final rawM = h['matched_fingers'];
                          final matchedCount = rawM is List ? rawM.length : null;
                          return ListTile(
                            contentPadding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
                            leading: Container(width: 40, height: 40,
                              decoration: BoxDecoration(
                                  color: isSlap ? YS.blueBg : YS.amberSoft,
                                  borderRadius: BorderRadius.circular(10)),
                              child: Icon(
                                  isSlap ? Icons.back_hand_rounded : Icons.fingerprint_rounded,
                                  color: isSlap ? YS.blue : YS.amber, size: 20)),
                            title: Row(children: [
                              Text(h['name'] ?? '—', style: YS.label(14, w: FontWeight.w700)),
                              const SizedBox(width: 8),
                              Container(
                                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                decoration: BoxDecoration(
                                  color: isSlap ? YS.blueBg : YS.amberSoft,
                                  borderRadius: BorderRadius.circular(8),
                                ),
                                child: Text(isSlap ? 'SLAP' : 'SINGLE',
                                    style: YS.label(8,
                                        color: isSlap ? YS.blue : YS.amberDeep,
                                        w: FontWeight.w800)),
                              ),
                            ]),
                            subtitle: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                const SizedBox(height: 2),
                                Text('${h['uid'] ?? '—'} · $conf% confidence'
                                    '${matchedCount != null ? ' · $matchedCount fingers' : ''}',
                                    style: YS.label(12, color: YS.inkMid)),
                              ],
                            ),
                            trailing: Text(h['timestamp']?.toString().substring(0, 16) ?? '',
                                style: YS.label(10, color: YS.inkLight)),
                          );
                        }),
          ),
        ]),
      ),
    );
  }
}

// ══════════════════════════════════════════════════════════════════════════════
// SETTINGS  (dual URL: single + slap)
// ══════════════════════════════════════════════════════════════════════════════

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  late final TextEditingController _singleUrlCtrl =
      TextEditingController(text: ApiService.singleUrl);
  late final TextEditingController _slapUrlCtrl =
      TextEditingController(text: ApiService.slapUrl);
  bool _checkingSingle = false;
  bool _checkingSlap = false;
  Map<String, dynamic>? _healthSingle;
  Map<String, dynamic>? _healthSlap;

  Future<void> _save() async {
    await ApiService.setSingleUrl(_singleUrlCtrl.text.trim());
    await ApiService.setSlapUrl(_slapUrlCtrl.text.trim());
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('Both URLs saved', style: YS.label(13)),
          backgroundColor: YS.green));
    }
  }

  Future<void> _check(bool slap) async {
    if (slap) {
      setState(() { _checkingSlap = true; _healthSlap = null; });
    } else {
      setState(() { _checkingSingle = true; _healthSingle = null; });
    }
    try {
      final h = await ApiService.healthCheck(slap: slap);
      if (mounted) {
        if (slap) {
          setState(() { _healthSlap = h; _checkingSlap = false; });
        } else {
          setState(() { _healthSingle = h; _checkingSingle = false; });
        }
      }
    } catch (e) {
      if (mounted) {
        if (slap) {
          setState(() { _healthSlap = {'error': e.toString()}; _checkingSlap = false; });
        } else {
          setState(() { _healthSingle = {'error': e.toString()}; _checkingSingle = false; });
        }
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: YS.bg,
      appBar: AppBar(
        leading: IconButton(icon: const Icon(Icons.arrow_back_rounded), onPressed: () => context.go('/')),
        title: Text('Settings', style: YS.label(17, w: FontWeight.w700)),
        bottom: PreferredSize(preferredSize: const Size.fromHeight(1),
            child: Container(height: 1, color: YS.stroke)),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text('SERVERS', style: YS.label(11, color: YS.inkLight, w: FontWeight.w700)
              .copyWith(letterSpacing: 1.8)),
          const SizedBox(height: 12),
          _urlCard(
            title: 'Single-Finger Backend',
            subtitle: 'Enroll / Auth / Verify — one finger at a time',
            icon: Icons.fingerprint_rounded,
            color: YS.amber,
            bg: YS.amberSoft,
            ctrl: _singleUrlCtrl,
            checking: _checkingSingle,
            health: _healthSingle,
            onCheck: () => _check(false),
          ),
          const SizedBox(height: 16),
          _urlCard(
            title: 'Slap (Multi-Finger) Backend',
            subtitle: '4-finger slap capture, aggregate matching',
            icon: Icons.back_hand_rounded,
            color: YS.blue,
            bg: YS.blueBg,
            ctrl: _slapUrlCtrl,
            checking: _checkingSlap,
            health: _healthSlap,
            onCheck: () => _check(true),
          ),
          const SizedBox(height: 20),
          ElevatedButton(onPressed: _save, child: const Text('Save All URLs')),
          const SizedBox(height: 32),
          Text('ABOUT', style: YS.label(11, color: YS.inkLight, w: FontWeight.w700)
              .copyWith(letterSpacing: 1.8)),
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(color: YS.card, borderRadius: BorderRadius.circular(16),
                border: Border.all(color: YS.stroke), boxShadow: YS.cardShadow),
            child: Column(children: [
              Image.asset('assets/images/logo11.png', height: 36, fit: BoxFit.contain),
              const SizedBox(height: 16),
              Divider(color: YS.stroke),
              const SizedBox(height: 12),
              _infoRow('Company',  'YellowSense Technologies'),
              _infoRow('Project',  'UIDAI SITAA Cohort 1'),
              _infoRow('Pipeline', 'YOLO → Liveness → U²Net → ZeroDCE → MinutiaeNet'),
              _infoRow('Matching', 'MCC Graph + Relaxation Labeling + Slap Aggregate'),
              _infoRow('Version',  '2.0.0 (Unified)'),
            ]),
          ),
          const SizedBox(height: 40),
        ]),
      ),
    );
  }

  Widget _urlCard({
    required String title,
    required String subtitle,
    required IconData icon,
    required Color color,
    required Color bg,
    required TextEditingController ctrl,
    required bool checking,
    Map<String, dynamic>? health,
    required VoidCallback onCheck,
  }) => Container(
    padding: const EdgeInsets.all(16),
    decoration: BoxDecoration(
      color: YS.card,
      borderRadius: BorderRadius.circular(16),
      border: Border.all(color: YS.stroke),
      boxShadow: YS.cardShadow,
    ),
    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        Container(width: 36, height: 36,
          decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(10)),
          child: Icon(icon, color: color, size: 18)),
        const SizedBox(width: 10),
        Expanded(child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: YS.label(14, w: FontWeight.w700)),
            Text(subtitle, style: YS.label(11, color: YS.inkLight)),
          ],
        )),
      ]),
      const SizedBox(height: 12),
      TextField(controller: ctrl, style: YS.label(13),
        decoration: InputDecoration(
          labelText: 'Server URL',
          hintText: 'http://IP:PORT',
          prefixIcon: Icon(Icons.dns_outlined, color: YS.inkLight, size: 18),
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
          contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
        )),
      const SizedBox(height: 8),
      OutlinedButton(
        onPressed: checking ? null : onCheck,
        child: checking
            ? SizedBox(width: 14, height: 14,
                child: CircularProgressIndicator(color: color, strokeWidth: 2))
            : const Text('Check Health'),
      ),
      if (health != null) ...[const SizedBox(height: 10), _miniHealthCard(health, color)],
    ]),
  );

  Widget _miniHealthCard(Map<String, dynamic> h, Color color) {
    final ok = h['status'] == 'ok' || h['error'] == null;
    final actualColor = h['error'] != null ? YS.red : YS.green;
    final bg = h['error'] != null ? YS.redBg : YS.greenBg;
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(10),
          border: Border.all(color: actualColor.withValues(alpha: 0.3))),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Icon(ok ? Icons.check_circle_rounded : Icons.error_rounded,
              color: actualColor, size: 14),
          const SizedBox(width: 6),
          Text(h['error'] != null ? 'Unreachable' : 'Server Online',
              style: YS.label(12, color: actualColor, w: FontWeight.w700)),
        ]),
        if (h['error'] != null) ...[
          const SizedBox(height: 4),
          Text(h['error'].toString().substring(0, h['error'].toString().length.clamp(0, 120)),
              style: YS.label(10, color: YS.inkMid)),
        ],
      ]),
    );
  }

  Widget _infoRow(String k, String v) => Padding(
    padding: const EdgeInsets.only(bottom: 8),
    child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text('$k: ', style: YS.label(12, color: YS.inkMid)),
      Expanded(child: Text(v, style: YS.label(12, w: FontWeight.w600))),
    ]),
  );
}
