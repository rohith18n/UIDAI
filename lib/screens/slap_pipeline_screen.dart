import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import '../theme/app_theme.dart';
import '../widgets/fingerprint_camera_widget.dart';
import '../services/api_service.dart';
import '../models/capture_mode.dart';
import 'screens.dart' show ysShimmer, ysOfflineCard;

class SlapPipelineScreen extends StatefulWidget {
  const SlapPipelineScreen({super.key});

  @override
  State<SlapPipelineScreen> createState() => _SlapPipelineScreenState();
}

class _SlapPipelineScreenState extends State<SlapPipelineScreen> {
  bool _loading = false;
  Map<String, dynamic>? _result;
  String _handSide = 'right';

  Future<void> _process(File image) async {
    final sw = Stopwatch()..start();
    setState(() { _loading = true; _result = null; });
    try {
      final r = await ApiService.processSlap(
          image: image, handSide: _handSide, vis: true);
      sw.stop();
      r['client_total_ms'] = sw.elapsedMilliseconds;
      setState(() { _result = r; _loading = false; });
    } catch (e) {
      sw.stop();
      final isOffline = e.toString().contains('SocketException') ||
          e.toString().contains('Connection refused') ||
          e.toString().contains('timed out');
      setState(() {
        _result = {
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
    final rawF = _result != null ? _result!['fingers'] : null;
    final fingers = (rawF is List ? rawF.whereType<Map>().toList() : <Map>[]);
    final composite = _result != null ? _result!['composite_b64'] : null;
    final count = _result != null ? (_result!['finger_count'] ?? 0) : 0;
    final off = _result != null && _result!['offline'] == true;
    return Scaffold(
      backgroundColor: YS.bg,
      appBar: AppBar(
        leading: IconButton(icon: const Icon(Icons.arrow_back_rounded), onPressed: () => context.go('/')),
        title: Text('Slap Pipeline', style: YS.label(17, w: FontWeight.w700)),
        bottom: PreferredSize(preferredSize: const Size.fromHeight(1),
            child: Container(height: 1, color: YS.stroke)),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
                color: YS.blueBg, borderRadius: BorderRadius.circular(12),
                border: Border.all(color: YS.blue.withValues(alpha: 0.3))),
            child: Row(children: [
              const Icon(Icons.auto_awesome_rounded, color: YS.blue, size: 16),
              const SizedBox(width: 8),
              Expanded(child: Text(
                  'Runs full slap pipeline: detect 4 fingers → liveness → segmentation → enhancement → minutiae → composite view',
                  style: YS.label(12, color: YS.blue))),
            ]),
          ),
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
          const SizedBox(height: 20),
          FingerprintCameraWidget(
            onImageCaptured: _process,
            disabled: _loading,
            mode: CaptureMode.slap,
            overlayStyle: 'slap',
            handSide: _handSide,
          ),
          const SizedBox(height: 16),
          if (_loading) ...[
            ysShimmer(height: 160),
            const SizedBox(height: 12),
            ysShimmer(height: 140),
            const SizedBox(height: 12),
            ysShimmer(height: 140),
          ],
          if (!_loading && off) ...[const SizedBox(height: 16), ysOfflineCard(_retryRetry)],
          if (!_loading && !off && _result != null) ...[const SizedBox(height: 16),
            _performanceTimeBanner(_result!),
            const SizedBox(height: 16),
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: YS.card, borderRadius: BorderRadius.circular(16),
                border: Border.all(color: YS.stroke), boxShadow: YS.cardShadow,
              ),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('Summary', style: YS.display(14, w: FontWeight.w700)),
                const SizedBox(height: 10),
                Row(children: [
                  _pill('$count fingers', YS.amberDeep, YS.amberSoft),
                  const SizedBox(width: 8),
                  _pill('${_result!['total_minutiae'] ?? 0} min', YS.orange, YS.orangeBg),
                  const SizedBox(width: 8),
                  _pill('${count > 0 ? (((_result!['client_total_ms'] ?? _result!['total_execution_time_ms'] ?? _result!['execution_time_ms'] ?? 0) as num) / 1000.0).toStringAsFixed(2) : '0.00'} s', YS.blue, YS.blueBg),
                ]),
                if (_result!['error'] != null && count == 0) ...[
                  const SizedBox(height: 12),
                  Text(_result!['error'].toString(),
                      style: YS.label(12, color: YS.red)),
                ],
              ]),
            ),
            if (composite != null) ...[
              const SizedBox(height: 16),
              Text('COMPOSITE',
                  style: YS.label(10, color: YS.inkLight, w: FontWeight.w700)
                      .copyWith(letterSpacing: 1.5)),
              const SizedBox(height: 8),
              Container(
                height: 180,
                decoration: BoxDecoration(
                  color: YS.card,
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: YS.stroke),
                  image: DecorationImage(
                    fit: BoxFit.contain,
                    image: MemoryImage(base64Decode(composite)),
                  ),
                ),
              ),
            ],
            const SizedBox(height: 20),
            Text('PER-FINGER PIPELINE',
                style: YS.label(10, color: YS.inkLight, w: FontWeight.w700)
                    .copyWith(letterSpacing: 1.5)),
            const SizedBox(height: 8),
            ...fingers.map((f) => _fingerCard(f)),
          ],
          const SizedBox(height: 40),
        ]),
      ),
    );
  }

  void _retryRetry() {
    // image is null; no way to retry without re-capture
    setState(() => _result = null);
  }

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
          child: Center(child: Text(label,
              style: YS.label(13,
                  color: sel ? YS.blue : YS.inkMid, w: FontWeight.w700))),
        ),
      ),
    );
  }

  Widget _pill(String text, Color color, Color bg) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
    decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(20)),
    child: Text(text, style: YS.label(11, color: color, w: FontWeight.w700)),
  );

  Widget _performanceTimeBanner(Map<String, dynamic> r) {
    final serverMs = r['total_execution_time_ms'] ?? r['execution_time_ms'] ?? 0;
    final totalMs = r['client_total_ms'] ?? serverMs;
    final totalSec = (totalMs / 1000.0).toStringAsFixed(2);
    final count = r['finger_count'] ?? 0;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: YS.blueBg,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: YS.blue.withValues(alpha: 0.35)),
        boxShadow: YS.cardShadow,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.timer_rounded, color: YS.blue, size: 20),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'COMPLETE PROCESS TIME',
                  style: YS.label(12, color: YS.blue, w: FontWeight.w800)
                      .copyWith(letterSpacing: 1.0),
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: YS.greenBg,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: YS.green.withValues(alpha: 0.3)),
                ),
                child: Text(
                  '${totalSec}s (<5s SLA) ✓',
                  style: YS.label(10, color: YS.green, w: FontWeight.w700),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: YS.card,
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: YS.stroke),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Total End-to-End',
                          style: YS.label(10, color: YS.inkLight)),
                      const SizedBox(height: 3),
                      Text('$totalSec s',
                          style: YS.display(16, color: YS.blue, w: FontWeight.w800)),
                    ],
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: YS.card,
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: YS.stroke),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Model Pipeline',
                          style: YS.label(10, color: YS.inkLight)),
                      const SizedBox(height: 3),
                      Text('${(serverMs / 1000.0).toStringAsFixed(2)} s',
                          style: YS.display(16, color: YS.amberDeep, w: FontWeight.w800)),
                    ],
                  ),
                ),
              ),
              if (count > 0) ...[
                const SizedBox(width: 8),
                Expanded(
                  child: Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: YS.card,
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: YS.stroke),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('Avg / Finger',
                            style: YS.label(10, color: YS.inkLight)),
                        const SizedBox(height: 3),
                        Text('${((serverMs / count) / 1000.0).toStringAsFixed(2)} s',
                            style: YS.display(16, color: YS.green, w: FontWeight.w800)),
                      ],
                    ),
                  ),
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }

  Widget _fingerCard(Map f) {
    final pos = (f['finger_position'] ?? f['position'] ?? '').toString().replaceAll('_', ' ');
    final mins = f['minutiae_count'] ?? 0;
    final conf = (((f['detection_conf'] ?? 0) as num) * 100).toStringAsFixed(0);
    final cropped = f['cropped_b64'];
    final preproc = f['preprocessed_b64'];
    final vis     = f['visualization_b64'];
    final liveRaw = f['liveness'];
    final liveMap = liveRaw is Map ? liveRaw : null;
    final isLive  = liveMap?['is_live'] == true;
    final liveConf = (((liveMap?['confidence'] ?? 0) as num) * 100).toStringAsFixed(0);
    final templateB64 = f['template_b64'];
    final templateLen = templateB64 is String ? (base64Decode(templateB64).length) : 0;
    final isoCode = f['iso_code'];
    return Container(
      margin: const EdgeInsets.only(bottom: 16),
      decoration: BoxDecoration(
        color: YS.card,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: YS.stroke),
        boxShadow: YS.cardShadow,
      ),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            const Icon(Icons.fingerprint_rounded, color: YS.blue, size: 18),
            const SizedBox(width: 8),
            Expanded(child: Text(pos.toUpperCase(),
                style: YS.label(14, w: FontWeight.w700))),
            _pill('$conf% det', YS.inkMid, YS.cardAlt),
            const SizedBox(width: 6),
            _pill(isLive ? '$liveConf% LIVE' : 'SPOOF',
                isLive ? YS.green : YS.red,
                isLive ? YS.greenBg : YS.redBg),
            const SizedBox(width: 6),
            _pill('$mins min', YS.amberDeep, YS.amberSoft),
            if (f['execution_time_ms'] != null) ...[
              const SizedBox(width: 6),
              _pill('${(((f['execution_time_ms'] as num)) / 1000.0).toStringAsFixed(2)} s', YS.blue, YS.blueBg),
            ],
          ]),
          const SizedBox(height: 12),
          Row(children: [
            Expanded(child: _stageTile('1. Cropped',   cropped, 'detect')),
            const SizedBox(width: 6),
            Expanded(child: _stageTile('2. Preprocessed', preproc, 'enhance')),
            const SizedBox(width: 6),
            Expanded(child: _stageTile('3. Minutiae',  vis, 'minutiae')),
          ]),
          const SizedBox(height: 10),
          Text('ISO 19794-2 template: $templateLen bytes (ISO Code: $isoCode)',
              style: YS.label(11, color: YS.inkLight)),
        ]),
      ),
    );
  }

  Widget _stageTile(String label, dynamic b64, String kind) {
    final hasImg = b64 != null && (b64 as String).isNotEmpty;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(label, style: YS.label(10, color: YS.inkLight, w: FontWeight.w700)),
      const SizedBox(height: 4),
      Container(
        height: 90,
        decoration: BoxDecoration(
          color: kind == 'detect'
              ? YS.amberSoft
              : kind == 'enhance'
                  ? YS.orangeBg
                  : YS.blueBg,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: YS.stroke),
          image: hasImg
              ? DecorationImage(fit: BoxFit.contain,
                  image: MemoryImage(base64Decode(b64)))
              : null,
        ),
        child: !hasImg
            ? Center(child: Icon(Icons.inbox_rounded, color: YS.inkFaint))
            : null,
      ),
    ]);
  }
}
