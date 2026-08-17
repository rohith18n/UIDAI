import 'dart:async';
import 'dart:developer' as dev;
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';
import 'theme/app_theme.dart';
import 'router.dart';
import 'screens/splash_screen.dart';
import 'services/api_service.dart';
import 'services/ondevice_ml_service.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Log all Flutter framework errors
  FlutterError.onError = (FlutterErrorDetails details) {
    FlutterError.presentError(details);
    dev.log(
      '🔥 [FLUTTER_ERROR] ${details.exceptionAsString()}',
      name: 'APP.ERROR',
      error: details.exception,
      stackTrace: details.stack,
    );
    debugPrint(
      '🔥 [FLUTTER_ERROR] ${details.exceptionAsString()}\n${details.stack}',
    );
  };

  // Log all unhandled async errors
  PlatformDispatcher.instance.onError = (error, stack) {
    dev.log(
      '🔥 [ASYNC_ERROR] $error',
      name: 'APP.ASYNC_ERROR',
      error: error,
      stackTrace: stack,
    );
    debugPrint('🔥 [ASYNC_ERROR] $error\n$stack');
    return true;
  };

  // Load persisted server URL before anything tries to call the API.
  await ApiService.init();
  // Warm up on-device ML interpreters in background
  unawaited(OnDeviceMLService.initialize());
  await SystemChrome.setPreferredOrientations([
    DeviceOrientation.portraitUp,
    DeviceOrientation.portraitDown,
  ]);
  SystemChrome.setSystemUIOverlayStyle(
    const SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: Brightness.dark,
    ),
  );
  runApp(const YellowSenseApp());
}

class YellowSenseApp extends StatefulWidget {
  const YellowSenseApp({super.key});
  @override
  State<YellowSenseApp> createState() => _YellowSenseAppState();
}

class _YellowSenseAppState extends State<YellowSenseApp> {
  bool _showSplash = true;

  @override
  Widget build(BuildContext context) {
    if (_showSplash) {
      return MaterialApp(
        title: 'YellowSense UIDAI',
        debugShowCheckedModeBanner: false,
        theme: YS.theme,
        home: SplashScreen(onDone: () => setState(() => _showSplash = false)),
      );
    }
    return MaterialApp.router(
      title: 'YellowSense UIDAI',
      debugShowCheckedModeBanner: false,
      theme: YS.theme,
      routerConfig: appRouter,
    );
  }
}
