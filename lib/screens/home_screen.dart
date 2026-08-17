import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../theme/app_theme.dart';
import '../models/capture_mode.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with SingleTickerProviderStateMixin {
  late TabController _tabCtrl;
  CaptureMode _mode = CaptureMode.single;
  static const String _modePrefKey = 'capture_mode_v1';

  @override
  void initState() {
    super.initState();
    _tabCtrl = TabController(length: 2, vsync: this);
    _loadSavedMode();
  }

  @override
  void dispose() {
    _tabCtrl.dispose();
    super.dispose();
  }

  Future<void> _loadSavedMode() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final saved = prefs.getString(_modePrefKey);
      if (saved == 'slap') {
        if (mounted) {
          setState(() {
            _mode = CaptureMode.slap;
            _tabCtrl.index = 1;
          });
        }
      }
    } catch (_) {}
  }

  Future<void> _setMode(CaptureMode m) async {
    setState(() => _mode = m);
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_modePrefKey, m == CaptureMode.slap ? 'slap' : 'single');
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: YS.bg,
      body: SafeArea(
        child: Column(children: [
          // ── Top bar ───────────────────────────────────────────────────
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 12),
            child: Row(children: [
              Image.asset('assets/images/logo11.png', height: 28, fit: BoxFit.contain),
              const Spacer(),
              GestureDetector(
                onTap: () => context.go('/settings'),
                child: Container(
                  width: 38, height: 38,
                  decoration: BoxDecoration(
                    color: YS.card, borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: YS.stroke),
                    boxShadow: YS.cardShadow,
                  ),
                  child: const Icon(Icons.settings_outlined, size: 18, color: YS.inkMid),
                ),
              ),
            ]),
          ),

          // ── Mode toggle tabs ──────────────────────────────────────────
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: Container(
              decoration: BoxDecoration(
                color: YS.card,
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: YS.stroke),
                boxShadow: YS.cardShadow,
              ),
              child: TabBar(
                controller: _tabCtrl,
                onTap: (i) => _setMode(i == 0 ? CaptureMode.single : CaptureMode.slap),
                padding: const EdgeInsets.all(6),
                indicator: BoxDecoration(
                  color: YS.amber,
                  borderRadius: BorderRadius.circular(10),
                  boxShadow: [BoxShadow(color: YS.amber.withValues(alpha: 0.3), blurRadius: 8)],
                ),
                indicatorSize: TabBarIndicatorSize.tab,
                dividerColor: Colors.transparent,
                labelColor: Colors.black,
                unselectedLabelColor: YS.inkLight,
                labelStyle: YS.label(13, w: FontWeight.w700),
                unselectedLabelStyle: YS.label(13, w: FontWeight.w600),
                tabs: const [
                  Tab(child: Row(mainAxisSize: MainAxisSize.min, children: [
                    Icon(Icons.fingerprint_rounded, size: 16),
                    SizedBox(width: 6),
                    Text('Thumb'),
                  ])),
                  Tab(child: Row(mainAxisSize: MainAxisSize.min, children: [
                    Icon(Icons.back_hand_rounded, size: 16),
                    SizedBox(width: 6),
                    Text('4-Finger Slap'),
                  ])),
                ],
              ),
            ),
          ),

          Expanded(child: ListView(
            padding: EdgeInsets.zero,
            children: [
              const SizedBox(height: 16),
              // ── Hero banner ─────────────────────────────────────────
              _HeroBanner(mode: _mode),
              // ── Stats row ──────────────────────────────────────────
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
                child: Row(children: [
                  _statCard(_mode == CaptureMode.slap ? '4×' : 'Thumb',
                      _mode == CaptureMode.slap ? 'Fingers' : 'Biometric',
                      _mode == CaptureMode.slap ? Icons.pan_tool_rounded : Icons.fingerprint_rounded),
                  const SizedBox(width: 10),
                  _statCard('1:N', 'Auth', Icons.groups_rounded),
                  const SizedBox(width: 10),
                  _statCard('1:1', 'Verify', Icons.person_search_rounded),
                ]),
              ),
              // ── Section label ──────────────────────────────────────
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 28, 20, 12),
                child: Text('ACTIONS',
                    style: YS.label(11, color: YS.inkLight, w: FontWeight.w700)
                        .copyWith(letterSpacing: 1.8)),
              ),
              // ── Action cards ───────────────────────────────────────
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: Column(children: [
                  Row(children: [
                    Expanded(child: _BigCard(
                      icon: Icons.fingerprint_rounded,
                      label: 'Enroll',
                      sub: _mode == CaptureMode.slap ? 'Register 4 fingers' : 'Register thumb',
                      color: YS.amber,
                      bg: YS.amberSoft,
                      onTap: () => context.go('/enroll', extra: _mode),
                    )),
                    const SizedBox(width: 12),
                    Expanded(child: _BigCard(
                      icon: Icons.how_to_reg_rounded,
                      label: 'Authenticate',
                      sub: _mode == CaptureMode.slap ? 'Slap 4-finger 1:N' : 'Thumb 1:N match',
                      color: YS.green,
                      bg: YS.greenBg,
                      onTap: () => context.go('/authenticate', extra: _mode),
                    )),
                  ]),
                  const SizedBox(height: 12),
                  Row(children: [
                    Expanded(child: _BigCard(
                      icon: Icons.verified_rounded,
                      label: 'Verify',
                      sub: _mode == CaptureMode.slap ? 'Slap 4-finger 1:1' : 'Thumb 1:1 identity',
                      color: YS.blue,
                      bg: YS.blueBg,
                      onTap: () => context.go('/verify', extra: _mode),
                    )),
                    const SizedBox(width: 12),
                    Expanded(child: _BigCard(
                      icon: Icons.biotech_rounded,
                      label: 'Pipeline',
                      sub: _mode == CaptureMode.slap ? '4-Finger visualizer' : 'Thumb visualizer',
                      color: YS.orange,
                      bg: YS.orangeBg,
                      onTap: () => context.go(
                          _mode == CaptureMode.slap ? '/slap_pipeline' : '/pipeline',
                          extra: _mode),
                    )),
                  ]),
                  const SizedBox(height: 12),
                  _WideCard(
                    icon: Icons.science_rounded,
                    label: 'QC Pipeline',
                    sub: 'Quality check & readiness scoring',
                    color: YS.orange,
                    onTap: () => context.go('/qc', extra: _mode),
                  ),
                  const SizedBox(height: 12),
                  _WideCard(
                    icon: Icons.history_rounded,
                    label: 'Auth History',
                    sub: 'Single + Slap authentication records',
                    color: YS.inkMid,
                    onTap: () => context.go('/history'),
                  ),
                ]),
              ),
              // ── Footer ─────────────────────────────────────────────
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 28, 20, 24),
                child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                  Text('Powered by ', style: YS.label(11, color: YS.inkLight)),
                  Text('YellowSense Technologies',
                      style: YS.label(11, color: YS.amberDeep, w: FontWeight.w700)),
                  Text(' · v2.0', style: YS.label(11, color: YS.inkLight)),
                ]),
              ),
            ],
          )),
        ]),
      ),
    );
  }

  Widget _statCard(String val, String label, IconData icon) => Expanded(
    child: Container(
      padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 12),
      decoration: BoxDecoration(
        color: YS.card, borderRadius: BorderRadius.circular(14),
        border: Border.all(color: YS.stroke),
        boxShadow: YS.cardShadow,
      ),
      child: Column(children: [
        Icon(icon, size: 18, color: YS.amber),
        const SizedBox(height: 6),
        Text(val, style: YS.display(18, color: YS.ink)),
        const SizedBox(height: 2),
        Text(label, style: YS.label(10, color: YS.inkLight)),
      ]),
    ),
  );
}

class _HeroBanner extends StatelessWidget {
  final CaptureMode mode;
  const _HeroBanner({required this.mode});

  @override
  Widget build(BuildContext context) {
    final isSlap = mode == CaptureMode.slap;
    return Container(
      margin: const EdgeInsets.fromLTRB(20, 4, 20, 0),
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft, end: Alignment.bottomRight,
          colors: isSlap
              ? const [Color(0xFF2E7DD6), Color(0xFF145299)]
              : const [Color(0xFFE0A020), Color(0xFFB87800)],
        ),
        borderRadius: BorderRadius.circular(24),
        boxShadow: isSlap
            ? [BoxShadow(color: const Color(0xFF145299).withValues(alpha: 0.3), blurRadius: 20, offset: const Offset(0, 6))]
            : YS.amberShadow,
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.2),
            borderRadius: BorderRadius.circular(20),
          ),
          child: Text('UIDAI · SITAA Cohort 1',
              style: YS.label(11, color: Colors.white, w: FontWeight.w600)),
        ),
        const SizedBox(height: 14),
        Text(isSlap ? 'Multi-Finger\n4-Finger Slap Auth' : 'Contactless\nThumb Biometric Auth',
            style: YS.display(28, color: Colors.white, w: FontWeight.w800)),
        const SizedBox(height: 8),
        Text(isSlap
                ? 'Capture all 4 fingers at once (Index, Middle, Ring, Little) — faster & stronger matching'
                : 'AI-powered contactless thumb authentication for Aadhaar — no scanner needed',
            style: YS.label(13, color: Colors.white.withValues(alpha: 0.85))),
        const SizedBox(height: 20),
        Wrap(spacing: 8, runSpacing: 8, children: [
          _chip('YOLO'), _chip('U²Net'), _chip('ZeroDCE'),
          _chip('MinutiaeNet'), _chip(isSlap ? '4-Finger Slap' : 'Thumb MCC'),
        ]),
      ]),
    );
  }

  Widget _chip(String label) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
    decoration: BoxDecoration(
      color: Colors.white.withValues(alpha: 0.2),
      borderRadius: BorderRadius.circular(20),
      border: Border.all(color: Colors.white.withValues(alpha: 0.3)),
    ),
    child: Text(label, style: YS.label(10, color: Colors.white, w: FontWeight.w600)),
  );
}

class _BigCard extends StatelessWidget {
  final IconData icon;
  final String label, sub;
  final Color color, bg;
  final VoidCallback onTap;
  const _BigCard({required this.icon, required this.label, required this.sub,
      required this.color, required this.bg, required this.onTap});

  @override
  Widget build(BuildContext context) => GestureDetector(
    onTap: onTap,
    child: Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: YS.card, borderRadius: BorderRadius.circular(18),
        border: Border.all(color: YS.stroke),
        boxShadow: YS.cardShadow,
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Container(
          width: 44, height: 44,
          decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(12)),
          child: Icon(icon, color: color, size: 22),
        ),
        const SizedBox(height: 14),
        Text(label, style: YS.label(15, color: YS.ink, w: FontWeight.w700)),
        const SizedBox(height: 2),
        Text(sub, style: YS.label(12, color: YS.inkLight)),
      ]),
    ),
  );
}

class _WideCard extends StatelessWidget {
  final IconData icon;
  final String label, sub;
  final Color color;
  final VoidCallback onTap;
  const _WideCard({required this.icon, required this.label, required this.sub,
      required this.color, required this.onTap});

  @override
  Widget build(BuildContext context) => GestureDetector(
    onTap: onTap,
    child: Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: YS.card, borderRadius: BorderRadius.circular(18),
        border: Border.all(color: YS.stroke),
        boxShadow: YS.cardShadow,
      ),
      child: Row(children: [
        Container(
          width: 44, height: 44,
          decoration: BoxDecoration(color: YS.cardAlt, borderRadius: BorderRadius.circular(12)),
          child: Icon(icon, color: color, size: 22),
        ),
        const SizedBox(width: 14),
        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(label, style: YS.label(15, color: YS.ink, w: FontWeight.w700)),
          Text(sub, style: YS.label(12, color: YS.inkLight)),
        ])),
        const Icon(Icons.chevron_right_rounded, color: YS.inkFaint, size: 20),
      ]),
    ),
  );
}
