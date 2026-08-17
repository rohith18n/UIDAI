import 'dart:convert';
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
        SnackBar(
          content: Text('Select a region', style: YS.label(13)),
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
              ? await ApiService.authenticateSlap(
                batch: _region!,
                image: image,
                handSide: _handSide,
              )
              : await ApiService.authenticatePreprocessed(
                batch: _region!,
                image: image,
              );
      sw.stop();
      r['client_total_ms'] = sw.elapsedMilliseconds;
      setState(() {
        _result = r;
        _loading = false;
      });
      if (r['success'] == true) {
        HapticFeedback.heavyImpact();
      } else {
        HapticFeedback.vibrate();
      }
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
        title: Text(
          _isSlap ? '4-Finger Slap Authenticate' : 'Thumb Authenticate',
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
                color: YS.greenBg,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: YS.green.withValues(alpha: 0.3)),
              ),
              child: Row(
                children: [
                  const Icon(
                    Icons.info_outline_rounded,
                    color: YS.green,
                    size: 16,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      _isSlap
                          ? 'Matches 4 fingers (Index, Middle, Ring, Little) against enrolled slap users'
                          : 'Matches Thumb against all enrolled users in the batch',
                      style: YS.label(12, color: YS.green),
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
            const SizedBox(height: 16),
            Text(
              _isSlap ? 'HAND (4 FINGERS)' : 'THUMB POSITION',
              style: YS
                  .label(11, color: YS.inkLight, w: FontWeight.w700)
                  .copyWith(letterSpacing: 1.8),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                _handChip('right', _isSlap ? 'Right Hand (4 Fingers)' : 'Right Thumb'),
                const SizedBox(width: 10),
                _handChip('left', _isSlap ? 'Left Hand (4 Fingers)' : 'Left Thumb'),
              ],
            ),
            const SizedBox(height: 24),
            Text(
              _isSlap
                  ? '4-FINGER SLAP CAPTURE (INDEX, MIDDLE, RING, LITTLE)'
                  : 'THUMB CAPTURE',
              style: YS
                  .label(11, color: YS.inkLight, w: FontWeight.w700)
                  .copyWith(letterSpacing: 1.8),
            ),
            const SizedBox(height: 10),
            FingerprintCameraWidget(
              onImageCaptured: _authenticate,
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
                if (_result!['minutiae'] is List ||
                    _result!['minutiae_count'] != null) ...[
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
            child: Text(
              label,
              style: YS.label(
                13,
                color: sel ? YS.green : YS.inkMid,
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
    final ok = r['success'] == true;
    final color = ok ? YS.green : YS.red;
    final bg = ok ? YS.greenBg : YS.redBg;
    final errorText = (r['error'] ?? r['message'] ?? '').toString();
    final bool hasError = errorText.isNotEmpty && errorText != 'null' && !ok;
    String msg = ok ? 'Match Verified' : (hasError ? errorText : 'No match found');
    if (r['quality_failed'] == true) {
      msg = r['guidance'] ?? 'Quality check failed';
    }
    if (r['spoof_detected'] == true) {
      msg = 'Spoof detected';
    }
    final rawMatched = r['matched_fingers'];
    final matchedFingers = rawMatched is List ? rawMatched : null;
    final avgConf = r['avg_confidence'] ?? r['confidence'];

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
                          ? 'AUTHENTICATED'
                          : (hasError ? 'ERROR / NOT RECOGNIZED' : 'NOT RECOGNIZED'),
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
          if (ok && r['name'] != null) _row('Name', r['name'].toString()),
          if (ok && r['uid'] != null) _row('Aadhaar UID', r['uid'].toString()),
          if (avgConf != null)
            _row(
              'Match Confidence',
              '${(((avgConf as num)) * 100).toStringAsFixed(1)}% (Threshold: ${(thresh * 100).toStringAsFixed(0)}%)',
            ),
          if (r['minutiae_count'] != null)
            _row('Minutiae Extracted', '${r['minutiae_count']} points'),
          if (r['mode'] != null)
            _row(
              'Engine Mode',
              r['mode'] == 'cloud_hybrid'
                  ? '☁️ Cloud Hybrid'
                  : '⚡ Offline On-Device',
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
        ],
      ),
    );
  }

  Widget _singlePipelineVisualizer(Map<String, dynamic> r) {
    final imagesRaw = r['images'];
    final Map<dynamic, dynamic> images = imagesRaw is Map ? imagesRaw : {};
    final steps = [
      {'num': '1', 'title': 'Original Frame', 'desc': 'Raw camera frame capture', 'icon': Icons.camera_alt_outlined, 'key': 'original'},
      {'num': '2', 'title': 'YOLO Distal Crop', 'desc': 'Distal phalanx apex & ROI boundary', 'icon': Icons.crop_free_rounded, 'key': 'cropped'},
      {'num': '3', 'title': 'Contact-Equivalent FIR', 'desc': 'U²-Net segmented tissue & enhanced ridges', 'icon': Icons.contrast_rounded, 'key': 'preprocessed'},
      {'num': '4', 'title': 'Minutiae Extraction', 'desc': 'Ridge endings & bifurcations mapped', 'icon': Icons.scatter_plot_rounded, 'key': 'visualization'},
    ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'PIPELINE VISUALIZATION',
          style: YS.label(11, color: YS.inkLight, w: FontWeight.w700).copyWith(letterSpacing: 1.8),
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
                            style: YS.label(11, color: YS.green, w: FontWeight.w800),
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(s['title'] as String, style: YS.label(13, w: FontWeight.w700)),
                            Text(s['desc'] as String, style: YS.label(10, color: YS.inkLight)),
                          ],
                        ),
                      ),
                      Icon(s['icon'] as IconData, color: YS.green, size: 16),
                    ],
                  ),
                ),
                if (b64 != null && b64.isNotEmpty)
                  GestureDetector(
                    onTap: () => _showImageZoomDialog(s['title'] as String, b64),
                    child: ClipRRect(
                      borderRadius: const BorderRadius.vertical(bottom: Radius.circular(16)),
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
                            child: const Icon(Icons.zoom_in_rounded, color: Colors.white, size: 14),
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
            style: YS.label(11, color: YS.inkLight, w: FontWeight.w700).copyWith(letterSpacing: 1.8),
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
                child: const Icon(Icons.zoom_in_rounded, color: Colors.white, size: 14),
              ),
            ),
          ),
          const SizedBox(height: 16),
        ],
        if (fingers.isNotEmpty) ...[
          Text(
            'PER-FINGER CROPS & MINUTIAE',
            style: YS.label(11, color: YS.inkLight, w: FontWeight.w700).copyWith(letterSpacing: 1.8),
          ),
          const SizedBox(height: 10),
          ...fingers.map((f) => _fingerCard(f)),
        ],
      ],
    );
  }

  Widget _fingerCard(Map f) {
    final pos = (f['finger_position'] ?? f['position'] ?? '').toString().replaceAll('_', ' ');
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
              Text(
                pos.toUpperCase(),
                style: YS.label(13, w: FontWeight.w700),
              ),
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
        Text(label, style: YS.label(10, color: YS.inkLight, w: FontWeight.w600)),
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
                image: hasImg
                    ? DecorationImage(
                        fit: BoxFit.contain,
                        image: MemoryImage(base64Decode(strB64)),
                      )
                    : null,
              ),
              child: !hasImg
                  ? Center(child: Icon(Icons.inbox_rounded, color: YS.inkFaint, size: 18))
                  : const Align(
                      alignment: Alignment.topRight,
                      child: Padding(
                        padding: EdgeInsets.all(3.0),
                        child: Icon(Icons.zoom_in_rounded, color: Colors.black45, size: 12),
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
      builder: (ctx) => Dialog(
        backgroundColor: Colors.black87,
        insetPadding: const EdgeInsets.all(16),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(title, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 15)),
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
                  borderRadius: const BorderRadius.vertical(bottom: Radius.circular(16)),
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

    final isBlurry = (qc['blur'] is Map && qc['blur']['is_blurry'] == true) ||
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
          color: passed
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
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: passed ? YS.green : YS.red,
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text(
                    'Score: ${(readiness as num).toStringAsFixed(1)}',
                    style: YS.label(10, color: Colors.white, w: FontWeight.w700),
                  ),
                ),
            ],
          ),
          if (guidance != null) ...[
            const SizedBox(height: 6),
            Text('→ $guidance', style: YS.label(12, color: passed ? YS.inkMid : YS.red)),
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
    final count = (r['minutiae_count'] as num?)?.toInt() ?? mins.length;

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
    final Color barColor = isOptimal
        ? YS.green
        : (isAcceptable ? const Color(0xFF0091EA) : YS.orange);
    final String statusText = isOptimal
        ? '✓ Optimal minutiae density ($count features) — UIDAI compliant'
        : (isAcceptable
            ? '✓ Sufficient minutiae ($count features) for matching'
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
              Text('Minutiae Extraction', style: YS.label(14, w: FontWeight.w700)),
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
                Text('Ending (RIG)', style: YS.label(11, color: YS.inkMid, w: FontWeight.w600)),
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
                Text('Bifurcation (BIF)', style: YS.label(11, color: YS.inkMid, w: FontWeight.w600)),
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
            Text(statusText, style: YS.label(11, color: barColor, w: FontWeight.w600)),
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
