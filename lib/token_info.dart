import 'dart:convert';

/// Reads the public part of a LiveKit token (no secret is needed for this)
/// and explains it in plain words, so a bad token is easy to spot.
class TokenInfo {
  const TokenInfo(this.lines, this.looksOk);

  final List<String> lines;
  final bool looksOk;
}

TokenInfo describeToken(String raw) {
  final token = raw.replaceAll(RegExp(r'\s+'), '');
  if (token.isEmpty) return const TokenInfo([], false);

  final parts = token.split('.');
  if (parts.length != 3) {
    return const TokenInfo(
      [
        'This does not look like a full token. A token has three parts '
            'separated by dots.',
      ],
      false,
    );
  }

  try {
    final payload = jsonDecode(
      utf8.decode(base64Url.decode(base64.normalize(parts[1]))),
    ) as Map<String, dynamic>;

    final lines = <String>[];
    var ok = true;

    final video = payload['video'];
    final room = video is Map ? video['room'] : null;
    final identity = payload['sub'];
    lines.add('Room: ${room ?? 'missing'}');
    lines.add('Identity: ${identity ?? 'missing'}');
    lines.add('API key: ${payload['iss'] ?? 'missing'}');
    if (room == null || identity == null) ok = false;

    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final exp = payload['exp'];
    final nbf = payload['nbf'];

    if (exp is num) {
      final left = exp.toInt() - now;
      if (left <= 0) {
        lines.add(
          'Expired ${(-left / 3600).toStringAsFixed(1)} hours ago by this '
          "phone's clock. Make a new token.",
        );
        ok = false;
      } else {
        lines.add(
          'Valid for about ${(left / 3600).toStringAsFixed(1)} more hours.',
        );
      }
    } else {
      lines.add('No expiry time found in this token.');
    }

    if (nbf is num && nbf.toInt() - now > 60) {
      final minutes = ((nbf.toInt() - now) / 60).round();
      lines.add(
        "Not valid yet: this phone's clock is $minutes minutes behind the "
        'computer that made the token. Set date and time to automatic on '
        'both, then make a new token.',
      );
      ok = false;
    }

    return TokenInfo(lines, ok);
  } catch (_) {
    return const TokenInfo(
      [
        'Could not read this token. It may be cut off or have extra '
            'characters. Copy it again, in one piece.',
      ],
      false,
    );
  }
}
