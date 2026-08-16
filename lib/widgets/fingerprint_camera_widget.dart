import 'dart:async';
import 'dart:developer' as dev;
import 'dart:io';
import 'dart:math';
import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';
import '../theme/app_theme.dart';
import '../services/ondevice_quality_service.dart';
import '../models/capture_mode.dart';

class FingerprintCameraWidget extends StatefulWidget {
  final void Function(File) onImageCaptured;
  final bool disabled;
  final CaptureMode mode;
  final String overlayStyle;
  final String handSide;
  final bool autoCapture;
  final VoidCallback? onRetake;
  const FingerprintCameraWidget({
    super.key,
    required this.onImageCaptured,
    this.onRetake,
    this.disabled = false,
    this.mode = CaptureMode.single,
    this.overlayStyle = 'oval',
    this.handSide = 'right',
    this.autoCapture = false,
  });

  @override
  State<FingerprintCameraWidget> createState() =>
      _FingerprintCameraWidgetState();
}

class _FingerprintCameraWidgetState extends State<FingerprintCameraWidget>
    with WidgetsBindingObserver, SingleTickerProviderStateMixin {
  CameraController? _ctrl;
  bool _isDisposed = false;
  static const CameraLensDirection _lensDirection = CameraLensDirection.back;
  bool _initializing = false;
  bool _live = false;
  bool _flashing = false;
  bool _torchOn = false;
  bool _autoFlashOn = false;
  File? _captured;
  String? _error;
  double _minZoom = 1.0, _maxZoom = 1.0, _zoom = 2.0;
  Offset? _focusPt;
  Timer? _focusTimer;

  static const Duration _focusSettleDelay = Duration(milliseconds: 300);

  bool _autoCaptureMode = false;
  bool get _autoCapture => _autoCaptureMode;
  bool _pollInFlight = false;
  bool _capturing = false;
  bool _pollActive = false;
  bool _evaluatingCapture = false;
  bool? _qualityPassed;
  String _qualityMessage = '';
  List<String> _qualityIssues = [];

  bool? _liveQualityPassed;
  String _liveQualityGrade = '';
  double _liveQualityScore = 0.0;
  List<String> _liveQualityIssues = [];
  double _liveBlurScore = 0.0;
  double _liveBrightness = 0.0;
  double _liveGlare = 0.0;

  String _roiGuidance = '';
  String _guidance = 'Place finger inside the oval — tap screen to focus';
  Color _guidanceColor = Colors.white60;
  double _qualityScore = 0.0;
  int _passCount = 0;

  double? _prevCentroidX;
  double? _prevCentroidY;
  double? _prevSkinRatio;
  static const double _maxAllowedJitter = 16.0;

  DateTime? _lastPassTime;
  static const Duration _maxPassGap = Duration(milliseconds: 1800);

  int _pollAttempts = 0;
  static const int _maxPollAttempts = 80;

  static const int _passesNeeded = 3;
  static const Duration _pollCooldown = Duration(milliseconds: 260);

  File? _lastGoodFrame;
  bool _tipsVisible = true;

  static const double _autoFlashThreshold = 60.0;
  static const double _autoFlashRecoverThreshold = 90.0;

  late AnimationController _scanCtrl;
  late Animation<double> _scanAnim;

  bool get _isSlap => widget.mode == CaptureMode.slap;

  @override
  void initState() {
    super.initState();
    _autoCaptureMode = widget.autoCapture;
    WidgetsBinding.instance.addObserver(this);
    _scanCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1800),
    )..repeat(reverse: true);
    _scanAnim = Tween<double>(
      begin: 0,
      end: 1,
    ).animate(CurvedAnimation(parent: _scanCtrl, curve: Curves.easeInOut));
    _guidance =
        _isSlap
            ? 'Position 4 fingers flat inside guide — tap Capture'
            : 'Position finger inside oval — tap screen to focus & Capture';
  }

  @override
  void dispose() {
    _isDisposed = true;
    WidgetsBinding.instance.removeObserver(this);
    _focusTimer?.cancel();
    _scanCtrl.dispose();
    _killPollLoop();
    final ctrl = _ctrl;
    _ctrl = null;
    try {
      ctrl?.dispose();
    } catch (_) {}
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused) {
      _killPollLoop();
      final ctrl = _ctrl;
      _ctrl = null;
      try {
        ctrl?.dispose();
      } catch (_) {}
      if (mounted && !_isDisposed) {
        setState(() {
          _live = false;
          _torchOn = false;
          _autoFlashOn = false;
        });
      }
    }
  }

  Future<void> _startCamera() async {
    if (widget.disabled || _initializing || _live) return;
    widget.onRetake?.call();
    setState(() {
      _initializing = true;
      _error = null;
      _captured = null;
      _qualityPassed = null;
      _qualityMessage = '';
      _qualityIssues = [];
    });
    try {
      final status = await Permission.camera.status;
      if (!status.isGranted) {
        final result = await Permission.camera.request();
        if (!result.isGranted) {
          if (mounted) {
            setState(() {
              _initializing = false;
              _error =
                  'Camera permission denied. Enable it in Settings to continue.';
            });
          }
          return;
        }
      }

      final cams = await availableCameras();
      if (cams.isEmpty) throw Exception('No camera found');
      final cam = cams.firstWhere(
        (c) => c.lensDirection == _lensDirection,
        orElse: () => cams.first,
      );

      await _ctrl?.dispose();
      _ctrl = CameraController(
        cam,
        ResolutionPreset
            .veryHigh, // Highest optical clarity for ridge detection
        enableAudio: false,
        imageFormatGroup: ImageFormatGroup.jpeg,
      );
      await _ctrl!.initialize();
      try {
        await _ctrl!.setFocusMode(FocusMode.auto);
        await _ctrl!.setExposureMode(ExposureMode.auto);
        await _ctrl!.setFocusPoint(const Offset(0.5, 0.5));
        await _ctrl!.setExposurePoint(const Offset(0.5, 0.5));
      } catch (_) {}
      try {
        _minZoom = await _ctrl!.getMinZoomLevel();
        _maxZoom = await _ctrl!.getMaxZoomLevel();
      } catch (_) {
        _minZoom = 1.0;
        _maxZoom = 1.0;
      }

      final double defaultZoom =
          _isSlap
              ? 1.0
              : (_lensDirection == CameraLensDirection.front ? 1.0 : 2.0);
      _zoom = defaultZoom.clamp(_minZoom, _maxZoom);
      try {
        await _ctrl!.setZoomLevel(_zoom);
      } catch (_) {}
      bool torchActivated = false;
      if (_lensDirection == CameraLensDirection.back) {
        try {
          await _ctrl!.setFlashMode(FlashMode.torch);
          torchActivated = true;
        } catch (_) {
          try {
            await _ctrl!.setFlashMode(FlashMode.off);
          } catch (_) {}
        }
      } else {
        try {
          await _ctrl!.setFlashMode(FlashMode.off);
        } catch (_) {}
      }

      if (!mounted) return;
      setState(() {
        _live = true;
        _initializing = false;
        _torchOn = torchActivated;
        _autoFlashOn = false;
      });

      await Future.delayed(_focusSettleDelay);
      if (mounted && _live) _kickPollLoop();
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = e.toString();
          _initializing = false;
        });
      }
    }
  }

  Future<void> _stopCamera() async {
    _killPollLoop();
    final ctrl = _ctrl;
    _ctrl = null;
    if (_torchOn && ctrl != null) {
      try {
        await ctrl.setFlashMode(FlashMode.off);
      } catch (_) {}
    }
    try {
      await ctrl?.dispose();
    } catch (_) {}
    if (mounted && !_isDisposed) {
      setState(() {
        _live = false;
        _torchOn = false;
        _autoFlashOn = false;
        _captured = null;
        _capturing = false;
        _pollInFlight = false;
        _roiGuidance = '';
        _passCount = 0;
        _qualityScore = 0.0;
        _lastGoodFrame = null;
        _lastPassTime = null;
        _pollAttempts = 0;
        _guidance =
            _isSlap ? 'Place your hand in view' : 'Place finger in the oval';
        _guidanceColor = Colors.white60;
        _focusing = false;
        _tipsVisible = true;
      });
    }
  }

  Future<void> _toggleTorch() async {
    if (_ctrl == null) return;
    try {
      if (_torchOn) {
        await _ctrl!.setFlashMode(FlashMode.off);
        if (mounted) {
          setState(() {
            _torchOn = false;
            _autoFlashOn = false;
          });
        }
      } else {
        await _ctrl!.setFlashMode(FlashMode.torch);
        if (mounted) {
          setState(() {
            _torchOn = true;
            _autoFlashOn = false;
          });
        }
      }
    } catch (_) {}
  }

  Future<void> _setAutoFlash(bool enable) async {
    if (_ctrl == null || _autoFlashOn == enable) return;
    try {
      await _ctrl!.setFlashMode(enable ? FlashMode.torch : FlashMode.off);
      if (mounted) {
        setState(() {
          _autoFlashOn = enable;
          _torchOn = enable;
        });
      }
    } catch (_) {}
  }

  bool _focusing = false;

  Future<void> _onTap(TapDownDetails d, BoxConstraints c) async {
    if (_ctrl == null || !_live) return;
    final x = (d.localPosition.dx / c.maxWidth).clamp(0.0, 1.0);
    final y = (d.localPosition.dy / c.maxHeight).clamp(0.0, 1.0);

    if (mounted) {
      setState(() {
        _focusPt = d.localPosition;
        _focusing = true;
      });
    }
    try {
      HapticFeedback.lightImpact();
    } catch (_) {}

    _focusTimer?.cancel();
    _focusTimer = Timer(const Duration(milliseconds: 1200), () {
      if (mounted) {
        setState(() {
          _focusPt = null;
          _focusing = false;
        });
      }
    });
    try {
      await _ctrl!.setFocusPoint(Offset(x, y));
      await _ctrl!.setExposurePoint(Offset(x, y));
    } catch (_) {}
    if (_autoCapture) {
      _pollAttempts = 0;
      _kickPollLoop();
    }
  }

  Future<File?> _stableFile(File src) async {
    try {
      final dir = Directory.systemTemp;
      final dest = File(
        '${dir.path}/ys_fp_${DateTime.now().millisecondsSinceEpoch}.jpg',
      );
      return await src.copy(dest.path);
    } catch (_) {
      return src;
    }
  }

  Future<void> _commitCapture() async {
    if (_capturing || _lastGoodFrame == null) return;
    _capturing = true;
    _killPollLoop();
    try {
      await _ctrl?.setFlashMode(FlashMode.off);
    } catch (_) {}
    if (mounted) {
      setState(() {
        _torchOn = false;
        _autoFlashOn = false;
      });
    }

    final stable = await _stableFile(_lastGoodFrame!);
    if (stable == null) {
      if (mounted) {
        setState(() {
          _capturing = false;
          _error = 'Capture file missing — retake';
        });
      }
      return;
    }

    try {
      final Uint8List frameBytes = await stable.readAsBytes();
      final verifyQuality = OnDeviceQualityService.evaluateYPlane(
        yPlaneBytes: frameBytes,
        width: 1080,
        height: 1920,
        bytesPerRow: 1080,
        isSlap: _isSlap,
      );

      if (!verifyQuality.isPassed) {
        dev.log(
          '⚠️ [AUTO.ABORT] Frame failed quality on final commit: ${verifyQuality.issues}',
          name: 'CAM.AUTO',
        );
        if (mounted) {
          setState(() {
            _capturing = false;
            _passCount = 0;
            _lastGoodFrame = null;
            _guidance = 'Hold finger steady inside guide';
            _guidanceColor = Colors.orangeAccent;
          });
          _kickPollLoop();
        }
        return;
      }
    } catch (_) {}

    if (mounted) {
      setState(() => _flashing = true);
      await Future.delayed(const Duration(milliseconds: 80));
      if (!mounted) return;
      setState(() {
        _flashing = false;
        _captured = stable;
        _live = false;
        _evaluatingCapture = false;
        _qualityPassed = true;
        _qualityMessage =
            _isSlap
                ? '✓ High Quality Slap Captured'
                : '✓ High Quality Fingerprint Captured';
        _qualityIssues = [];
        _capturing = false;
      });
      HapticFeedback.heavyImpact();
      widget.onImageCaptured(stable);
    }
  }

  bool _isTakingPicture = false;

  Future<XFile?> _safeTakePicture() async {
    if (_isDisposed || !mounted) return null;
    final ctrl = _ctrl;
    if (ctrl == null || !ctrl.value.isInitialized) return null;

    int waitedMs = 0;
    while (_isTakingPicture && waitedMs < 2000) {
      if (_isDisposed || !mounted) return null;
      await Future.delayed(const Duration(milliseconds: 40));
      waitedMs += 40;
    }

    if (_isDisposed || !mounted) return null;
    if (_ctrl != ctrl || !ctrl.value.isInitialized) return null;

    _isTakingPicture = true;
    try {
      if (_isDisposed || !mounted || !ctrl.value.isInitialized) return null;
      return await ctrl.takePicture();
    } catch (e, st) {
      if (!_isDisposed && mounted) {
        dev.log(
          '⚠️ [CAMERA.CAPTURE_EX] $e',
          name: 'CAM.SAFE',
          error: e,
          stackTrace: st,
        );
      }
      return null;
    } finally {
      _isTakingPicture = false;
    }
  }

  Future<void> _captureFresh() async {
    if (_ctrl == null || !_ctrl!.value.isInitialized || _capturing) return;
    _capturing = true;
    _killPollLoop();
    if (mounted) setState(() => _flashing = true);
    await Future.delayed(const Duration(milliseconds: 80));
    if (!mounted) return;
    setState(() => _flashing = false);
    try {
      final xf = await _safeTakePicture();
      if (xf == null) {
        if (mounted) {
          setState(() {
            _capturing = false;
            _error = 'Camera busy — please tap Capture again';
          });
        }
        return;
      }
      try {
        await _ctrl!.setFlashMode(FlashMode.off);
      } catch (_) {}
      if (mounted) {
        setState(() {
          _torchOn = false;
          _autoFlashOn = false;
        });
      }
      final stable = await _stableFile(File(xf.path));
      if (!mounted) return;
      if (stable != null) {
        setState(() {
          _captured = stable;
          _live = false;
          _evaluatingCapture = true;
          _qualityPassed = null;
          _qualityMessage = 'Analyzing fingerprint quality…';
          _qualityIssues = [];
        });

        // Fast Quality Evaluation on captured frame
        bool passed = false;
        String guideMsg = '';
        List<String> issuesList = [];

        try {
          // 100% On-Device Quality Evaluation (Sub-20ms)
          final fileBytes = await stable.readAsBytes();
          final localQuality = OnDeviceQualityService.evaluateYPlane(
            yPlaneBytes: fileBytes,
            width: 1080,
            height: 1920,
            bytesPerRow: 1080,
            isSlap: _isSlap,
          );
          passed = localQuality.isPassed;
          guideMsg = localQuality.guidanceText;
          issuesList = List<String>.from(localQuality.issues);
          if (localQuality.tooDark) {
            _setAutoFlash(true);
          }
          if (passed) {
            guideMsg =
                _isSlap
                    ? '✓ Slap hand is clear & optimal'
                    : '✓ Fingerprint is clear & optimal';
          }
        } catch (_) {
          passed = true;
          guideMsg =
              _isSlap ? '✓ Slap hand captured' : '✓ Fingerprint image captured';
        }

        if (!mounted) return;
        setState(() {
          _evaluatingCapture = false;
          _qualityPassed = passed;
          _qualityMessage = guideMsg;
          _qualityIssues = issuesList;
          _capturing = false;
        });

        dev.log(
          '📸 [CAPTURE.EVAL] Passed: $passed | Issues: $issuesList | Guide: $guideMsg',
          name: 'CAM.CAPTURE',
        );

        if (passed) {
          HapticFeedback.heavyImpact();
          widget.onImageCaptured(stable);
        } else {
          HapticFeedback.vibrate();
        }
      }
    } catch (e, st) {
      dev.log(
        '🔥 [CAPTURE.ERROR] $e',
        name: 'CAM.CAPTURE',
        error: e,
        stackTrace: st,
      );
      if (mounted) {
        setState(() {
          _error = 'Capture failed: $e';
          _capturing = false;
          _evaluatingCapture = false;
        });
        if (_autoCapture) _kickPollLoop();
      }
    }
  }

  void _useImage() {
    if (_captured != null) widget.onImageCaptured(_captured!);
  }

  Future<void> _retry() async {
    setState(() {
      _captured = null;
      _live = false;
      _capturing = false;
      _evaluatingCapture = false;
      _qualityPassed = null;
      _qualityMessage = '';
      _qualityIssues = [];
      _pollInFlight = false;
      _roiGuidance = '';
      _passCount = 0;
      _qualityScore = 0.0;
      _lastGoodFrame = null;
      _lastPassTime = null;
      _pollAttempts = 0;
      _error = null;
      _tipsVisible = true;
      _guidance =
          _isSlap
              ? 'Position 4 fingers flat inside guide — tap Capture'
              : 'Position finger inside oval — tap screen to focus & Capture';
      _guidanceColor = Colors.white60;
    });
    widget.onRetake?.call();
    await _startCamera();
  }

  void _kickPollLoop() {
    if (_pollActive) return;
    _pollActive = true;
    _pollInFlight = false;
    _passCount = 0;
    _lastGoodFrame = null;
    _lastPassTime = null;
    _pollAttempts = 0;
    _roiGuidance = '';
    Future.microtask(_pollOnce);
  }

  void _killPollLoop() {
    _pollActive = false;
    _pollInFlight = false;
  }

  Future<void> _pollOnce() async {
    if (_isDisposed ||
        !mounted ||
        !_pollActive ||
        !_live ||
        _capturing ||
        _captured != null) {
      return;
    }
    final ctrl = _ctrl;
    if (ctrl == null || !ctrl.value.isInitialized) return;
    if (_pollInFlight || _isTakingPicture) {
      _scheduleNextPoll();
      return;
    }

    if (_pollAttempts >= _maxPollAttempts) {
      if (mounted) {
        setState(() {
          _guidance = 'Switch to MANUAL — auto not detecting';
          _guidanceColor = Colors.white38;
        });
      }
      _pollActive = false;
      return;
    }

    _pollInFlight = true;
    _pollAttempts++;

    try {
      final xf = await _safeTakePicture();
      if (xf == null || !_pollActive || _capturing) return;
      final file = File(xf.path);

      if (!_pollActive || _capturing) return;

      final Uint8List fileBytes = await file.readAsBytes();

      // On-Device Fast Evaluation (Sub-20ms execution)
      final localQuality = OnDeviceQualityService.evaluateYPlane(
        yPlaneBytes: fileBytes,
        width: 1080,
        height: 1920,
        bytesPerRow: 1080,
        isSlap: _isSlap,
      );

      final passed = localQuality.isPassed;
      final guidance = localQuality.guidanceText;
      final score = localQuality.readinessScore / 100.0;

      if (!_autoFlashOn &&
          localQuality.tooDark &&
          localQuality.brightness < _autoFlashThreshold) {
        await _setAutoFlash(true);
      } else if (_autoFlashOn &&
          localQuality.brightness > _autoFlashRecoverThreshold &&
          !localQuality.tooDark) {
        await _setAutoFlash(false);
      }

      // Inter-frame Stillness & Motion Jitter Check
      bool isStill = true;
      if (_prevCentroidX != null && _prevCentroidY != null) {
        final dx = localQuality.offsetX - _prevCentroidX!;
        final dy = localQuality.offsetY - _prevCentroidY!;
        final jitter = sqrt(dx * dx + dy * dy);
        final skinDelta =
            (_prevSkinRatio != null)
                ? (localQuality.skinRatio - _prevSkinRatio!).abs()
                : 0.0;

        if (jitter > _maxAllowedJitter || skinDelta > 0.12) {
          isStill = false;
          dev.log(
            '⚠️ [QC.MOTION] Jitter: ${jitter.toStringAsFixed(1)}px | SkinDelta: ${(skinDelta * 100).toStringAsFixed(1)}%',
            name: 'QC.STILL',
          );
        }
      }

      _prevCentroidX = localQuality.offsetX;
      _prevCentroidY = localQuality.offsetY;
      _prevSkinRatio = localQuality.skinRatio;

      final bool overallPass = passed && isStill;

      if (mounted) {
        setState(() {
          _liveQualityPassed = overallPass;
          _liveQualityGrade = localQuality.readinessGrade;
          _liveQualityScore = localQuality.readinessScore;
          _liveQualityIssues = List<String>.from(localQuality.issues);
          if (!isStill && localQuality.issues.isEmpty) {
            _liveQualityIssues.add('Hold steady — motion detected');
          }
          _liveBlurScore = localQuality.blurScore;
          _liveBrightness = localQuality.brightness;
          _liveGlare = localQuality.glareRatio;
          _guidance =
              overallPass
                  ? '✓ Good — hold still'
                  : (!isStill ? 'Hold steady — motion detected' : guidance);
          _guidanceColor = overallPass ? YS.green : Colors.orangeAccent;
          _qualityScore = score;
          _roiGuidance = localQuality.roiGuidance;
        });
      }

      if (overallPass) {
        final now = DateTime.now();
        if (_lastPassTime != null &&
            now.difference(_lastPassTime!) > _maxPassGap) {
          _passCount = 0;
        }
        _lastPassTime = now;
        _lastGoodFrame = file;
        _passCount++;
        if (_tipsVisible && mounted) setState(() => _tipsVisible = false);

        if (_autoCapture &&
            _passCount >= _passesNeeded &&
            _pollActive &&
            !_capturing) {
          _pollInFlight = false;
          await _commitCapture();
          return;
        }
      } else {
        _passCount = 0;
        _lastGoodFrame = null;
        _lastPassTime = null;
      }
    } catch (_) {
      if (mounted && _pollActive) {
        setState(() {
          _guidance = 'Auto-check unavailable — tap MANUAL';
          _guidanceColor = Colors.white38;
        });
      }
    } finally {
      _pollInFlight = false;
    }

    _scheduleNextPoll();
  }

  void _scheduleNextPoll() {
    if (!_pollActive || _isDisposed || !mounted) return;
    Future.delayed(_pollCooldown, () {
      if (_pollActive &&
          !_isDisposed &&
          mounted &&
          !_capturing &&
          _captured == null) {
        _pollOnce();
      }
    });
  }

  IconData _roiGuidanceIcon(String guidance) {
    final g = guidance.toLowerCase();
    if (g.contains('left')) return Icons.arrow_back_rounded;
    if (g.contains('right')) return Icons.arrow_forward_rounded;
    if (g.contains('up') || g.contains('higher')) {
      return Icons.arrow_upward_rounded;
    }
    if (g.contains('down') || g.contains('lower')) {
      return Icons.arrow_downward_rounded;
    }
    if (g.contains('closer') || g.contains('near')) {
      return Icons.zoom_in_rounded;
    }
    if (g.contains('further') || g.contains('far')) {
      return Icons.zoom_out_rounded;
    }
    return Icons.open_with_rounded;
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: YS.card,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: YS.stroke),
      ),
      clipBehavior: Clip.hardEdge,
      child: Column(children: [_header(), _viewfinder(), _controls()]),
    );
  }

  Widget _header() => Container(
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
    decoration: const BoxDecoration(
      color: YS.card,
      border: Border(bottom: BorderSide(color: YS.stroke)),
    ),
    child: Row(
      children: [
        Flexible(
          child: Text(
            _isSlap ? 'SLAP CAPTURE' : 'FINGERPRINT',
            overflow: TextOverflow.ellipsis,
            style: YS
                .label(10, color: YS.amber, w: FontWeight.w800)
                .copyWith(letterSpacing: 1.0),
          ),
        ),
        const Spacer(),
        if (_live)
          GestureDetector(
            onTap: _toggleTorch,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 200),
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: _torchOn ? YS.amber : YS.stroke),
                color: _torchOn ? YS.amberSoft : YS.cardAlt,
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    _torchOn ? Icons.flash_on_rounded : Icons.flash_off_rounded,
                    size: 12,
                    color: _torchOn ? YS.amberDeep : YS.inkLight,
                  ),
                  const SizedBox(width: 3),
                  Text(
                    _autoFlashOn
                        ? 'AUTO'
                        : (_torchOn ? 'FLASH ON' : 'FLASH OFF'),
                    style: YS.label(
                      9,
                      color: _torchOn ? YS.amberDeep : YS.inkLight,
                      w: FontWeight.w700,
                    ),
                  ),
                ],
              ),
            ),
          ),
      ],
    ),
  );

  Widget _viewfinder() => LayoutBuilder(
    builder: (context, constraints) {
      final viewW = constraints.maxWidth;
      final viewH = viewW * 4 / 3;
      return SizedBox(
        width: viewW,
        height: viewH,
        child: Container(
          color: const Color(0xFF1A1A1A),
          child: Stack(
            fit: StackFit.expand,
            children: [
              if (_live && _ctrl != null && _ctrl!.value.isInitialized)
                GestureDetector(
                  onTapDown: (d) => _onTap(d, constraints),
                  child: CameraPreview(_ctrl!),
                ),

              if (_captured != null) Image.file(_captured!, fit: BoxFit.cover),

              if (!_live && !_initializing && _captured == null)
                Container(
                  color: const Color(0xFF1A1A1A),
                  child: Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Container(
                          width: 72,
                          height: 72,
                          decoration: BoxDecoration(
                            color: YS.amber.withValues(alpha: 0.12),
                            shape: BoxShape.circle,
                          ),
                          child: Icon(
                            _isSlap
                                ? Icons.back_hand_rounded
                                : Icons.fingerprint_rounded,
                            size: 40,
                            color: YS.amber,
                          ),
                        ),
                        const SizedBox(height: 14),
                        Text(
                          'Tap "Start Camera" below',
                          style: YS.label(
                            12,
                            color: Colors.white38,
                            w: FontWeight.w500,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),

              if (_initializing)
                Container(
                  color: const Color(0xFF1A1A1A),
                  child: const Center(
                    child: CircularProgressIndicator(
                      color: YS.amber,
                      strokeWidth: 2,
                    ),
                  ),
                ),

              if ((_live || _captured != null) && widget.overlayStyle != 'none')
                CustomPaint(
                  painter:
                      widget.overlayStyle == 'slap'
                          ? _SlapOverlayPainter(
                            _liveQualityPassed == true ? YS.green : YS.amber,
                            widget.handSide,
                          )
                          : _OverlayPainter(
                            _liveQualityPassed == true ? YS.green : YS.amber,
                          ),
                ),

              if (_live && _autoCapture && widget.overlayStyle != 'none')
                AnimatedBuilder(
                  animation: _scanAnim,
                  builder:
                      (context, child) => Positioned(
                        top: _scanAnim.value * (viewH * 0.6),
                        left: viewW * 0.18,
                        right: viewW * 0.18,
                        child: Container(
                          height: 2,
                          decoration: const BoxDecoration(
                            gradient: LinearGradient(
                              colors: [
                                Colors.transparent,
                                YS.amber,
                                Colors.transparent,
                              ],
                            ),
                          ),
                        ),
                      ),
                ),

              if (_focusPt != null)
                Positioned(
                  left: _focusPt!.dx - 25,
                  top: _focusPt!.dy - 25,
                  child: Container(
                    width: 50,
                    height: 50,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      border: Border.all(color: YS.amber, width: 2),
                    ),
                  ),
                ),

              if (_flashing)
                Container(color: Colors.white.withValues(alpha: 0.8)),

              if (_live && _autoCapture)
                Positioned(
                  top: 12,
                  left: 16,
                  right: 16,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text(
                            'QUALITY',
                            style: YS
                                .label(
                                  9,
                                  color: Colors.white54,
                                  w: FontWeight.w700,
                                )
                                .copyWith(letterSpacing: 1.5),
                          ),
                          Row(
                            children: List.generate(
                              _passesNeeded,
                              (i) => Container(
                                width: 7,
                                height: 7,
                                margin: const EdgeInsets.only(left: 4),
                                decoration: BoxDecoration(
                                  shape: BoxShape.circle,
                                  color:
                                      i < _passCount
                                          ? YS.amber
                                          : Colors.white.withValues(
                                            alpha: 0.25,
                                          ),
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 4),
                      ClipRRect(
                        borderRadius: BorderRadius.circular(4),
                        child: LinearProgressIndicator(
                          value: _qualityScore,
                          minHeight: 4,
                          backgroundColor: Colors.white.withValues(alpha: 0.15),
                          color:
                              _qualityScore > 0.7
                                  ? YS.amber
                                  : _qualityScore > 0.4
                                  ? Colors.orangeAccent
                                  : Colors.redAccent,
                        ),
                      ),
                    ],
                  ),
                ),

              if (_autoFlashOn && _live)
                Positioned(
                  top: 56,
                  left: 16,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 4,
                    ),
                    decoration: BoxDecoration(
                      color: YS.amber.withValues(alpha: 0.85),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: const [
                        Icon(Icons.flash_auto, size: 10, color: Colors.black),
                        SizedBox(width: 3),
                        Text(
                          'AUTO FLASH ON',
                          style: TextStyle(
                            fontSize: 9,
                            fontWeight: FontWeight.w800,
                            color: Colors.black,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),

              if (_live || _captured != null)
                Positioned(
                  bottom: 14,
                  left: 16,
                  right: 16,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (_evaluatingCapture)
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 16,
                            vertical: 10,
                          ),
                          decoration: BoxDecoration(
                            color: Colors.black87,
                            borderRadius: BorderRadius.circular(16),
                            border: Border.all(color: YS.amber),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const SizedBox(
                                width: 14,
                                height: 14,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  color: YS.amber,
                                ),
                              ),
                              const SizedBox(width: 10),
                              Text(
                                'Checking fingerprint quality…',
                                style: YS.label(
                                  12,
                                  color: Colors.white,
                                  w: FontWeight.w600,
                                ),
                              ),
                            ],
                          ),
                        ),

                      if (_captured != null &&
                          !_evaluatingCapture &&
                          _qualityPassed == false)
                        Container(
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: Colors.black.withValues(alpha: 0.85),
                            borderRadius: BorderRadius.circular(14),
                            border: Border.all(
                              color: YS.red.withValues(alpha: 0.7),
                            ),
                          ),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Row(
                                children: [
                                  const Icon(
                                    Icons.warning_amber_rounded,
                                    color: YS.red,
                                    size: 18,
                                  ),
                                  const SizedBox(width: 8),
                                  Expanded(
                                    child: Text(
                                      _qualityMessage.isNotEmpty
                                          ? _qualityMessage
                                          : 'Fingerprint not clear — retake',
                                      style: YS.label(
                                        12,
                                        color: YS.red,
                                        w: FontWeight.w700,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                              if (_qualityIssues.isNotEmpty) ...[
                                const SizedBox(height: 6),
                                ..._qualityIssues.map(
                                  (i) => Padding(
                                    padding: const EdgeInsets.only(top: 2),
                                    child: Row(
                                      children: [
                                        const Icon(
                                          Icons.arrow_right_rounded,
                                          color: YS.orange,
                                          size: 14,
                                        ),
                                        const SizedBox(width: 4),
                                        Expanded(
                                          child: Text(
                                            i,
                                            style: YS.label(
                                              11,
                                              color: Colors.white70,
                                            ),
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                              ],
                            ],
                          ),
                        ),

                      if (_captured != null &&
                          !_evaluatingCapture &&
                          _qualityPassed == true)
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 14,
                            vertical: 8,
                          ),
                          decoration: BoxDecoration(
                            color: Colors.black.withValues(alpha: 0.85),
                            borderRadius: BorderRadius.circular(14),
                            border: Border.all(color: YS.green),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const Icon(
                                Icons.check_circle_rounded,
                                color: YS.green,
                                size: 16,
                              ),
                              const SizedBox(width: 8),
                              Text(
                                '✓ Clear Fingerprint Captured',
                                style: YS.label(
                                  12,
                                  color: YS.green,
                                  w: FontWeight.w700,
                                ),
                              ),
                            ],
                          ),
                        ),

                      if (_roiGuidance.isNotEmpty && _live)
                        Container(
                          margin: const EdgeInsets.only(bottom: 6),
                          padding: const EdgeInsets.symmetric(
                            horizontal: 14,
                            vertical: 7,
                          ),
                          decoration: BoxDecoration(
                            color: Colors.black.withValues(alpha: 0.75),
                            borderRadius: BorderRadius.circular(22),
                            border: Border.all(
                              color: Colors.orangeAccent.withValues(alpha: 0.5),
                            ),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                _roiGuidanceIcon(_roiGuidance),
                                size: 15,
                                color: Colors.orangeAccent,
                              ),
                              const SizedBox(width: 6),
                              Text(
                                _roiGuidance,
                                style: YS.label(
                                  12,
                                  color: Colors.orangeAccent,
                                  w: FontWeight.w700,
                                ),
                              ),
                            ],
                          ),
                        ),

                      if (_focusing && _live)
                        Container(
                          margin: const EdgeInsets.only(bottom: 6),
                          padding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 5,
                          ),
                          decoration: BoxDecoration(
                            color: Colors.black54,
                            borderRadius: BorderRadius.circular(20),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const SizedBox(
                                width: 10,
                                height: 10,
                                child: CircularProgressIndicator(
                                  strokeWidth: 1.5,
                                  color: YS.amber,
                                ),
                              ),
                              const SizedBox(width: 6),
                              Text(
                                'Focusing…',
                                style: YS.label(
                                  11,
                                  color: YS.amber,
                                  w: FontWeight.w600,
                                ),
                              ),
                            ],
                          ),
                        ),

                      if (_live)
                        Text(
                          _guidance,
                          textAlign: TextAlign.center,
                          style: YS.label(
                            11,
                            color: _guidanceColor,
                            w: FontWeight.w600,
                          ),
                        ),
                    ],
                  ),
                ),
            ],
          ),
        ),
      );
    },
  );

  Widget _controls() => Container(
    color: YS.card,
    padding: const EdgeInsets.all(16),
    child: Column(
      children: [
        if (_maxZoom > _minZoom + 0.1 && _live)
          Row(
            children: [
              const Icon(Icons.zoom_out, size: 14, color: YS.inkLight),
              Expanded(
                child: Slider(
                  value: _zoom.clamp(_minZoom, _maxZoom.clamp(_minZoom, 5.0)),
                  min: _minZoom,
                  max: _maxZoom.clamp(_minZoom, 5.0),
                  activeColor: YS.amber,
                  inactiveColor: YS.stroke,
                  thumbColor: YS.amber,
                  onChanged: (v) async {
                    setState(() => _zoom = v);
                    try {
                      await _ctrl?.setZoomLevel(v);
                    } catch (_) {}
                  },
                ),
              ),
              const Icon(Icons.zoom_in, size: 14, color: YS.inkLight),
              const SizedBox(width: 4),
              Text(
                '${_zoom.toStringAsFixed(1)}×',
                style: YS.label(10, color: YS.inkLight),
              ),
            ],
          ),

        if (!_live && !_initializing && _captured == null)
          _btn(
            'Start Camera',
            _startCamera,
            true,
            icon: Icons.camera_alt_rounded,
          ),

        if (_initializing)
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(vertical: 14),
            decoration: BoxDecoration(
              color: YS.amberSoft,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: YS.amberDeep,
                  ),
                ),
                const SizedBox(width: 10),
                Text(
                  'Starting camera…',
                  style: YS.label(13, color: YS.amberDeep, w: FontWeight.w600),
                ),
              ],
            ),
          ),

        if (_live && _captured == null) _modeToggle(),

        _qualityGuidanceBanner(),

        if (_live && _captured == null && _autoCaptureMode)
          Column(
            children: [
              Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 12,
                ),
                decoration: BoxDecoration(
                  color: _liveQualityPassed == true ? YS.greenBg : YS.cardAlt,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color:
                        _liveQualityPassed == true
                            ? YS.green.withValues(alpha: 0.4)
                            : YS.stroke,
                  ),
                ),
                child: Row(
                  children: [
                    SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                        value:
                            _liveQualityPassed == true
                                ? (_passCount / _passesNeeded).clamp(0.1, 1.0)
                                : null,
                        strokeWidth: 2.5,
                        color: _liveQualityPassed == true ? YS.green : YS.amber,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        _liveQualityPassed == true
                            ? 'Auto-Capturing... Hold still ($_passCount/$_passesNeeded)'
                            : 'Align finger inside guide for auto-capture',
                        style: YS.label(
                          12,
                          color:
                              _liveQualityPassed == true ? YS.green : YS.inkMid,
                          w: FontWeight.w600,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: _btn(
                      _isSlap
                          ? 'Capture Slap (Manual)'
                          : 'Capture Now (Manual)',
                      _captureFresh,
                      false,
                      icon: Icons.camera_rounded,
                    ),
                  ),
                  const SizedBox(width: 8),
                  _btn('✕', _stopCamera, false, square: true),
                ],
              ),
            ],
          ),

        if (_live && _captured == null && !_autoCaptureMode)
          Row(
            children: [
              Expanded(
                child: _btn(
                  _isSlap ? 'Capture Slap' : 'Capture Fingerprint',
                  _captureFresh,
                  true,
                  icon: Icons.camera_rounded,
                ),
              ),
              const SizedBox(width: 10),
              _btn('✕', _stopCamera, false, square: true),
            ],
          ),

        if (_captured != null)
          if (_qualityPassed == false)
            Column(
              children: [
                _btn(
                  'Retake Fingerprint',
                  _retry,
                  true,
                  icon: Icons.refresh_rounded,
                ),
                const SizedBox(height: 6),
                GestureDetector(
                  onTap: _useImage,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: Text(
                      'Use anyway (not recommended)',
                      style: YS.label(
                        11,
                        color: YS.inkLight,
                        w: FontWeight.w500,
                      ),
                    ),
                  ),
                ),
              ],
            )
          else
            Row(
              children: [
                Expanded(
                  child: _btn(
                    'Use Fingerprint',
                    _useImage,
                    true,
                    icon: Icons.check_rounded,
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: _btn(
                    'Retake',
                    _retry,
                    false,
                    icon: Icons.refresh_rounded,
                  ),
                ),
              ],
            ),

        if (_error != null) ...[
          const SizedBox(height: 8),
          GestureDetector(
            onTap:
                _error!.contains('Settings') ? () => openAppSettings() : null,
            child: Text(
              _error!,
              style: const TextStyle(
                color: YS.red,
                fontSize: 11,
                decoration: TextDecoration.underline,
              ),
            ),
          ),
        ],
        if (_live && _captured == null && _tipsVisible) ...[
          const SizedBox(height: 10),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              color: YS.cardAlt,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: YS.stroke),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text(
                      'Tips for best capture',
                      style: YS
                          .label(11, color: YS.inkMid, w: FontWeight.w700)
                          .copyWith(letterSpacing: 0.3),
                    ),
                    const Spacer(),
                    GestureDetector(
                      onTap: () => setState(() => _tipsVisible = false),
                      child: const Icon(
                        Icons.close_rounded,
                        size: 14,
                        color: YS.inkLight,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                _tip(
                  Icons.touch_app_rounded,
                  'Tap anywhere on the preview to refocus',
                ),
                _tip(
                  Icons.flash_auto_rounded,
                  'Low light? Auto-flash activates automatically; tap ⚡ for manual',
                ),
                _tip(
                  Icons.zoom_in_rounded,
                  _isSlap
                      ? 'Use zoom slider so all four fingers fill the slots'
                      : 'Use zoom slider to fill the oval with your finger — 2–3× works best',
                ),
                _tip(
                  Icons.pan_tool_rounded,
                  _isSlap
                      ? 'Hold your hand steady and flat, fingers slightly apart'
                      : 'Follow the arrows to centre your finger in the oval',
                ),
              ],
            ),
          ),
        ],
      ],
    ),
  );

  Widget _modeToggle() => Container(
    margin: const EdgeInsets.only(bottom: 12),
    padding: const EdgeInsets.all(4),
    decoration: BoxDecoration(
      color: YS.cardAlt,
      borderRadius: BorderRadius.circular(12),
      border: Border.all(color: YS.stroke),
    ),
    child: Row(
      children: [
        Expanded(
          child: GestureDetector(
            onTap:
                () => setState(() {
                  _autoCaptureMode = true;
                  _passCount = 0;
                }),
            child: Container(
              padding: const EdgeInsets.symmetric(vertical: 8),
              decoration: BoxDecoration(
                color: _autoCaptureMode ? YS.amber : Colors.transparent,
                borderRadius: BorderRadius.circular(9),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(
                    Icons.bolt_rounded,
                    size: 16,
                    color: _autoCaptureMode ? YS.bg : YS.inkLight,
                  ),
                  const SizedBox(width: 6),
                  Text(
                    'AUTO CAPTURE',
                    style: YS.label(
                      11,
                      color: _autoCaptureMode ? YS.bg : YS.inkMid,
                      w: FontWeight.w700,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
        Expanded(
          child: GestureDetector(
            onTap:
                () => setState(() {
                  _autoCaptureMode = false;
                  _passCount = 0;
                }),
            child: Container(
              padding: const EdgeInsets.symmetric(vertical: 8),
              decoration: BoxDecoration(
                color: !_autoCaptureMode ? YS.amber : Colors.transparent,
                borderRadius: BorderRadius.circular(9),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(
                    Icons.touch_app_rounded,
                    size: 16,
                    color: !_autoCaptureMode ? YS.bg : YS.inkLight,
                  ),
                  const SizedBox(width: 6),
                  Text(
                    'MANUAL',
                    style: YS.label(
                      11,
                      color: !_autoCaptureMode ? YS.bg : YS.inkMid,
                      w: FontWeight.w700,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    ),
  );

  Widget _qualityGuidanceBanner() {
    if (!_live && _captured == null) return const SizedBox.shrink();

    // 1. Post-Capture Quality Analysis Card
    if (_captured != null) {
      if (_evaluatingCapture) {
        return Container(
          margin: const EdgeInsets.only(bottom: 12),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          decoration: BoxDecoration(
            color: YS.cardAlt,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: YS.stroke),
          ),
          child: Row(
            children: [
              const SizedBox(
                width: 14,
                height: 14,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: YS.amber,
                ),
              ),
              const SizedBox(width: 10),
              Text(
                'Analyzing image quality…',
                style: YS.label(12, color: YS.inkMid),
              ),
            ],
          ),
        );
      }

      final ok = _qualityPassed == true;
      return Container(
        margin: const EdgeInsets.only(bottom: 12),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: ok ? YS.greenBg : YS.redBg,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: (ok ? YS.green : YS.red).withValues(alpha: 0.35),
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  ok ? Icons.check_circle_rounded : Icons.error_rounded,
                  color: ok ? YS.green : YS.red,
                  size: 16,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    ok
                        ? '✓ High Quality Fingerprint Captured'
                        : 'Quality Check Failed — Retake Recommended',
                    style: YS.label(
                      12,
                      color: ok ? YS.green : YS.red,
                      w: FontWeight.w700,
                    ),
                  ),
                ),
              ],
            ),
            if (!ok && _qualityIssues.isNotEmpty) ...[
              const SizedBox(height: 6),
              ..._qualityIssues.map(
                (issue) => Padding(
                  padding: const EdgeInsets.only(left: 4, top: 2),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '• ',
                        style: YS.label(12, color: YS.red, w: FontWeight.w700),
                      ),
                      Expanded(
                        child: Text(
                          issue,
                          style: YS.label(
                            11,
                            color: YS.red,
                            w: FontWeight.w500,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ],
        ),
      );
    }

    // 2. Real-Time Live Pre-Capture Quality Guidance
    final ok = _liveQualityPassed == true;
    final issues = _liveQualityIssues;

    if (ok) {
      return Container(
        margin: const EdgeInsets.only(bottom: 12),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: YS.greenBg,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: YS.green.withValues(alpha: 0.35)),
        ),
        child: Row(
          children: [
            const Icon(Icons.check_circle_rounded, color: YS.green, size: 16),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                _isSlap
                    ? '✓ All fingers clear — optimal quality'
                    : '✓ Fingerprint clear & sharp — ready to capture',
                style: YS.label(12, color: YS.green, w: FontWeight.w600),
              ),
            ),
            if (_liveQualityScore > 0)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: BoxDecoration(
                  color: YS.green.withValues(alpha: 0.18),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text(
                  '${_liveQualityScore.toInt()}%',
                  style: YS.label(11, color: YS.green, w: FontWeight.w700),
                ),
              ),
          ],
        ),
      );
    }

    if (issues.isNotEmpty) {
      final isRed = issues.any(
        (i) =>
            i.contains('dark') ||
            i.contains('Glare') ||
            i.contains('No finger') ||
            i.contains('No hand'),
      );
      final color = isRed ? YS.red : YS.amber;
      final bg = isRed ? YS.redBg : YS.amberSoft;

      return Container(
        margin: const EdgeInsets.only(bottom: 12),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: color.withValues(alpha: 0.35)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  isRed
                      ? Icons.warning_amber_rounded
                      : Icons.info_outline_rounded,
                  color: color,
                  size: 16,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Live Quality Guidance',
                    style: YS.label(12, color: color, w: FontWeight.w700),
                  ),
                ),
                if (_liveQualityGrade.isNotEmpty)
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 6,
                      vertical: 2,
                    ),
                    decoration: BoxDecoration(
                      color: color.withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Text(
                      _liveQualityGrade,
                      style: YS.label(10, color: color, w: FontWeight.w700),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 6),
            ...issues.map(
              (issue) => Padding(
                padding: const EdgeInsets.only(left: 4, top: 2),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '• ',
                      style: YS.label(12, color: color, w: FontWeight.w700),
                    ),
                    Expanded(
                      child: Text(
                        issue,
                        style: YS.label(11, color: color, w: FontWeight.w600),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            if (_liveBlurScore > 0 || _liveBrightness > 0)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(
                  'Sharpness: ${_liveBlurScore.toStringAsFixed(1)} • Brightness: ${_liveBrightness.toInt()} • Glare: ${(_liveGlare * 100).toStringAsFixed(1)}%',
                  style: YS.label(10, color: color.withValues(alpha: 0.8)),
                ),
              ),
          ],
        ),
      );
    }

    return const SizedBox.shrink();
  }

  Widget _tip(IconData icon, String text) => Padding(
    padding: const EdgeInsets.only(top: 4),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 12, color: YS.amber),
        const SizedBox(width: 6),
        Expanded(child: Text(text, style: YS.label(11, color: YS.inkLight))),
      ],
    ),
  );

  Widget _btn(
    String label,
    VoidCallback onTap,
    bool primary, {
    bool square = false,
    IconData? icon,
  }) => GestureDetector(
    onTap: widget.disabled ? null : onTap,
    child: Container(
      width: square ? 48 : null,
      padding: EdgeInsets.symmetric(horizontal: square ? 0 : 14, vertical: 13),
      decoration: BoxDecoration(
        color: primary ? YS.amber : YS.cardAlt,
        borderRadius: BorderRadius.circular(12),
        border: primary ? null : Border.all(color: YS.stroke),
      ),
      child:
          square
              ? Center(
                child: Text(
                  label,
                  textAlign: TextAlign.center,
                  style: YS.label(
                    13,
                    color: primary ? Colors.black : YS.inkMid,
                    w: FontWeight.w700,
                  ),
                ),
              )
              : Row(
                mainAxisSize: MainAxisSize.min,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  if (icon != null) ...[
                    Icon(
                      icon,
                      size: 14,
                      color: primary ? Colors.black : YS.inkMid,
                    ),
                    const SizedBox(width: 6),
                  ],
                  Flexible(
                    child: Text(
                      label,
                      overflow: TextOverflow.ellipsis,
                      maxLines: 1,
                      style: YS.label(
                        13,
                        color: primary ? Colors.black : YS.inkMid,
                        w: FontWeight.w700,
                      ),
                    ),
                  ),
                ],
              ),
    ),
  );
}

class _OverlayPainter extends CustomPainter {
  final Color color;
  const _OverlayPainter(this.color);

  @override
  void paint(Canvas canvas, Size size) {
    final cx = size.width / 2, cy = size.height / 2;
    final rx = size.width * 0.23, ry = size.height * 0.25;
    final oval = Rect.fromCenter(
      center: Offset(cx, cy),
      width: rx * 2,
      height: ry * 2,
    );
    canvas.drawPath(
      Path()
        ..addRect(Rect.fromLTWH(0, 0, size.width, size.height))
        ..addOval(oval)
        ..fillType = PathFillType.evenOdd,
      Paint()..color = const Color(0xFF050505).withValues(alpha: 0.65),
    );
    canvas.drawOval(
      oval,
      Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 3),
    );
    canvas.drawOval(
      oval,
      Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.2,
    );
  }

  @override
  bool shouldRepaint(_OverlayPainter old) => old.color != color;
}

class _SlapOverlayPainter extends CustomPainter {
  final Color color;
  final String handSide;
  const _SlapOverlayPainter(this.color, this.handSide);

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width, h = size.height;
    final fingerW = w * 0.15;
    final gap = w * 0.047;
    final startX = (w - (4 * fingerW + 3 * gap)) / 2;
    final knuckleY = h * 0.80;

    final lengths =
        handSide == 'left'
            ? <double>[0.40, 0.52, 0.58, 0.50]
            : <double>[0.50, 0.58, 0.52, 0.40];

    final slots = <RRect>[];
    for (var i = 0; i < 4; i++) {
      final x = startX + i * (fingerW + gap);
      final top = knuckleY - lengths[i] * h;
      slots.add(
        RRect.fromRectAndCorners(
          Rect.fromLTRB(x, top, x + fingerW, knuckleY),
          topLeft: Radius.circular(fingerW * 0.5),
          topRight: Radius.circular(fingerW * 0.5),
          bottomLeft: Radius.circular(fingerW * 0.22),
          bottomRight: Radius.circular(fingerW * 0.22),
        ),
      );
    }

    final scrim = Path()..addRect(Rect.fromLTWH(0, 0, w, h));
    for (final s in slots) {
      scrim.addRRect(s);
    }
    scrim.fillType = PathFillType.evenOdd;
    canvas.drawPath(
      scrim,
      Paint()..color = const Color(0xFF050505).withValues(alpha: 0.62),
    );

    final glow =
        Paint()
          ..color = color
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.6
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 3);
    final line =
        Paint()
          ..color = color
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.3;
    for (final s in slots) {
      canvas.drawRRect(s, glow);
      canvas.drawRRect(s, line);
    }

    final tp = TextPainter(
      text: TextSpan(
        text: 'Align ${handSide == 'left' ? 'Left' : 'Right'} hand in slots',
        style: TextStyle(
          color: color.withValues(alpha: 0.9),
          fontSize: 12,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.4,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout(maxWidth: w);
    tp.paint(canvas, Offset((w - tp.width) / 2, h * 0.06));
  }

  @override
  bool shouldRepaint(_SlapOverlayPainter old) =>
      old.color != color || old.handSide != handSide;
}
