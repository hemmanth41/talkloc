import 'package:flutter/material.dart';

class AppColors {
  static const orange = Color(0xFFC93A08);
  static const orangeDark = Color(0xFFA52F06);
  static const green = Color(0xFF0B6B5D);
  static const greenSoft = Color(0xFFDDEFEA);
  static const cream = Color(0xFFFBFAF7);
  static const ink = Color(0xFF14201F);
  static const muted = Color(0xFF4B5B59);
  static const sand = Color(0xFFF0EDE5);
  static const amberSoft = Color(0xFFFFF4DD);
  static const amberInk = Color(0xFF4A2F00);
}

ThemeData buildTheme() {
  return ThemeData(
    useMaterial3: true,
    colorScheme: ColorScheme.fromSeed(
      seedColor: AppColors.green,
      primary: AppColors.green,
    ),
    scaffoldBackgroundColor: AppColors.cream,
  );
}
