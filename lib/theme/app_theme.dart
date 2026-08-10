import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';

class YS {
  // ── Brand ──────────────────────────────────────────────────────────────────
  static const Color amber     = Color(0xFFE0A020);
  static const Color amberDeep = Color(0xFFB87800);
  static const Color amberSoft = Color(0xFFFFF3D6);
  static const Color amberGlow = Color(0x28E0A020);

  // ── Surfaces ───────────────────────────────────────────────────────────────
  static const Color bg        = Color(0xFFFAFAFA);
  static const Color card      = Color(0xFFFFFFFF);
  static const Color cardAlt   = Color(0xFFF5F5F5);
  static const Color stroke    = Color(0xFFEEEEEE);
  static const Color strokeMd  = Color(0xFFE0E0E0);

  // ── Text ───────────────────────────────────────────────────────────────────
  static const Color ink       = Color(0xFF111111);
  static const Color inkMid    = Color(0xFF555555);
  static const Color inkLight  = Color(0xFF999999);
  static const Color inkFaint  = Color(0xFFCCCCCC);

  // ── Semantic ───────────────────────────────────────────────────────────────
  static const Color green     = Color(0xFF1B7A3E);
  static const Color greenBg   = Color(0xFFEAF7EF);
  static const Color red       = Color(0xFFB71C1C);
  static const Color redBg     = Color(0xFFFFF0F0);
  static const Color blue      = Color(0xFF1A4FA0);
  static const Color blueBg    = Color(0xFFEEF4FF);
  static const Color orange    = Color(0xFFBF4800);
  static const Color orangeBg  = Color(0xFFFFF4EE);

  // ── Typography ─────────────────────────────────────────────────────────────
  static TextStyle display(double size, {Color? color, FontWeight w = FontWeight.w700}) =>
      GoogleFonts.playfairDisplay(fontSize: size, fontWeight: w,
          color: color ?? ink, height: 1.15, letterSpacing: -0.3);

  static TextStyle label(double size, {Color? color, FontWeight w = FontWeight.w500}) =>
      GoogleFonts.dmSans(fontSize: size, fontWeight: w,
          color: color ?? ink, height: 1.4);

  static TextStyle mono(double size, {Color? color}) =>
      GoogleFonts.jetBrainsMono(fontSize: size, color: color ?? inkMid,
          fontWeight: FontWeight.w500);

  // ── Shadows ────────────────────────────────────────────────────────────────
  static List<BoxShadow> get cardShadow => [
    BoxShadow(color: Colors.black.withValues(alpha: 0.05), blurRadius: 12, offset: const Offset(0, 4)),
    BoxShadow(color: Colors.black.withValues(alpha: 0.03), blurRadius: 4,  offset: const Offset(0, 1)),
  ];

  static List<BoxShadow> get amberShadow => [
    BoxShadow(color: amber.withValues(alpha: 0.4), blurRadius: 20, offset: const Offset(0, 6)),
    BoxShadow(color: amber.withValues(alpha: 0.15), blurRadius: 40, offset: const Offset(0, 12)),
  ];

  // ── Theme ──────────────────────────────────────────────────────────────────
  static ThemeData get theme => ThemeData(
    useMaterial3: true,
    brightness: Brightness.light,
    scaffoldBackgroundColor: bg,
    colorScheme: const ColorScheme.light(
      primary: amber, onPrimary: Colors.black,
      surface: card, error: red,
    ),
    textTheme: GoogleFonts.dmSansTextTheme(ThemeData.light().textTheme)
        .apply(bodyColor: ink, displayColor: ink),
    appBarTheme: AppBarTheme(
      backgroundColor: card, elevation: 0,
      surfaceTintColor: Colors.transparent,
      systemOverlayStyle: SystemUiOverlayStyle.dark,
      titleTextStyle: GoogleFonts.dmSans(
          color: ink, fontSize: 17, fontWeight: FontWeight.w700),
      iconTheme: const IconThemeData(color: ink),
      actionsIconTheme: const IconThemeData(color: inkMid),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true, fillColor: cardAlt,
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: stroke)),
      enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: stroke)),
      focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: amber, width: 1.5)),
      labelStyle: GoogleFonts.dmSans(color: inkMid, fontSize: 14),
      hintStyle: GoogleFonts.dmSans(color: inkFaint, fontSize: 14),
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
    ),
    elevatedButtonTheme: ElevatedButtonThemeData(
      style: ElevatedButton.styleFrom(
        backgroundColor: amber, foregroundColor: Colors.black,
        elevation: 0, shadowColor: Colors.transparent,
        padding: const EdgeInsets.symmetric(vertical: 15),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        textStyle: GoogleFonts.dmSans(fontSize: 15, fontWeight: FontWeight.w700),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: ink,
        side: const BorderSide(color: strokeMd),
        padding: const EdgeInsets.symmetric(vertical: 15),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        textStyle: GoogleFonts.dmSans(fontSize: 15, fontWeight: FontWeight.w600),
      ),
    ),
    dividerTheme: const DividerThemeData(color: stroke, thickness: 1),
  );
}
