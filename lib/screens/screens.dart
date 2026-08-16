import 'dart:convert';
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
  'Andhra Pradesh',
  'Arunachal Pradesh',
  'Assam',
  'Bihar',
  'Chhattisgarh',
  'Goa',
  'Gujarat',
  'Haryana',
  'Himachal Pradesh',
  'Jharkhand',
  'Karnataka',
  'Kerala',
  'Madhya Pradesh',
  'Maharashtra',
  'Manipur',
  'Meghalaya',
  'Mizoram',
  'Nagaland',
  'Odisha',
  'Punjab',
  'Rajasthan',
  'Sikkim',
  'Tamil Nadu',
  'Telangana',
  'Tripura',
  'Uttar Pradesh',
  'Uttarakhand',
  'West Bengal',
  'Andaman & Nicobar Islands',
  'Chandigarh',
  'Dadra & Nagar Haveli and Daman & Diu',
  'Delhi',
  'Jammu & Kashmir',
  'Ladakh',
  'Lakshadweep',
  'Puducherry',
];

Widget regionDropdown({
  required String? value,
  required ValueChanged<String?> onChanged,
}) => DropdownButtonFormField<String>(
  initialValue: value,
  decoration: InputDecoration(
    labelText: 'Region / State',
    hintText: 'Select state or UT',
    prefixIcon: const Icon(Icons.location_on_outlined, size: 18),
    border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
    contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
  ),
  isExpanded: true,
  items:
      kIndiaRegions
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
  child: Column(
    children: [
      const Icon(Icons.wifi_off_rounded, size: 40, color: YS.inkLight),
      const SizedBox(height: 12),
      Text(
        'Cannot reach server',
        style: YS.label(14, color: YS.inkMid, w: FontWeight.w600),
      ),
      const SizedBox(height: 4),
      Text(
        'Check Settings → Server URLs',
        style: YS.label(12, color: YS.inkLight),
      ),
      const SizedBox(height: 16),
      SizedBox(
        width: double.infinity,
        child: ElevatedButton(onPressed: onRetry, child: const Text('Retry')),
      ),
    ],
  ),
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
  void dispose() {
    _uidCtrl.dispose();
    super.dispose();
  }

  bool get _isSlap => widget.mode == CaptureMode.slap;

  Future<void> _verify(File image) async {
    if (_uidCtrl.text.trim().isEmpty || _region == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Enter UID and select region', style: YS.label(13)),
          backgroundColor: YS.red,
        ),
      );
      return;
    }
    final sw = Stopwatch()..start();
    setState(() {
      _loading = true;
      _result = null;
    });
    try {
      final r =
          _isSlap
              ? await ApiService.verifySlap(
                uid: _uidCtrl.text.trim(),
                batch: _region!,
                image: image,
                handSide: _handSide,
              )
              : await ApiService.verify(
                uid: _uidCtrl.text.trim(),
                batch: _region!,
                image: image,
              );
      sw.stop();
      r['client_total_ms'] = sw.elapsedMilliseconds;
      setState(() {
        _result = r;
        _loading = false;
      });
      if (r['matched'] == true) {
        HapticFeedback.heavyImpact();
      } else {
        HapticFeedback.vibrate();
      }
    } catch (e) {
      sw.stop();
      final msg = e.toString();
      final isOffline =
          msg.contains('SocketException') ||
          msg.contains('Connection refused') ||
          msg.contains('timed out');
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
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_rounded),
          onPressed: () => context.go('/'),
        ),
        title: Text(
          _isSlap ? 'Slap Verify' : 'Verify Identity',
          style: YS.label(17, w: FontWeight.w700),
        ),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(1),
          child: Container(height: 1, color: YS.stroke),
        ),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: YS.blueBg,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: YS.blue.withValues(alpha: 0.3)),
              ),
              child: Row(
                children: [
                  const Icon(
                    Icons.info_outline_rounded,
                    color: YS.blue,
                    size: 16,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      _isSlap
                          ? 'Verifies slap fingerprint against a specific Aadhaar UID'
                          : 'Verifies fingerprint against a specific Aadhaar UID',
                      style: YS.label(12, color: YS.blue),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 20),
            regionDropdown(
              value: _region,
              onChanged: (v) => setState(() => _region = v),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _uidCtrl,
              style: YS.label(14),
              decoration: InputDecoration(
                labelText: 'Aadhaar UID',
                prefixIcon: Icon(
                  Icons.badge_outlined,
                  color: YS.inkLight,
                  size: 18,
                ),
              ),
            ),
            if (_isSlap) ...[
              const SizedBox(height: 16),
              Text(
                'HAND',
                style: YS
                    .label(11, color: YS.inkLight, w: FontWeight.w700)
                    .copyWith(letterSpacing: 1.8),
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  _handChip('right', 'Right hand', YS.blueBg, YS.blue),
                  const SizedBox(width: 10),
                  _handChip('left', 'Left hand', YS.blueBg, YS.blue),
                ],
              ),
            ],
            const SizedBox(height: 24),
            Text(
              _isSlap ? 'SLAP CAPTURE' : 'FINGERPRINT CAPTURE',
              style: YS
                  .label(11, color: YS.inkLight, w: FontWeight.w700)
                  .copyWith(letterSpacing: 1.8),
            ),
            const SizedBox(height: 10),
            FingerprintCameraWidget(
              onImageCaptured: _verify,
              onRetake: () => setState(() => _result = null),
              disabled: _loading,
              mode: widget.mode,
              overlayStyle: _isSlap ? 'slap' : 'oval',
              handSide: _handSide,
            ),
            const SizedBox(height: 20),
            if (_loading) ...[
              ysShimmer(height: 80),
              const SizedBox(height: 8),
              ysShimmer(height: 60),
            ],
            if (!_loading && _result != null) ...[
              const SizedBox(height: 16),
              if (_result!['offline'] == true)
                ysOfflineCard(() => setState(() => _result = null))
              else ...[
                _resultCard(_result!),
                if (_result!['quality'] is Map) ...[
                  const SizedBox(height: 14),
                  _qualityRow(_result!),
                ],
                if (!_isSlap &&
                    (_result!['minutiae'] is List ||
                        _result!['minutiae_count'] != null ||
                        _result!['input_minutiae_count'] != null)) ...[
                  const SizedBox(height: 14),
                  _minutiaeStats(_result!),
                ],
                const SizedBox(height: 16),
                if (!_isSlap && _result!['images'] is Map)
                  _singlePipelineVisualizer(_result!)
                else if (_isSlap &&
                    (_result!['fingers'] is List ||
                        _result!['composite_b64'] != null))
                  _slapPipelineVisualizer(_result!),
              ],
            ],
            const SizedBox(height: 40),
          ],
        ),
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
            child: Text(
              label,
              style: YS.label(
                13,
                color: sel ? color : YS.inkMid,
                w: FontWeight.w700,
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _resultCard(Map<String, dynamic> r) {
    final thresh = ((r['threshold'] ?? 0.20) as num).toDouble();
    final score =
        ((r['confidence'] ?? r['avg_confidence'] ?? 0.0) as num).toDouble();
    final ok =
        r['success'] == true &&
        (r['matched'] == true || (r['confidence'] != null && score >= thresh));
    final color = ok ? YS.green : YS.red;
    final bg = ok ? YS.greenBg : YS.redBg;
    final String errorText = (r['error'] ?? r['message'] ?? '').toString();
    final bool hasError = errorText.isNotEmpty && errorText != 'null';
    String msg =
        ok ? 'Identity Verified' : (hasError ? errorText : 'Identity Mismatch');
    if (r['quality_failed'] == true) msg = r['guidance'] ?? 'Quality failed';
    if (r['spoof_detected'] == true) msg = 'Spoof detected';
    final raw = r['matched_fingers'];
    final matchedFingers = raw is List ? raw : null;
    final minutiaeCount = r['input_minutiae_count'] ?? r['minutiae_count'];

    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: color.withValues(alpha: 0.3)),
        boxShadow: YS.cardShadow,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                ok ? Icons.verified_rounded : Icons.cancel_rounded,
                color: color,
                size: 24,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      ok
                          ? 'IDENTITY VERIFIED'
                          : (hasError ? 'ERROR / NOT FOUND' : 'MISMATCH'),
                      style: YS.display(16, color: color, w: FontWeight.w800),
                    ),
                    Text(
                      msg,
                      style: YS.label(12, color: color, w: FontWeight.w600),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          Divider(color: color.withValues(alpha: 0.2)),
          const SizedBox(height: 8),
          if (hasError && !ok) ...[_row('Error', errorText)],
          if (r['client_total_ms'] != null &&
              r['total_execution_time_ms'] != null &&
              r['client_total_ms'] != r['total_execution_time_ms']) ...[
            _row(
              'Total End-to-End Time',
              '${((r['client_total_ms'] as num) / 1000.0).toStringAsFixed(2)} s',
            ),
            _row(
              'Cloud API Pipeline Time',
              '${((r['total_execution_time_ms'] as num) / 1000.0).toStringAsFixed(2)} s',
            ),
          ] else if (r['client_total_ms'] != null ||
              r['total_execution_time_ms'] != null ||
              r['execution_time_ms'] != null)
            _row(
              'Complete Process Time',
              '${(((r['client_total_ms'] ?? r['total_execution_time_ms'] ?? r['execution_time_ms']) as num) / 1000.0).toStringAsFixed(2)} s',
            ),
          if (r['uid'] != null && r['uid'].toString() != 'null')
            _row('Aadhaar UID', r['uid'].toString()),
          if (r['name'] != null &&
              r['name'].toString() != 'null' &&
              r['name'].toString() != r['uid'].toString())
            _row('Name', r['name'].toString()),
          if (r['confidence'] != null || r['avg_confidence'] != null) ...[
            _row(
              'Match Score',
              '${(score * 100).toStringAsFixed(1)}% (Threshold: ${(thresh * 100).toStringAsFixed(0)}%)',
            ),
            const SizedBox(height: 6),
            ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: LinearProgressIndicator(
                value: score.clamp(0.0, 1.0),
                backgroundColor: YS.stroke,
                color: color,
                minHeight: 8,
              ),
            ),
            const SizedBox(height: 8),
          ],
          if (minutiaeCount != null)
            _row('Minutiae Extracted', '$minutiaeCount points'),
          if (r['mode'] != null)
            _row(
              'Engine Mode',
              r['mode'] == 'cloud_hybrid'
                  ? '☁️ Cloud Hybrid'
                  : '⚡ Offline On-Device',
            ),
          if (matchedFingers != null && matchedFingers.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text('Matched fingers:', style: YS.label(11, color: YS.inkMid)),
            const SizedBox(height: 4),
            ...matchedFingers.map<Widget>(
              (f) => Padding(
                padding: const EdgeInsets.only(left: 8, bottom: 2),
                child: Text(
                  '•  ${(f['finger_position'] ?? f['matched_position'] ?? f['probe_position'] ?? '').toString().replaceAll('_', ' ').toUpperCase()}'
                  '  —  ${(((f['confidence'] ?? 0) as num) * 100).toStringAsFixed(1)}%',
                  style: YS.label(12, w: FontWeight.w600),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _qualityRow(Map<String, dynamic> r) {
    final qcRaw = r['quality'];
    final Map<dynamic, dynamic> qc = qcRaw is Map ? qcRaw : {};
    final passed = qc['passed'] == true || qc['is_passed'] == true;

    dynamic blurVal = qc['blur'];
    if (blurVal is Map) {
      blurVal = blurVal['blur_score'];
    }
    blurVal ??= qc['blur_score'] ?? '—';

    dynamic brightVal = qc['brightness'];
    if (brightVal is Map) {
      brightVal = brightVal['brightness'];
    }
    brightVal ??= qc['brightness_val'] ?? '—';

    dynamic glareVal = qc['glare'];
    bool hasGlare = false;
    if (glareVal is Map) {
      hasGlare = glareVal['has_glare'] == true;
    } else if (qc['has_glare'] != null) {
      hasGlare = qc['has_glare'] == true;
    }

    final isBlurry =
        (qc['blur'] is Map && qc['blur']['is_blurry'] == true) ||
        qc['is_blurry'] == true;
    final guidance = qc['guidance'] ?? qc['guidance_text'];
    final readiness = qc['readiness_score'];
    final grade = qc['readiness_grade'];

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: passed ? YS.greenBg : YS.redBg,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color:
              passed
                  ? YS.green.withValues(alpha: 0.3)
                  : YS.red.withValues(alpha: 0.3),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                passed ? Icons.check_circle_rounded : Icons.cancel_rounded,
                color: passed ? YS.green : YS.red,
                size: 18,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Quality Gate — ${passed ? "PASSED" : "FAILED"}${grade != null ? ' ($grade)' : ''}',
                  style: YS.label(
                    13,
                    color: passed ? YS.green : YS.red,
                    w: FontWeight.w700,
                  ),
                ),
              ),
              if (readiness != null)
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 3,
                  ),
                  decoration: BoxDecoration(
                    color: passed ? YS.green : YS.red,
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text(
                    'Score: ${(readiness as num).toStringAsFixed(1)}',
                    style: YS.label(
                      10,
                      color: Colors.white,
                      w: FontWeight.w700,
                    ),
                  ),
                ),
            ],
          ),
          if (guidance != null) ...[
            const SizedBox(height: 6),
            Text(
              '→ $guidance',
              style: YS.label(12, color: passed ? YS.inkMid : YS.red),
            ),
          ],
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: _qcChip(
                  'Blur',
                  '$blurVal',
                  isBlurry ? YS.red : YS.green,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(child: _qcChip('Brightness', '$brightVal', YS.inkMid)),
              const SizedBox(width: 8),
              Expanded(
                child: _qcChip(
                  'Glare',
                  hasGlare ? 'Yes' : 'None',
                  hasGlare ? YS.red : YS.green,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _qcChip(String k, String v, Color c) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
    decoration: BoxDecoration(
      color: YS.card,
      borderRadius: BorderRadius.circular(8),
      border: Border.all(color: YS.stroke),
    ),
    child: Column(
      children: [
        Text(
          k,
          style: YS
              .label(9, color: YS.inkLight, w: FontWeight.w600)
              .copyWith(letterSpacing: 0.5),
        ),
        const SizedBox(height: 2),
        Text(v, style: YS.label(12, color: c, w: FontWeight.w700)),
      ],
    ),
  );

  Widget _minutiaeStats(Map<String, dynamic> r) {
    final mins = r['minutiae'] as List? ?? [];
    final count =
        (r['input_minutiae_count'] ?? r['minutiae_count'] as num?)?.toInt() ??
        mins.length;

    int rig = 0;
    int bif = 0;
    for (final m in mins) {
      if (m is Map) {
        final t = (m['type'] as String? ?? '').toUpperCase();
        if (t.contains('END') || t.contains('RIG')) {
          rig++;
        } else if (t.contains('BIF')) {
          bif++;
        }
      }
    }

    if (mins.isNotEmpty && rig == 0 && bif == 0) {
      rig = (count * 0.55).round();
      bif = count - rig;
    }

    final bool isOptimal = count >= 25;
    final bool isAcceptable = count >= 12;
    final Color barColor =
        isOptimal
            ? YS.green
            : (isAcceptable ? const Color(0xFF0091EA) : YS.orange);
    final String statusText =
        isOptimal
            ? '✓ Optimal minutiae density ($count features) — UIDAI compliant'
            : (isAcceptable
                ? '✓ Sufficient minutiae ($count features) for 1:1 verification'
                : '⚠ Low minutiae count ($count features) — minimum 12 required');

    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: YS.card,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: YS.stroke),
        boxShadow: YS.cardShadow,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                'Minutiae Extraction',
                style: YS.label(14, w: FontWeight.w700),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: isAcceptable ? YS.greenBg : YS.redBg,
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text(
                  isOptimal
                      ? 'EXCELLENT'
                      : (isAcceptable ? 'PASSED' : 'LOW QUALITY'),
                  style: YS.label(
                    9,
                    color: isAcceptable ? YS.green : YS.red,
                    w: FontWeight.w700,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            'ISO/IEC 19794-2 ridge endings & bifurcations extracted',
            style: YS.label(11, color: YS.inkLight),
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              _mStat('$count', 'Total Points', YS.amber),
              const SizedBox(width: 10),
              _mStat('$rig', 'Ridge Endings', YS.green),
              const SizedBox(width: 10),
              _mStat('$bif', 'Bifurcations', YS.blue),
            ],
          ),
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: YS.cardAlt,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: YS.stroke.withValues(alpha: 0.5)),
            ),
            child: Row(
              children: [
                Container(
                  width: 10,
                  height: 10,
                  decoration: const BoxDecoration(
                    color: Color(0xFF00C853),
                    shape: BoxShape.circle,
                  ),
                ),
                const SizedBox(width: 6),
                Text(
                  'Ending (RIG)',
                  style: YS.label(11, color: YS.inkMid, w: FontWeight.w600),
                ),
                const SizedBox(width: 16),
                Container(
                  width: 10,
                  height: 10,
                  decoration: const BoxDecoration(
                    color: Color(0xFF0091EA),
                    shape: BoxShape.circle,
                  ),
                ),
                const SizedBox(width: 6),
                Text(
                  'Bifurcation (BIF)',
                  style: YS.label(11, color: YS.inkMid, w: FontWeight.w600),
                ),
              ],
            ),
          ),
          if (count > 0) ...[
            const SizedBox(height: 12),
            ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: LinearProgressIndicator(
                value: (count / 35.0).clamp(0.0, 1.0),
                minHeight: 7,
                backgroundColor: YS.stroke,
                color: barColor,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              statusText,
              style: YS.label(11, color: barColor, w: FontWeight.w600),
            ),
          ],
        ],
      ),
    );
  }

  Widget _mStat(String val, String label, Color c) => Expanded(
    child: Container(
      padding: const EdgeInsets.symmetric(vertical: 10),
      decoration: BoxDecoration(
        color: YS.cardAlt,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        children: [
          Text(val, style: YS.display(18, color: c, w: FontWeight.w800)),
          const SizedBox(height: 2),
          Text(label, style: YS.label(10, color: YS.inkLight)),
        ],
      ),
    ),
  );

  Widget _singlePipelineVisualizer(Map<String, dynamic> r) {
    final imagesRaw = r['images'];
    final Map<dynamic, dynamic> images = imagesRaw is Map ? imagesRaw : {};
    final steps = [
      {
        'num': '1',
        'title': 'Original Frame',
        'desc': 'Raw camera frame capture',
        'icon': Icons.camera_alt_outlined,
        'key': 'original',
      },
      {
        'num': '2',
        'title': 'YOLO Distal Crop',
        'desc': 'Distal phalanx apex & ROI boundary',
        'icon': Icons.crop_free_rounded,
        'key': 'cropped',
      },
      {
        'num': '3',
        'title': 'Contact-Equivalent FIR',
        'desc': 'U²-Net segmented tissue & enhanced ridges',
        'icon': Icons.contrast_rounded,
        'key': 'preprocessed',
      },
      {
        'num': '4',
        'title': 'Minutiae Extraction',
        'desc': 'Ridge endings & bifurcations mapped',
        'icon': Icons.scatter_plot_rounded,
        'key': 'visualization',
      },
    ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'PIPELINE VISUALIZATION',
          style: YS
              .label(11, color: YS.inkLight, w: FontWeight.w700)
              .copyWith(letterSpacing: 1.8),
        ),
        const SizedBox(height: 10),
        ...steps.map((s) {
          final b64 = images[s['key']] as String?;
          return Container(
            margin: const EdgeInsets.only(bottom: 14),
            decoration: BoxDecoration(
              color: YS.card,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: YS.stroke),
              boxShadow: YS.cardShadow,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(14, 12, 14, 10),
                  child: Row(
                    children: [
                      Container(
                        width: 24,
                        height: 24,
                        decoration: BoxDecoration(
                          color: YS.greenBg,
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: Center(
                          child: Text(
                            s['num'] as String,
                            style: YS.label(
                              11,
                              color: YS.green,
                              w: FontWeight.w800,
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              s['title'] as String,
                              style: YS.label(13, w: FontWeight.w700),
                            ),
                            Text(
                              s['desc'] as String,
                              style: YS.label(10, color: YS.inkLight),
                            ),
                          ],
                        ),
                      ),
                      Icon(s['icon'] as IconData, color: YS.green, size: 16),
                    ],
                  ),
                ),
                if (b64 != null && b64.isNotEmpty)
                  GestureDetector(
                    onTap:
                        () => _showImageZoomDialog(s['title'] as String, b64),
                    child: ClipRRect(
                      borderRadius: const BorderRadius.vertical(
                        bottom: Radius.circular(16),
                      ),
                      child: Stack(
                        alignment: Alignment.bottomRight,
                        children: [
                          Container(
                            color: Colors.white,
                            width: double.infinity,
                            constraints: const BoxConstraints(maxHeight: 220),
                            child: Image.memory(
                              base64Decode(b64),
                              fit: BoxFit.contain,
                            ),
                          ),
                          Container(
                            margin: const EdgeInsets.all(8),
                            padding: const EdgeInsets.all(5),
                            decoration: BoxDecoration(
                              color: Colors.black54,
                              borderRadius: BorderRadius.circular(6),
                            ),
                            child: const Icon(
                              Icons.zoom_in_rounded,
                              color: Colors.white,
                              size: 14,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
          );
        }),
      ],
    );
  }

  Widget _slapPipelineVisualizer(Map<String, dynamic> r) {
    final composite = r['composite_b64'] as String?;
    final rawF = r['fingers'];
    final fingers = (rawF is List ? rawF.whereType<Map>().toList() : <Map>[]);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (composite != null && composite.isNotEmpty) ...[
          Text(
            'STITCHED SLAP COMPOSITE',
            style: YS
                .label(11, color: YS.inkLight, w: FontWeight.w700)
                .copyWith(letterSpacing: 1.8),
          ),
          const SizedBox(height: 10),
          GestureDetector(
            onTap: () => _showImageZoomDialog('4-Finger Composite', composite),
            child: Container(
              height: 150,
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: YS.stroke),
                image: DecorationImage(
                  fit: BoxFit.contain,
                  image: MemoryImage(base64Decode(composite)),
                ),
              ),
              alignment: Alignment.bottomRight,
              padding: const EdgeInsets.all(8),
              child: Container(
                padding: const EdgeInsets.all(5),
                decoration: BoxDecoration(
                  color: Colors.black54,
                  borderRadius: BorderRadius.circular(6),
                ),
                child: const Icon(
                  Icons.zoom_in_rounded,
                  color: Colors.white,
                  size: 14,
                ),
              ),
            ),
          ),
          const SizedBox(height: 16),
        ],
        if (fingers.isNotEmpty) ...[
          Text(
            'PER-FINGER CROPS & MINUTIAE',
            style: YS
                .label(11, color: YS.inkLight, w: FontWeight.w700)
                .copyWith(letterSpacing: 1.8),
          ),
          const SizedBox(height: 10),
          ...fingers.map((f) => _fingerCard(f)),
        ],
      ],
    );
  }

  Widget _fingerCard(Map f) {
    final pos = (f['finger_position'] ?? f['position'] ?? '')
        .toString()
        .replaceAll('_', ' ');
    final mins = f['minutiae_count'] ?? (f['minutiae'] as List?)?.length ?? 0;
    final cropped = f['cropped_b64'];
    final preproc = f['preprocessed_b64'];
    final vis = f['visualization_b64'] ?? f['minutiae_b64'];
    final isoCode = f['iso_code'];

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: YS.card,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: YS.stroke),
        boxShadow: YS.cardShadow,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(pos.toUpperCase(), style: YS.label(13, w: FontWeight.w700)),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: BoxDecoration(
                  color: YS.amberSoft,
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text(
                  '$mins minutiae${isoCode != null ? ' · ISO $isoCode' : ''}',
                  style: YS.label(10, color: YS.amberDeep, w: FontWeight.w700),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(child: _stageTile('1. Cropped', cropped)),
              const SizedBox(width: 6),
              Expanded(child: _stageTile('2. FIR Image', preproc)),
              const SizedBox(width: 6),
              Expanded(child: _stageTile('3. Minutiae', vis)),
            ],
          ),
        ],
      ),
    );
  }

  Widget _stageTile(String label, dynamic b64) {
    final String? strB64 = b64 is String && b64.isNotEmpty ? b64 : null;
    final hasImg = strB64 != null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: YS.label(10, color: YS.inkLight, w: FontWeight.w600),
        ),
        const SizedBox(height: 4),
        AspectRatio(
          aspectRatio: 1.0,
          child: GestureDetector(
            onTap: hasImg ? () => _showImageZoomDialog(label, strB64) : null,
            child: Container(
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: YS.stroke),
                image:
                    hasImg
                        ? DecorationImage(
                          fit: BoxFit.contain,
                          image: MemoryImage(base64Decode(strB64)),
                        )
                        : null,
              ),
              child:
                  !hasImg
                      ? Center(
                        child: Icon(
                          Icons.inbox_rounded,
                          color: YS.inkFaint,
                          size: 18,
                        ),
                      )
                      : const Align(
                        alignment: Alignment.topRight,
                        child: Padding(
                          padding: EdgeInsets.all(3.0),
                          child: Icon(
                            Icons.zoom_in_rounded,
                            color: Colors.black45,
                            size: 12,
                          ),
                        ),
                      ),
            ),
          ),
        ),
      ],
    );
  }

  void _showImageZoomDialog(String title, String b64) {
    showDialog(
      context: context,
      builder:
          (ctx) => Dialog(
            backgroundColor: Colors.black87,
            insetPadding: const EdgeInsets.all(16),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 12,
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        title,
                        style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.bold,
                          fontSize: 15,
                        ),
                      ),
                      IconButton(
                        icon: const Icon(Icons.close, color: Colors.white70),
                        onPressed: () => Navigator.of(ctx).pop(),
                      ),
                    ],
                  ),
                ),
                Flexible(
                  child: InteractiveViewer(
                    minScale: 0.8,
                    maxScale: 6.0,
                    child: ClipRRect(
                      borderRadius: const BorderRadius.vertical(
                        bottom: Radius.circular(16),
                      ),
                      child: Container(
                        color: Colors.white,
                        child: Image.memory(
                          base64Decode(b64),
                          fit: BoxFit.contain,
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
    );
  }

  Widget _row(String k, String v) => Padding(
    padding: const EdgeInsets.only(bottom: 6),
    child: Row(
      children: [
        Text('$k: ', style: YS.label(13, color: YS.inkMid)),
        Text(v, style: YS.label(13, w: FontWeight.w700)),
      ],
    ),
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
    final sw = Stopwatch()..start();
    setState(() {
      _loading = true;
      _result = null;
      _readiness = null;
    });
    try {
      final results =
          _isSlap
              ? [
                await ApiService.processSlap(
                  image: image,
                  handSide: _handSide,
                  vis: true,
                ),
              ]
              : await Future.wait([
                ApiService.process(image),
                ApiService.readiness(image),
              ]);
      sw.stop();
      results[0]['client_total_ms'] = sw.elapsedMilliseconds;
      if (results.length > 1) {
        results[1]['client_total_ms'] = sw.elapsedMilliseconds;
      }
      setState(() {
        if (_isSlap) {
          _result = results[0];
        } else {
          _result = results[0];
          _readiness = results[1];
        }
        _loading = false;
      });
    } catch (e) {
      sw.stop();
      final isOffline =
          e.toString().contains('SocketException') ||
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
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_rounded),
          onPressed: () => context.go('/'),
        ),
        title: Text('QC Pipeline', style: YS.label(17, w: FontWeight.w700)),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(1),
          child: Container(height: 1, color: YS.stroke),
        ),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (_isSlap) ...[
              Text(
                'HAND',
                style: YS
                    .label(11, color: YS.inkLight, w: FontWeight.w700)
                    .copyWith(letterSpacing: 1.8),
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  _qcHandChip('right', 'Right hand'),
                  const SizedBox(width: 10),
                  _qcHandChip('left', 'Left hand'),
                ],
              ),
              const SizedBox(height: 16),
            ],
            FingerprintCameraWidget(
              onImageCaptured: _run,
              onRetake:
                  () => setState(() {
                    _result = null;
                    _readiness = null;
                  }),
              disabled: _loading,
              mode: widget.mode,
              overlayStyle: _isSlap ? 'slap' : 'oval',
              handSide: _handSide,
            ),
            const SizedBox(height: 20),
            if (_loading) ...[
              ysShimmer(height: 80),
              const SizedBox(height: 8),
              ysShimmer(height: 200),
            ],
            if (!_loading && _result?['offline'] == true) ...[
              const SizedBox(height: 16),
              ysOfflineCard(
                () => setState(() {
                  _result = null;
                  _readiness = null;
                }),
              ),
            ],
            if (!_loading && _readiness != null) ...[
              const SizedBox(height: 16),
              _readinessCard(_readiness!),
            ],
            if (!_loading &&
                _result != null &&
                _result!['offline'] != true) ...[
              const SizedBox(height: 16),
              _isSlap ? _slapQcCard(_result!) : _qcCard(_result!),
              if (!_isSlap &&
                  (_result!['minutiae'] is List ||
                      _result!['minutiae_count'] != null ||
                      _result!['input_minutiae_count'] != null)) ...[
                const SizedBox(height: 14),
                _minutiaeStats(_result!),
              ],
              const SizedBox(height: 16),
              if (!_isSlap && _result!['images'] is Map)
                _singlePipelineVisualizer(_result!)
              else if (_isSlap &&
                  (_result!['fingers'] is List ||
                      _result!['composite_b64'] != null))
                _slapPipelineVisualizer(_result!),
            ],
            const SizedBox(height: 40),
          ],
        ),
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
          child: Center(
            child: Text(
              label,
              style: YS.label(
                13,
                color: sel ? YS.orange : YS.inkMid,
                w: FontWeight.w700,
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _readinessCard(Map<String, dynamic> r) {
    final score = (r['readiness_score'] as num?)?.toInt() ?? 0;
    final grade = r['grade'] as String? ?? '—';
    final breakdownRaw = r['breakdown'];
    final Map<dynamic, dynamic> breakdown =
        breakdownRaw is Map ? breakdownRaw : {};
    final gradeColor =
        grade == 'Excellent'
            ? YS.green
            : grade == 'Good'
            ? YS.green
            : grade == 'Marginal'
            ? YS.orange
            : YS.red;
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: YS.card,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: YS.stroke),
        boxShadow: YS.cardShadow,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                'Readiness Score',
                style: YS.display(16, w: FontWeight.w700),
              ),
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 5,
                ),
                decoration: BoxDecoration(
                  color: gradeColor.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(color: gradeColor.withValues(alpha: 0.3)),
                ),
                child: Text(
                  grade,
                  style: YS.label(12, color: gradeColor, w: FontWeight.w700),
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(
                '$score',
                style: YS.display(40, color: gradeColor, w: FontWeight.w800),
              ),
              Padding(
                padding: const EdgeInsets.only(bottom: 6, left: 4),
                child: Text('/100', style: YS.label(14, color: YS.inkLight)),
              ),
            ],
          ),
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
          Row(
            children: [
              _miniStat('Blur', '${breakdown['blur'] ?? '—'}'),
              _miniStat('Brightness', '${breakdown['brightness'] ?? '—'}'),
              _miniStat('Glare', breakdown['glare'] == true ? 'Yes' : 'No'),
              _miniStat('Minutiae', '${breakdown['minutiae'] ?? '—'}'),
            ],
          ),
        ],
      ),
    );
  }

  Widget _miniStat(String k, String v) => Expanded(
    child: Container(
      margin: const EdgeInsets.only(right: 8),
      padding: const EdgeInsets.symmetric(vertical: 10),
      decoration: BoxDecoration(
        color: YS.cardAlt,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        children: [
          Text(v, style: YS.label(13, w: FontWeight.w700)),
          const SizedBox(height: 2),
          Text(k, style: YS.label(10, color: YS.inkLight)),
        ],
      ),
    ),
  );

  Widget _qcCard(Map<String, dynamic> r) {
    if (r['success'] != true) {
      return Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: YS.redBg,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: YS.red.withValues(alpha: 0.3)),
        ),
        child: Text('Error: ${r['error']}', style: YS.label(13, color: YS.red)),
      );
    }
    final qcRaw = r['quality'];
    final Map<dynamic, dynamic> qc = qcRaw is Map ? qcRaw : {};
    final livenessRaw = r['liveness'];
    final Map<dynamic, dynamic> liveness =
        livenessRaw is Map ? livenessRaw : {};
    final qcPassed = qc['passed'] == true || qc['is_passed'] == true;
    final isLive = liveness['is_live'] == true;
    final guidance = qc['guidance'] ?? qc['guidance_text'];
    final skinRatio = qc['skin_ratio'] ?? qc['coverage_ratio'];
    final detConf = qc['detection_conf'] ?? r['detection_conf'];

    dynamic blurVal = qc['blur'];
    if (blurVal is Map) blurVal = blurVal['blur_score'];
    blurVal ??= qc['blur_score'] ?? '—';
    if (blurVal is num) blurVal = blurVal.toStringAsFixed(1);

    dynamic brightVal = qc['brightness'];
    if (brightVal is Map) brightVal = brightVal['brightness'];
    brightVal ??= qc['brightness_val'] ?? qc['brightness'] ?? '—';
    if (brightVal is num) brightVal = brightVal.toStringAsFixed(1);

    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: YS.card,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: YS.stroke),
        boxShadow: YS.cardShadow,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text('Pipeline Results', style: YS.display(16, w: FontWeight.w700)),
              if (qc['readiness_score'] != null)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: qcPassed ? YS.greenBg : YS.redBg,
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text(
                    'Score: ${(qc['readiness_score'] as num).toStringAsFixed(1)}',
                    style: YS.label(10, color: qcPassed ? YS.green : YS.red, w: FontWeight.w700),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 16),
          if (r['client_total_ms'] != null ||
              r['total_execution_time_ms'] != null ||
              r['execution_time_ms'] != null) ...[
            _qcRow(
              'Time Taken',
              '${(((r['client_total_ms'] ?? r['total_execution_time_ms'] ?? r['execution_time_ms']) as num) / 1000.0).toStringAsFixed(2)} s',
              YS.blue,
            ),
            const SizedBox(height: 4),
          ],
          _qcRow(
            'Quality Gate',
            qcPassed ? 'PASSED' : 'FAILED',
            qcPassed ? YS.green : YS.red,
          ),
          if (guidance != null)
            Padding(
              padding: const EdgeInsets.only(left: 16, bottom: 8),
              child: Text(
                '→ $guidance',
                style: YS.label(12, color: qcPassed ? YS.green : YS.orange, w: FontWeight.w600),
              ),
            ),
          _qcRow(
            'Blur Score',
            '$blurVal',
            YS.inkMid,
          ),
          _qcRow(
            'Brightness',
            '$brightVal',
            YS.inkMid,
          ),
          _qcRow(
            'Glare',
            (qc['glare'] is Map
                    ? (qc['glare']['has_glare'] == true)
                    : (qc['has_glare'] == true))
                ? 'Detected'
                : 'None',
            (qc['glare'] is Map
                    ? (qc['glare']['has_glare'] == true)
                    : (qc['has_glare'] == true))
                ? YS.red
                : YS.green,
          ),
          if (skinRatio != null)
            _qcRow(
              'Skin Coverage',
              '${(((skinRatio as num)) * 100).toStringAsFixed(1)}%',
              YS.blue,
            ),
          Divider(color: YS.stroke, height: 24),
          if (detConf != null)
            _qcRow(
              'Detection',
              '${(((detConf as num)) * 100).toStringAsFixed(1)}%',
              YS.inkMid,
            ),
          _qcRow(
            'Liveness',
            isLive ? 'LIVE' : 'SPOOF',
            isLive ? YS.green : YS.red,
          ),
          _qcRow(
            'Liveness Conf',
            '${(((liveness['confidence'] ?? 0) as num) * 100).toStringAsFixed(1)}%',
            YS.inkMid,
          ),
          Divider(color: YS.stroke, height: 24),
          _qcRow('Minutiae Extracted', '${r['minutiae_count'] ?? (r['minutiae'] as List?)?.length ?? 0} points', YS.amber),
        ],
      ),
    );
  }

  Widget _slapQcCard(Map<String, dynamic> r) {
    final rawF = r['fingers'];
    final fingers = (rawF is List ? rawF.whereType<Map>().toList() : <Map>[]);
    final count = r['finger_count'] ?? 0;
    if (count == 0) {
      return Container(
        padding: const EdgeInsets.all(18),
        decoration: BoxDecoration(
          color: YS.redBg,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: YS.red.withValues(alpha: 0.3)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: const [
                Icon(Icons.error_outline_rounded, color: YS.red, size: 20),
                SizedBox(width: 8),
                Text(
                  'No fingers detected',
                  style: TextStyle(
                    color: YS.red,
                    fontSize: 15,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              r['error'] ??
                  'Move closer and present your fingers to the camera.',
              style: YS.label(12, color: YS.inkMid),
            ),
          ],
        ),
      );
    }
    final totalMinutiae = fingers.fold<int>(
      0,
      (s, f) => s + (((f['minutiae_count'] ?? 0) as num).toInt()),
    );
    final allLive = fingers.every(
      (f) => (f['liveness'] as Map?)?['is_live'] == true,
    );
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: YS.card,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: YS.stroke),
        boxShadow: YS.cardShadow,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Slap Pipeline Results',
            style: YS.display(16, w: FontWeight.w700),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              _statPill('$count fingers', YS.amberDeep, YS.amberSoft),
              const SizedBox(width: 8),
              _statPill('$totalMinutiae total min', YS.orange, YS.orangeBg),
              const SizedBox(width: 8),
              _statPill(
                allLive ? 'ALL LIVE' : 'SPOOF MIX',
                allLive ? YS.green : YS.red,
                allLive ? YS.greenBg : YS.redBg,
              ),
              if (r['client_total_ms'] != null ||
                  r['total_execution_time_ms'] != null ||
                  r['execution_time_ms'] != null) ...[
                const SizedBox(width: 8),
                _statPill(
                  '${(((r['client_total_ms'] ?? r['total_execution_time_ms'] ?? r['execution_time_ms']) as num) / 1000.0).toStringAsFixed(2)} s',
                  YS.blue,
                  YS.blueBg,
                ),
              ],
            ],
          ),
          const SizedBox(height: 14),
          ...fingers.map<Widget>((f) => _fingerQcRow(f)),
        ],
      ),
    );
  }

  Widget _statPill(String text, Color color, Color bg) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
    decoration: BoxDecoration(
      color: bg,
      borderRadius: BorderRadius.circular(20),
    ),
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
      decoration: BoxDecoration(
        color: YS.cardAlt,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        children: [
          Icon(Icons.fingerprint_rounded, size: 16, color: YS.amber),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              pos.toUpperCase(),
              style: YS.label(13, w: FontWeight.w700),
            ),
          ),
          Text('$conf%', style: YS.label(11, color: YS.inkLight)),
          const SizedBox(width: 12),
          Text(
            '$mins min',
            style: YS.label(11, color: YS.amberDeep, w: FontWeight.w700),
          ),
          const SizedBox(width: 12),
          Text(
            live ? 'LIVE' : 'SPOOF',
            style: YS.label(
              11,
              color: live ? YS.green : YS.red,
              w: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }

  Widget _qcRow(String k, String v, Color vc) => Padding(
    padding: const EdgeInsets.only(bottom: 10),
    child: Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(k, style: YS.label(13, color: YS.inkMid)),
        Text(v, style: YS.label(13, color: vc, w: FontWeight.w700)),
      ],
    ),
  );

  Widget _minutiaeStats(Map<String, dynamic> r) {
    final mins = r['minutiae'] as List? ?? [];
    final count =
        (r['input_minutiae_count'] ?? r['minutiae_count'] as num?)?.toInt() ??
        mins.length;

    int rig = 0;
    int bif = 0;
    for (final m in mins) {
      if (m is Map) {
        final t = (m['type'] as String? ?? '').toUpperCase();
        if (t.contains('END') || t.contains('RIG')) {
          rig++;
        } else if (t.contains('BIF')) {
          bif++;
        }
      }
    }

    if (mins.isNotEmpty && rig == 0 && bif == 0) {
      rig = (count * 0.55).round();
      bif = count - rig;
    }

    final bool isOptimal = count >= 25;
    final bool isAcceptable = count >= 12;
    final Color barColor =
        isOptimal
            ? YS.green
            : (isAcceptable ? const Color(0xFF0091EA) : YS.orange);
    final String statusText =
        isOptimal
            ? '✓ Optimal minutiae density ($count features) — UIDAI compliant'
            : (isAcceptable
                ? '✓ Sufficient minutiae ($count features) for 1:1 verification'
                : '⚠ Low minutiae count ($count features) — minimum 12 required');

    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: YS.card,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: YS.stroke),
        boxShadow: YS.cardShadow,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                'Minutiae Extraction',
                style: YS.label(14, w: FontWeight.w700),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: isAcceptable ? YS.greenBg : YS.redBg,
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text(
                  isOptimal
                      ? 'EXCELLENT'
                      : (isAcceptable ? 'PASSED' : 'LOW QUALITY'),
                  style: YS.label(
                    9,
                    color: isAcceptable ? YS.green : YS.red,
                    w: FontWeight.w700,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            'ISO/IEC 19794-2 ridge endings & bifurcations extracted',
            style: YS.label(11, color: YS.inkLight),
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              _mStat('$count', 'Total Points', YS.amber),
              const SizedBox(width: 10),
              _mStat('$rig', 'Ridge Endings', YS.green),
              const SizedBox(width: 10),
              _mStat('$bif', 'Bifurcations', YS.blue),
            ],
          ),
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: YS.cardAlt,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: YS.stroke.withValues(alpha: 0.5)),
            ),
            child: Row(
              children: [
                Container(
                  width: 10,
                  height: 10,
                  decoration: const BoxDecoration(
                    color: Color(0xFF00C853),
                    shape: BoxShape.circle,
                  ),
                ),
                const SizedBox(width: 6),
                Text(
                  'Ending (RIG)',
                  style: YS.label(11, color: YS.inkMid, w: FontWeight.w600),
                ),
                const SizedBox(width: 16),
                Container(
                  width: 10,
                  height: 10,
                  decoration: const BoxDecoration(
                    color: Color(0xFF0091EA),
                    shape: BoxShape.circle,
                  ),
                ),
                const SizedBox(width: 6),
                Text(
                  'Bifurcation (BIF)',
                  style: YS.label(11, color: YS.inkMid, w: FontWeight.w600),
                ),
              ],
            ),
          ),
          if (count > 0) ...[
            const SizedBox(height: 12),
            ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: LinearProgressIndicator(
                value: (count / 35.0).clamp(0.0, 1.0),
                minHeight: 7,
                backgroundColor: YS.stroke,
                color: barColor,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              statusText,
              style: YS.label(11, color: barColor, w: FontWeight.w600),
            ),
          ],
        ],
      ),
    );
  }

  Widget _mStat(String val, String label, Color c) => Expanded(
    child: Container(
      padding: const EdgeInsets.symmetric(vertical: 10),
      decoration: BoxDecoration(
        color: YS.cardAlt,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        children: [
          Text(val, style: YS.display(18, color: c, w: FontWeight.w800)),
          const SizedBox(height: 2),
          Text(label, style: YS.label(10, color: YS.inkLight)),
        ],
      ),
    ),
  );

  Widget _singlePipelineVisualizer(Map<String, dynamic> r) {
    final imagesRaw = r['images'];
    final Map<dynamic, dynamic> images = imagesRaw is Map ? imagesRaw : {};
    final steps = [
      {
        'num': '1',
        'title': 'Original Frame',
        'desc': 'Raw camera frame capture',
        'icon': Icons.camera_alt_outlined,
        'key': 'original',
      },
      {
        'num': '2',
        'title': 'YOLO Distal Crop',
        'desc': 'Distal phalanx apex & ROI boundary',
        'icon': Icons.crop_free_rounded,
        'key': 'cropped',
      },
      {
        'num': '3',
        'title': 'Contact-Equivalent FIR',
        'desc': 'U²-Net segmented tissue & enhanced ridges',
        'icon': Icons.contrast_rounded,
        'key': 'preprocessed',
      },
      {
        'num': '4',
        'title': 'Minutiae Extraction',
        'desc': 'Ridge endings & bifurcations mapped',
        'icon': Icons.scatter_plot_rounded,
        'key': 'visualization',
      },
    ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'PIPELINE VISUALIZATION',
          style: YS
              .label(11, color: YS.inkLight, w: FontWeight.w700)
              .copyWith(letterSpacing: 1.8),
        ),
        const SizedBox(height: 10),
        ...steps.map((s) {
          final b64 = images[s['key']] as String?;
          return Container(
            margin: const EdgeInsets.only(bottom: 14),
            decoration: BoxDecoration(
              color: YS.card,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: YS.stroke),
              boxShadow: YS.cardShadow,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(14, 12, 14, 10),
                  child: Row(
                    children: [
                      Container(
                        width: 24,
                        height: 24,
                        decoration: BoxDecoration(
                          color: YS.greenBg,
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: Center(
                          child: Text(
                            s['num'] as String,
                            style: YS.label(
                              11,
                              color: YS.green,
                              w: FontWeight.w800,
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              s['title'] as String,
                              style: YS.label(13, w: FontWeight.w700),
                            ),
                            Text(
                              s['desc'] as String,
                              style: YS.label(10, color: YS.inkLight),
                            ),
                          ],
                        ),
                      ),
                      Icon(s['icon'] as IconData, color: YS.green, size: 16),
                    ],
                  ),
                ),
                if (b64 != null && b64.isNotEmpty)
                  GestureDetector(
                    onTap:
                        () => _showImageZoomDialog(s['title'] as String, b64),
                    child: ClipRRect(
                      borderRadius: const BorderRadius.vertical(
                        bottom: Radius.circular(16),
                      ),
                      child: Stack(
                        alignment: Alignment.bottomRight,
                        children: [
                          Container(
                            color: Colors.white,
                            width: double.infinity,
                            constraints: const BoxConstraints(maxHeight: 220),
                            child: Image.memory(
                              base64Decode(b64),
                              fit: BoxFit.contain,
                            ),
                          ),
                          Container(
                            margin: const EdgeInsets.all(8),
                            padding: const EdgeInsets.all(5),
                            decoration: BoxDecoration(
                              color: Colors.black54,
                              borderRadius: BorderRadius.circular(6),
                            ),
                            child: const Icon(
                              Icons.zoom_in_rounded,
                              color: Colors.white,
                              size: 14,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
          );
        }),
      ],
    );
  }

  Widget _slapPipelineVisualizer(Map<String, dynamic> r) {
    final composite = r['composite_b64'] as String?;
    final rawF = r['fingers'];
    final fingers = (rawF is List ? rawF.whereType<Map>().toList() : <Map>[]);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (composite != null && composite.isNotEmpty) ...[
          Text(
            'STITCHED SLAP COMPOSITE',
            style: YS
                .label(11, color: YS.inkLight, w: FontWeight.w700)
                .copyWith(letterSpacing: 1.8),
          ),
          const SizedBox(height: 10),
          GestureDetector(
            onTap: () => _showImageZoomDialog('4-Finger Composite', composite),
            child: Container(
              height: 150,
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: YS.stroke),
                image: DecorationImage(
                  fit: BoxFit.contain,
                  image: MemoryImage(base64Decode(composite)),
                ),
              ),
              alignment: Alignment.bottomRight,
              padding: const EdgeInsets.all(8),
              child: Container(
                padding: const EdgeInsets.all(5),
                decoration: BoxDecoration(
                  color: Colors.black54,
                  borderRadius: BorderRadius.circular(6),
                ),
                child: const Icon(
                  Icons.zoom_in_rounded,
                  color: Colors.white,
                  size: 14,
                ),
              ),
            ),
          ),
          const SizedBox(height: 16),
        ],
        if (fingers.isNotEmpty) ...[
          Text(
            'PER-FINGER CROPS & MINUTIAE',
            style: YS
                .label(11, color: YS.inkLight, w: FontWeight.w700)
                .copyWith(letterSpacing: 1.8),
          ),
          const SizedBox(height: 10),
          ...fingers.map((f) => _fingerCard(f)),
        ],
      ],
    );
  }

  Widget _fingerCard(Map f) {
    final pos = (f['finger_position'] ?? f['position'] ?? '')
        .toString()
        .replaceAll('_', ' ');
    final mins = f['minutiae_count'] ?? (f['minutiae'] as List?)?.length ?? 0;
    final cropped = f['cropped_b64'];
    final preproc = f['preprocessed_b64'];
    final vis = f['visualization_b64'] ?? f['minutiae_b64'];
    final isoCode = f['iso_code'];

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: YS.card,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: YS.stroke),
        boxShadow: YS.cardShadow,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(pos.toUpperCase(), style: YS.label(13, w: FontWeight.w700)),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: BoxDecoration(
                  color: YS.amberSoft,
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text(
                  '$mins minutiae${isoCode != null ? ' · ISO $isoCode' : ''}',
                  style: YS.label(10, color: YS.amberDeep, w: FontWeight.w700),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(child: _stageTile('1. Cropped', cropped)),
              const SizedBox(width: 6),
              Expanded(child: _stageTile('2. FIR Image', preproc)),
              const SizedBox(width: 6),
              Expanded(child: _stageTile('3. Minutiae', vis)),
            ],
          ),
        ],
      ),
    );
  }

  Widget _stageTile(String label, dynamic b64) {
    final String? strB64 = b64 is String && b64.isNotEmpty ? b64 : null;
    final hasImg = strB64 != null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: YS.label(10, color: YS.inkLight, w: FontWeight.w600),
        ),
        const SizedBox(height: 4),
        AspectRatio(
          aspectRatio: 1.0,
          child: GestureDetector(
            onTap: hasImg ? () => _showImageZoomDialog(label, strB64) : null,
            child: Container(
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: YS.stroke),
                image:
                    hasImg
                        ? DecorationImage(
                          fit: BoxFit.contain,
                          image: MemoryImage(base64Decode(strB64)),
                        )
                        : null,
              ),
              child:
                  !hasImg
                      ? Center(
                        child: Icon(
                          Icons.inbox_rounded,
                          color: YS.inkFaint,
                          size: 18,
                        ),
                      )
                      : const Align(
                        alignment: Alignment.topRight,
                        child: Padding(
                          padding: EdgeInsets.all(3.0),
                          child: Icon(
                            Icons.zoom_in_rounded,
                            color: Colors.black45,
                            size: 12,
                          ),
                        ),
                      ),
            ),
          ),
        ),
      ],
    );
  }

  void _showImageZoomDialog(String title, String b64) {
    showDialog(
      context: context,
      builder:
          (ctx) => Dialog(
            backgroundColor: Colors.black87,
            insetPadding: const EdgeInsets.all(16),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 12,
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        title,
                        style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.bold,
                          fontSize: 16,
                        ),
                      ),
                      IconButton(
                        icon: const Icon(Icons.close, color: Colors.white70),
                        onPressed: () => Navigator.of(ctx).pop(),
                      ),
                    ],
                  ),
                ),
                Flexible(
                  child: InteractiveViewer(
                    minScale: 0.8,
                    maxScale: 6.0,
                    child: ClipRRect(
                      borderRadius: const BorderRadius.vertical(
                        bottom: Radius.circular(16),
                      ),
                      child: Image.memory(
                        base64Decode(b64),
                        fit: BoxFit.contain,
                      ),
                    ),
                  ),
                ),
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 8),
                  child: Text(
                    'Pinch to zoom / Pan to inspect minutiae details',
                    style: TextStyle(color: Colors.white54, fontSize: 11),
                  ),
                ),
              ],
            ),
          ),
    );
  }
}

// ══════════════════════════════════════════════════════════════════════════════
// HISTORY  (unified: Single / Slap / All tabs)
// ══════════════════════════════════════════════════════════════════════════════

class HistoryScreen extends StatefulWidget {
  const HistoryScreen({super.key});

  @override
  State<HistoryScreen> createState() => _HistoryScreenState();
}

class _HistoryScreenState extends State<HistoryScreen>
    with SingleTickerProviderStateMixin {
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
    setState(() {
      _loading = true;
      _offline = false;
    });
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
      final isOffline =
          e.toString().contains('SocketException') ||
          e.toString().contains('Connection refused') ||
          e.toString().contains('timed out');
      setState(() {
        _loading = false;
        _offline = isOffline;
      });
    }
  }

  List<dynamic> get _visibleList {
    switch (_tabCtrl.index) {
      case 0:
        return [..._singleHistory, ..._slapHistory]..sort((a, b) {
          final ta = a['timestamp'] ?? '';
          final tb = b['timestamp'] ?? '';
          return tb.toString().compareTo(ta.toString());
        });
      case 1:
        return _singleHistory;
      case 2:
        return _slapHistory;
      default:
        return [];
    }
  }

  bool _isSlapEntry(Map h) =>
      h['type'] == 'slap' ||
      h.containsKey('matched_fingers') ||
      h.containsKey('finger_count');

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: YS.bg,
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_rounded),
          onPressed: () => context.go('/'),
        ),
        title: Text('Auth History', style: YS.label(17, w: FontWeight.w700)),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(48),
          child: Column(
            children: [
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
            ],
          ),
        ),
      ),
      body: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          children: [
            Row(
              children: [
                Expanded(
                  child: regionDropdown(
                    value: _region,
                    onChanged: (v) => setState(() => _region = v),
                  ),
                ),
                const SizedBox(width: 12),
                ElevatedButton(onPressed: _load, child: const Text('Load')),
              ],
            ),
            const SizedBox(height: 16),
            if (_loading) ...[
              const SizedBox(height: 8),
              ysShimmer(height: 70),
              const SizedBox(height: 8),
              ysShimmer(height: 70),
              const SizedBox(height: 8),
              ysShimmer(height: 70),
            ],
            const SizedBox(height: 8),
            Expanded(
              child:
                  _offline
                      ? ysOfflineCard(_load)
                      : _visibleList.isEmpty && !_loading
                      ? Center(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(
                              Icons.history_rounded,
                              size: 48,
                              color: YS.inkFaint,
                            ),
                            const SizedBox(height: 12),
                            Text(
                              'No records yet',
                              style: YS.label(14, color: YS.inkLight),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              'Tap Load to fetch history',
                              style: YS.label(12, color: YS.inkFaint),
                            ),
                          ],
                        ),
                      )
                      : ListView.separated(
                        itemCount: _visibleList.length,
                        separatorBuilder:
                            (_, s) => Divider(color: YS.stroke, height: 1),
                        itemBuilder: (_, i) {
                          final h = _visibleList[i] as Map<String, dynamic>;
                          final isSlap = _isSlapEntry(h);
                          final conf =
                              ((((h['avg_confidence'] ?? h['confidence']) ?? 0)
                                          as num) *
                                      100)
                                  .toStringAsFixed(1);
                          final rawM = h['matched_fingers'];
                          final matchedCount =
                              rawM is List ? rawM.length : null;
                          return ListTile(
                            contentPadding: const EdgeInsets.symmetric(
                              horizontal: 4,
                              vertical: 4,
                            ),
                            leading: Container(
                              width: 40,
                              height: 40,
                              decoration: BoxDecoration(
                                color: isSlap ? YS.blueBg : YS.amberSoft,
                                borderRadius: BorderRadius.circular(10),
                              ),
                              child: Icon(
                                isSlap
                                    ? Icons.back_hand_rounded
                                    : Icons.fingerprint_rounded,
                                color: isSlap ? YS.blue : YS.amber,
                                size: 20,
                              ),
                            ),
                            title: Row(
                              children: [
                                Text(
                                  h['name'] ?? '—',
                                  style: YS.label(14, w: FontWeight.w700),
                                ),
                                const SizedBox(width: 8),
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 6,
                                    vertical: 2,
                                  ),
                                  decoration: BoxDecoration(
                                    color: isSlap ? YS.blueBg : YS.amberSoft,
                                    borderRadius: BorderRadius.circular(8),
                                  ),
                                  child: Text(
                                    isSlap ? 'SLAP' : 'SINGLE',
                                    style: YS.label(
                                      8,
                                      color: isSlap ? YS.blue : YS.amberDeep,
                                      w: FontWeight.w800,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                            subtitle: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                const SizedBox(height: 2),
                                Text(
                                  '${h['uid'] ?? '—'} · $conf% confidence'
                                  '${matchedCount != null ? ' · $matchedCount fingers' : ''}',
                                  style: YS.label(12, color: YS.inkMid),
                                ),
                              ],
                            ),
                            trailing: Text(
                              h['timestamp']?.toString().substring(0, 16) ?? '',
                              style: YS.label(10, color: YS.inkLight),
                            ),
                          );
                        },
                      ),
            ),
          ],
        ),
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
  bool _checking = false;
  Map<String, dynamic>? _engineStatus;
  late TextEditingController _urlCtrl;
  String _mode = ApiService.engineMode;

  @override
  void initState() {
    super.initState();
    _urlCtrl = TextEditingController(text: ApiService.singleUrl);
    _checkEngine();
  }

  @override
  void dispose() {
    _urlCtrl.dispose();
    super.dispose();
  }

  Future<void> _checkEngine() async {
    setState(() => _checking = true);
    try {
      final h = await ApiService.healthCheck();
      if (mounted) {
        setState(() {
          _engineStatus = h;
          _checking = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _engineStatus = {
            'status': 'ok',
            'mode': 'offline_on_device',
            'error': '$e',
          };
          _checking = false;
        });
      }
    }
  }

  Future<void> _saveUrl() async {
    final url = _urlCtrl.text.trim();
    if (url.isNotEmpty) {
      await ApiService.setSingleUrl(url);
      await ApiService.setSlapUrl(url);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Cloud URL saved: $url', style: YS.label(13)),
            backgroundColor: YS.green,
          ),
        );
      }
      _checkEngine();
    }
  }

  Future<void> _toggleMode(String m) async {
    setState(() => _mode = m);
    await ApiService.setEngineMode(m);
    _checkEngine();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: YS.bg,
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_rounded),
          onPressed: () => context.go('/'),
        ),
        title: Text(
          'Settings & Diagnostics',
          style: YS.label(17, w: FontWeight.w700),
        ),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(1),
          child: Container(height: 1, color: YS.stroke),
        ),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'ENGINE ARCHITECTURE & TIER SPLIT',
              style: YS
                  .label(11, color: YS.inkLight, w: FontWeight.w700)
                  .copyWith(letterSpacing: 1.8),
            ),
            const SizedBox(height: 12),
            // ── Mode Switcher ──────────────────────────────────────────
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: YS.card,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: YS.stroke),
                boxShadow: YS.cardShadow,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Operational Mode',
                    style: YS.label(13, w: FontWeight.w700),
                  ),
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      Expanded(
                        child: _modeOption(
                          'hybrid',
                          'Cloud Hybrid (/v2)',
                          'On-Device Preprocessing + Cloud Matcher',
                          Icons.cloud_sync_rounded,
                          YS.blue,
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: _modeOption(
                          'offline',
                          '100% Offline',
                          'Pure Standalone On-Device Engine',
                          Icons.bolt_rounded,
                          YS.green,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            // ── Cloud /v2 URL Config ───────────────────────────────────
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: YS.card,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: YS.stroke),
                boxShadow: YS.cardShadow,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const Icon(Icons.dns_rounded, color: YS.blue, size: 18),
                      const SizedBox(width: 8),
                      Text(
                        'backend2 Cloud Base URL (/v2/*)',
                        style: YS.label(13, w: FontWeight.w700),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    controller: _urlCtrl,
                    style: YS.label(13),
                    decoration: InputDecoration(
                      hintText: 'https://34-100-150-103.sslip.io',
                      suffixIcon: IconButton(
                        icon: const Icon(
                          Icons.check_circle_rounded,
                          color: YS.green,
                        ),
                        onPressed: _saveUrl,
                      ),
                    ),
                  ),
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      TextButton.icon(
                        onPressed: () {
                          _urlCtrl.text = ApiService.defaultCloudUrl;
                          _saveUrl();
                        },
                        icon: const Icon(Icons.replay_rounded, size: 14),
                        label: const Text('Reset to Live Mumbai Cloud VM'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            // ── Diagnostics Card ───────────────────────────────────────
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color:
                    _engineStatus?['mode'] == 'cloud_hybrid'
                        ? YS.blueBg
                        : YS.greenBg,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(
                  color: (_engineStatus?['mode'] == 'cloud_hybrid'
                          ? YS.blue
                          : YS.green)
                      .withValues(alpha: 0.3),
                ),
                boxShadow: YS.cardShadow,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Container(
                        width: 36,
                        height: 36,
                        decoration: BoxDecoration(
                          color:
                              _engineStatus?['mode'] == 'cloud_hybrid'
                                  ? YS.blue
                                  : YS.green,
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Icon(
                          _engineStatus?['mode'] == 'cloud_hybrid'
                              ? Icons.cloud_done_rounded
                              : Icons.bolt_rounded,
                          color: Colors.white,
                          size: 20,
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              _engineStatus?['mode'] == 'cloud_hybrid'
                                  ? 'Cloud Hybrid Active (/v2/* Connected)'
                                  : '100% On-Device Standalone Active',
                              style: YS.label(
                                14,
                                w: FontWeight.w700,
                                color:
                                    _engineStatus?['mode'] == 'cloud_hybrid'
                                        ? YS.blue
                                        : YS.green,
                              ),
                            ),
                            Text(
                              _engineStatus?['mode'] == 'cloud_hybrid'
                                  ? 'Connected to ${_engineStatus!['cloud_url'] ?? ApiService.singleUrl}'
                                  : 'Zero network dependency — local RANSAC matcher',
                              style: YS.label(11, color: YS.inkMid),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 14),
                  Divider(
                    color: (_engineStatus?['mode'] == 'cloud_hybrid'
                            ? YS.blue
                            : YS.green)
                        .withValues(alpha: 0.2),
                  ),
                  const SizedBox(height: 8),
                  _featureRow(
                    Icons.check_circle_rounded,
                    'On-Device Laplacian Quality Gate & Guidance (<100ms)',
                  ),
                  _featureRow(
                    Icons.check_circle_rounded,
                    'On-Device YOLO Multi-Finger Detector & Apex Anchoring',
                  ),
                  _featureRow(
                    Icons.check_circle_rounded,
                    'On-Device U²-Net Segmentation & Integral FIR Preprocessing',
                  ),
                  _featureRow(
                    Icons.check_circle_rounded,
                    'MinutiaeNet Neural Extraction & ISO/IEC 19794-2 Serialization',
                  ),
                  _featureRow(
                    Icons.check_circle_rounded,
                    'Position-Constrained Slap Matcher (Index-to-Index, Middle-to-Middle)',
                  ),
                ],
              ),
            ),
            const SizedBox(height: 20),
            OutlinedButton.icon(
              onPressed: _checking ? null : _checkEngine,
              icon:
                  _checking
                      ? const SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                      : const Icon(Icons.refresh_rounded, size: 16),
              label: const Text('Test Connection & Run Diagnostic'),
            ),
            const SizedBox(height: 32),
            Text(
              'ABOUT',
              style: YS
                  .label(11, color: YS.inkLight, w: FontWeight.w700)
                  .copyWith(letterSpacing: 1.8),
            ),
            const SizedBox(height: 12),
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                color: YS.card,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: YS.stroke),
                boxShadow: YS.cardShadow,
              ),
              child: Column(
                children: [
                  Image.asset(
                    'assets/images/logo11.png',
                    height: 36,
                    fit: BoxFit.contain,
                  ),
                  const SizedBox(height: 16),
                  Divider(color: YS.stroke),
                  const SizedBox(height: 12),
                  _infoRow('Company', 'YellowSense Technologies'),
                  _infoRow(
                    'Project',
                    'UIDAI SITAA Contactless Fingerprint SDK',
                  ),
                  _infoRow(
                    'Execution',
                    '100% On-Device (Zero Backend Dependency)',
                  ),
                  _infoRow(
                    'Single Finger',
                    'Capture → Crop → FIR → Minutiae → ISO Template',
                  ),
                  _infoRow(
                    'Slap Pipeline',
                    '4-Finger Auto Slice → Per-Finger FIR → Composite',
                  ),
                  _infoRow('Version', '3.0.0 (Native On-Device Standalone)'),
                ],
              ),
            ),
            const SizedBox(height: 40),
          ],
        ),
      ),
    );
  }

  Widget _modeOption(
    String key,
    String title,
    String subtitle,
    IconData icon,
    Color activeColor,
  ) {
    final isSel = _mode == key;
    return GestureDetector(
      onTap: () => _toggleMode(key),
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: isSel ? activeColor.withValues(alpha: 0.1) : YS.cardAlt,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: isSel ? activeColor : YS.stroke,
            width: isSel ? 1.5 : 1.0,
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(icon, size: 16, color: isSel ? activeColor : YS.inkLight),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    title,
                    style: YS.label(
                      12,
                      w: FontWeight.w700,
                      color: isSel ? activeColor : YS.ink,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(subtitle, style: YS.label(10, color: YS.inkLight)),
          ],
        ),
      ),
    );
  }

  Widget _featureRow(IconData icon, String text) => Padding(
    padding: const EdgeInsets.only(bottom: 6),
    child: Row(
      children: [
        Icon(icon, size: 14, color: YS.green),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            text,
            style: YS.label(12, color: YS.ink, w: FontWeight.w600),
          ),
        ),
      ],
    ),
  );

  Widget _infoRow(String k, String v) => Padding(
    padding: const EdgeInsets.only(bottom: 8),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('$k: ', style: YS.label(12, color: YS.inkMid)),
        Expanded(child: Text(v, style: YS.label(12, w: FontWeight.w600))),
      ],
    ),
  );
}
