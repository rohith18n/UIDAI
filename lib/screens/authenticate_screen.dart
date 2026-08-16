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
          _isSlap ? 'Slap Authenticate' : 'Authenticate',
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
                          ? 'Matches all 4 fingers against enrolled slap users in batch'
                          : 'Matches against all enrolled users in the batch',
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
                  _handChip('right', 'Right hand'),
                  const SizedBox(width: 10),
                  _handChip('left', 'Left hand'),
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
    final ok = r['success'] == true;
    final color = ok ? YS.green : YS.red;
    final bg = ok ? YS.greenBg : YS.redBg;
    String msg = ok ? 'Match Verified' : (r['message'] ?? r['error'] ?? 'No match found');
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
                      ok ? 'AUTHENTICATED' : 'NOT RECOGNIZED',
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
              '${(((avgConf as num)) * 100).toStringAsFixed(1)}% (Threshold: 60.0%)',
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
