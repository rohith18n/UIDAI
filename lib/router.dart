import 'package:go_router/go_router.dart';
import 'models/capture_mode.dart';
import 'screens/home_screen.dart';
import 'screens/enroll_screen.dart';
import 'screens/authenticate_screen.dart';
import 'screens/pipeline_screen.dart';
import 'screens/slap_pipeline_screen.dart';
import 'screens/screens.dart';

CaptureMode _modeExtra(GoRouterState state, {CaptureMode d = CaptureMode.single}) {
  final x = state.extra;
  if (x is CaptureMode) return x;
  return d;
}

final appRouter = GoRouter(
  initialLocation: '/',
  routes: [
    GoRoute(path: '/',             builder: (context, state) => const HomeScreen()),
    GoRoute(path: '/enroll',       builder: (context, state) =>
                                     EnrollScreen(mode: _modeExtra(state))),
    GoRoute(path: '/authenticate', builder: (context, state) =>
                                     AuthenticateScreen(mode: _modeExtra(state))),
    GoRoute(path: '/verify',       builder: (context, state) =>
                                     VerifyScreen(mode: _modeExtra(state))),
    GoRoute(path: '/pipeline',     builder: (context, state) => const PipelineScreen()),
    GoRoute(path: '/slap_pipeline',builder: (context, state) => const SlapPipelineScreen()),
    GoRoute(path: '/history',      builder: (context, state) => const HistoryScreen()),
    GoRoute(path: '/settings',     builder: (context, state) => const SettingsScreen()),
    GoRoute(path: '/qc',           builder: (context, state) =>
                                     QcScreen(mode: _modeExtra(state))),
  ],
);

