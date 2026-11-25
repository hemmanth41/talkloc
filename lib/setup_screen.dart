import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'talk_screen.dart';
import 'theme.dart';

/// First screen of the prototype. You paste the server address and the
/// token made for THIS phone (see README). They are saved on the phone.
class SetupScreen extends StatefulWidget {
  const SetupScreen({super.key});

  @override
  State<SetupScreen> createState() => _SetupScreenState();
}

class _SetupScreenState extends State<SetupScreen> {
  final TextEditingController _url = TextEditingController();
  final TextEditingController _token = TextEditingController();
  String? _problem;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _url.dispose();
    _token.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    _url.text = prefs.getString('url') ?? '';
    _token.text = prefs.getString('token') ?? '';
    if (mounted) setState(() {});
  }

  Future<void> _go() async {
    final url = _url.text.trim();
    final token = _token.text.trim();
    if (!(url.startsWith('wss://') || url.startsWith('ws://'))) {
      setState(() => _problem = 'The server address should start with wss://');
      return;
    }
    if (token.length < 40) {
      setState(() => _problem = 'Paste the full token made for this phone.');
      return;
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('url', url);
    await prefs.setString('token', token);
    if (!mounted) return;
    setState(() => _problem = null);
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => TalkScreen(url: url, token: token)),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(24, 32, 24, 24),
          children: [
            Row(
              children: [
                Container(
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(
                    color: AppColors.orange,
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: const Icon(Icons.mic, color: Colors.white),
                ),
                const SizedBox(width: 10),
                const Text(
                  'TalkLoc',
                  style: TextStyle(
                    fontSize: 22,
                    fontWeight: FontWeight.w700,
                    color: AppColors.ink,
                  ),
                ),
                const SizedBox(width: 8),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: AppColors.sand,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: const Text(
                    'test build',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: AppColors.muted,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 28),
            const Text(
              'Talk to your person.\nSee where they are.',
              style: TextStyle(
                fontSize: 30,
                height: 1.15,
                fontWeight: FontWeight.w700,
                color: AppColors.ink,
              ),
            ),
            const SizedBox(height: 10),
            const Text(
              'Paste the server address and the token made for this phone. '
              'Both phones must use tokens for the same room.',
              style: TextStyle(fontSize: 15, height: 1.4, color: AppColors.muted),
            ),
            const SizedBox(height: 24),
            TextField(
              controller: _url,
              keyboardType: TextInputType.url,
              autocorrect: false,
              decoration: InputDecoration(
                labelText: 'Server address (wss://...)',
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(14),
                ),
              ),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _token,
              minLines: 3,
              maxLines: 5,
              autocorrect: false,
              enableSuggestions: false,
              decoration: InputDecoration(
                labelText: 'Token for this phone',
                alignLabelWithHint: true,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(14),
                ),
              ),
            ),
            if (_problem != null) ...[
              const SizedBox(height: 12),
              Text(
                _problem!,
                style: const TextStyle(
                  color: AppColors.orangeDark,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
            const SizedBox(height: 20),
            SizedBox(
              height: 56,
              child: FilledButton(
                style: FilledButton.styleFrom(
                  backgroundColor: AppColors.orange,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16),
                  ),
                ),
                onPressed: _go,
                child: const Text(
                  'Connect',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                ),
              ),
            ),
            const SizedBox(height: 16),
            const Text(
              'Your location is shared only with the other phone in this room, '
              'and only while this app is connected.',
              style: TextStyle(fontSize: 12, height: 1.5, color: AppColors.muted),
            ),
          ],
        ),
      ),
    );
  }
}
