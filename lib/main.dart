import 'package:flutter/material.dart';

import 'setup_screen.dart';
import 'theme.dart';

void main() {
  runApp(const TalkLocApp());
}

class TalkLocApp extends StatelessWidget {
  const TalkLocApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'TalkLoc',
      debugShowCheckedModeBanner: false,
      theme: buildTheme(),
      home: const SetupScreen(),
    );
  }
}
