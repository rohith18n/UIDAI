import 'package:flutter/material.dart';
import '../theme/app_theme.dart';

class SplashScreen extends StatefulWidget {
  final VoidCallback onDone;
  const SplashScreen({super.key, required this.onDone});
  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen>
    with SingleTickerProviderStateMixin {
  late AnimationController _ctrl;
  late Animation<double> _logoScale;
  late Animation<double> _logoFade;
  late Animation<double> _textFade;
  late Animation<double> _barWidth;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(vsync: this, duration: const Duration(milliseconds: 1800));

    _logoScale = Tween<double>(begin: 0.6, end: 1.0).animate(
        CurvedAnimation(parent: _ctrl, curve: const Interval(0.0, 0.5, curve: Curves.easeOutBack)));
    _logoFade  = Tween<double>(begin: 0.0, end: 1.0).animate(
        CurvedAnimation(parent: _ctrl, curve: const Interval(0.0, 0.4, curve: Curves.easeOut)));
    _textFade  = Tween<double>(begin: 0.0, end: 1.0).animate(
        CurvedAnimation(parent: _ctrl, curve: const Interval(0.4, 0.8, curve: Curves.easeOut)));
    _barWidth  = Tween<double>(begin: 0.0, end: 1.0).animate(
        CurvedAnimation(parent: _ctrl, curve: const Interval(0.6, 1.0, curve: Curves.easeInOut)));

    _ctrl.forward();
    Future.delayed(const Duration(milliseconds: 2800), widget.onDone);
  }

  @override
  void dispose() { _ctrl.dispose(); super.dispose(); }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [Color(0xFFFFFBF0), Color(0xFFFFF3D0), Color(0xFFFAFAFA)],
            stops: [0.0, 0.5, 1.0],
          ),
        ),
        child: SafeArea(
          child: AnimatedBuilder(
            animation: _ctrl,
            builder: (_, s) => Column(
              children: [
                const Spacer(flex: 3),
                // Logo
                Opacity(
                  opacity: _logoFade.value,
                  child: Transform.scale(
                    scale: _logoScale.value,
                    child: Container(
                      width: 110, height: 110,
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(30),
                        color: YS.card,
                        boxShadow: YS.amberShadow,
                      ),
                      padding: const EdgeInsets.all(16),
                      child: Image.asset('assets/images/logo11.png', fit: BoxFit.contain),
                    ),
                  ),
                ),
                const SizedBox(height: 32),
                // Text block
                Opacity(
                  opacity: _textFade.value,
                  child: Column(children: [
                    Text('YellowSense', style: YS.display(32,
                        color: YS.amberDeep, w: FontWeight.w800)),
                    const SizedBox(height: 4),
                    Text('UIDAI Fingerprint SDK',
                        style: YS.label(15, color: YS.inkMid, w: FontWeight.w500)),
                    const SizedBox(height: 6),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                      decoration: BoxDecoration(
                        color: YS.amberSoft,
                        borderRadius: BorderRadius.circular(20),
                        border: Border.all(color: YS.amber.withValues(alpha: 0.3)),
                      ),
                      child: Text('SITAA Cohort 1 · 2025',
                          style: YS.label(11, color: YS.amberDeep, w: FontWeight.w600)),
                    ),
                  ]),
                ),
                const Spacer(flex: 3),
                // Progress bar
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 60),
                  child: Column(children: [
                    Opacity(
                      opacity: _textFade.value,
                      child: Text('Initializing models...',
                          style: YS.label(12, color: YS.inkLight)),
                    ),
                    const SizedBox(height: 10),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(4),
                      child: Container(
                        height: 3, color: YS.stroke,
                        child: Align(
                          alignment: Alignment.centerLeft,
                          child: FractionallySizedBox(
                            widthFactor: _barWidth.value,
                            child: Container(
                              decoration: BoxDecoration(
                                gradient: const LinearGradient(
                                  colors: [YS.amber, YS.amberDeep]),
                                borderRadius: BorderRadius.circular(4),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ]),
                ),
                const SizedBox(height: 32),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
