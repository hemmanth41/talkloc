import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart' hide ConnectionState;
import 'package:flutter/services.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';
import 'package:livekit_client/livekit_client.dart';
import 'package:permission_handler/permission_handler.dart';

import 'theme.dart';

/// One shared position (mine or my partner's).
class Fix {
  Fix(this.lat, this.lng, this.accuracy, this.at);

  final double lat;
  final double lng;
  final double accuracy;
  final DateTime at;

  LatLng get point => LatLng(lat, lng);
}

/// The main screen: map + hold-to-talk + live distance, all in one place.
class TalkScreen extends StatefulWidget {
  const TalkScreen({super.key, required this.url, required this.token});

  final String url;
  final String token;

  @override
  State<TalkScreen> createState() => _TalkScreenState();
}

class _TalkScreenState extends State<TalkScreen> with WidgetsBindingObserver {
  late Room _room;
  EventsListener<RoomEvent>? _events;
  StreamSubscription<Position>? _posSub;
  Timer? _beat;
  Timer? _tick;
  Timer? _watchdog;
  final MapController _map = MapController();

  Fix? _me;
  final Map<String, Fix> _others = <String, Fix>{};
  String _status = 'Starting...';
  String? _connError;
  String? _locError;
  bool _talking = false;
  bool _mapReady = false;
  bool _fitDone = false;
  bool _sharingLocation = false;
  bool _leaving = false;
  bool _connecting = false;
  bool _connectedOnce = false;
  bool _giveUp = false;

  int _fixCount = 0;
  int _sentCount = 0;
  int _sendFails = 0;
  int _reconnects = 0;
  int _streamRestarts = 0;
  DateTime? _lastFixAt;
  DateTime? _lastSentAt;
  AppLifecycleState _life = AppLifecycleState.resumed;
  final List<String> _log = <String>[];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _wireRoom();
    _tick = Timer.periodic(const Duration(seconds: 1), (_) => _refresh());
    _watchdog = Timer.periodic(const Duration(seconds: 10), (_) => _watch());
    WidgetsBinding.instance.addPostFrameCallback((_) => _start());
  }

  @override
  void dispose() {
    _leaving = true;
    WidgetsBinding.instance.removeObserver(this);
    _tick?.cancel();
    _beat?.cancel();
    _watchdog?.cancel();
    _posSub?.cancel();
    _events?.dispose();
    _room.removeListener(_refresh);
    _disposeRoom(_room);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _life = state;
    _note('App is ${state.name}');
    if (state == AppLifecycleState.resumed) {
      _sendFix();
      _watch();
    }
  }

  void _refresh() {
    if (mounted) setState(() {});
  }

  String _two(int n) => n.toString().padLeft(2, '0');

  void _note(String message) {
    final t = DateTime.now();
    _log.add('${_two(t.hour)}:${_two(t.minute)}:${_two(t.second)}  $message');
    if (_log.length > 120) _log.removeAt(0);
  }

  Future<void> _disposeRoom(Room room) async {
    try {
      await room.disconnect();
    } catch (_) {}
    try {
      await room.dispose();
    } catch (_) {}
  }

  // ---------------------------------------------------------------- start

  Future<void> _start() async {
    _note('Started');
    final agreed = await _showDisclosure();
    var locationOk = false;
    if (agreed) {
      locationOk = await _askPermissions();
      await _askBackgroundRun();
    } else {
      await Permission.microphone.request();
    }
    await _connect();
    if (locationOk) {
      await _startLocation();
    } else {
      _status = 'Connected. Location sharing is off.';
      _refresh();
    }
  }

  /// Plain-words disclosure shown BEFORE the phone's own permission prompt.
  Future<bool> _showDisclosure() async {
    if (!mounted) return false;
    final result = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: const Text('Use your location to find your person'),
        content: const Text(
          'TalkLoc collects your location even when the app is closed or '
          'not in use, so the person in this room can see where you are '
          'while you talk.\n\n'
          'Only people in this room see it. Sharing stops when you leave. '
          'It is not used for ads.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Not now'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: AppColors.orange),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Continue'),
          ),
        ],
      ),
    );
    return result ?? false;
  }

  Future<bool> _askPermissions() async {
    final loc = await Permission.location.request();
    if (loc.isGranted) {
      // On Android 11+ this opens the phone's settings page:
      // choose "Allow all the time".
      await Permission.locationAlways.request();
    }
    await Permission.microphone.request();
    await Permission.notification.request();
    return loc.isGranted;
  }

  /// Asks the phone to let the app keep running when the screen is off.
  Future<void> _askBackgroundRun() async {
    if (!mounted) return;
    try {
      if (await Permission.ignoreBatteryOptimizations.isGranted) return;
    } catch (_) {
      return;
    }
    if (!mounted) return;
    final go = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: const Text('Keep sharing when your screen is off'),
        content: const Text(
          'Next, your phone will ask if TalkLoc may run in the background. '
          'Choose Allow. Without it, many phones stop sharing your location '
          'a few minutes after the screen turns off.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Skip'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: AppColors.orange),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Continue'),
          ),
        ],
      ),
    );
    if (go == true) {
      try {
        await Permission.ignoreBatteryOptimizations.request();
      } catch (_) {}
    }
  }

  // ----------------------------------------------------------- voice + data

  void _wireRoom() {
    _room = Room(
      roomOptions: RoomOptions(adaptiveStream: true, dynacast: true),
    );
    _room.addListener(_refresh);
    final events = _room.createListener();
    _events = events;
    events
      ..on<DataReceivedEvent>(_onData)
      ..on<ParticipantConnectedEvent>((e) {
        _note('${e.participant.identity} joined');
        _sendFix();
        _refresh();
      })
      ..on<ParticipantDisconnectedEvent>((e) {
        _others.remove(e.participant.identity);
        _note('${e.participant.identity} left');
        _refresh();
      })
      ..on<RoomReconnectingEvent>((e) {
        _note('Connection weak, reconnecting');
        _refresh();
      })
      ..on<RoomReconnectedEvent>((e) {
        _note('Reconnected');
        _sendFix();
        _refresh();
      })
      ..on<RoomDisconnectedEvent>((e) {
        _note('Disconnected from the server');
        _status = 'Disconnected';
        _refresh();
      })
      ..on<ActiveSpeakersChangedEvent>((e) => _refresh());
  }

  Future<void> _connect() async {
    if (_connecting || _leaving) return;
    _connecting = true;
    try {
      await _room.connect(widget.url, widget.token);
      try {
        await Hardware.instance.setSpeakerphoneOn(true);
      } catch (_) {}
      _status = 'Connected';
      _connError = null;
      _connectedOnce = true;
      _note('Connected to the room');
      _sendFix();
    } catch (e) {
      final text = e.toString();
      var hint = '';
      if (text.toLowerCase().contains('token')) {
        hint = '\n\nThis usually means the API key and secret were copied '
            'wrongly, belong to a different LiveKit project than this server '
            'address, or the token has expired. Go back, check the token '
            'details on the first screen, and make a new token.';
        _giveUp = true;
      }
      _connError = 'Could not connect: $text$hint';
      _status = 'Not connected';
      _note('Connect failed: $text');
    } finally {
      _connecting = false;
    }
    _refresh();
  }

  /// Starts again with a fresh connection after the old one dropped.
  Future<void> _rebuildAndConnect() async {
    final old = _room;
    _events?.dispose();
    old.removeListener(_refresh);
    _wireRoom();
    _disposeRoom(old);
    await _connect();
  }

  void _watch() {
    if (_leaving) return;
    if (_connectedOnce &&
        !_giveUp &&
        !_connecting &&
        _room.connectionState == ConnectionState.disconnected) {
      _reconnects++;
      _note('Lost connection, reconnecting (try $_reconnects)');
      _rebuildAndConnect();
    }
    final last = _lastFixAt;
    if (_sharingLocation &&
        last != null &&
        DateTime.now().difference(last).inSeconds > 60) {
      _streamRestarts++;
      _note('No GPS update for 60 s, restarting location');
      _lastFixAt = DateTime.now();
      _startLocation();
    }
  }

  void _onData(DataReceivedEvent e) {
    if (e.topic != null && e.topic != 'loc') return;
    try {
      final map = jsonDecode(utf8.decode(e.data)) as Map<String, dynamic>;
      final id = e.participant?.identity ?? 'partner';
      _others[id] = Fix(
        (map['lat'] as num).toDouble(),
        (map['lng'] as num).toDouble(),
        (map['acc'] as num?)?.toDouble() ?? 0,
        DateTime.now(),
      );
      _fit(onlyOnce: true);
      _refresh();
    } catch (_) {
      // Ignore anything that is not a location message.
    }
  }

  Future<void> _sendFix() async {
    final me = _me;
    if (me == null) return;
    if (_room.connectionState != ConnectionState.connected) return;
    final payload = jsonEncode(<String, dynamic>{
      'lat': me.lat,
      'lng': me.lng,
      'acc': me.accuracy,
      'ts': DateTime.now().millisecondsSinceEpoch,
    });
    try {
      await _room.localParticipant?.publishData(
        utf8.encode(payload),
        reliable: false,
        topic: 'loc',
      );
      _sentCount++;
      _lastSentAt = DateTime.now();
    } catch (e) {
      _sendFails++;
      if (_sendFails <= 3) _note('Sending location failed: $e');
    }
  }

  Future<void> _talk(bool on) async {
    if (_talking == on) return;
    setState(() => _talking = on);
    try {
      await _room.localParticipant?.setMicrophoneEnabled(on);
    } catch (e) {
      _connError = 'Microphone problem: $e';
    }
    _refresh();
  }

  // --------------------------------------------------------------- location

  Future<void> _startLocation() async {
    if (!await Geolocator.isLocationServiceEnabled()) {
      _locError = 'Turn on location (GPS) in your phone settings.';
      _note('Location service is off');
      _refresh();
      return;
    }
    await _posSub?.cancel();
    final settings = AndroidSettings(
      accuracy: LocationAccuracy.best,
      distanceFilter: 0,
      intervalDuration: const Duration(seconds: 4),
      foregroundNotificationConfig: const ForegroundNotificationConfig(
        notificationTitle: 'TalkLoc is sharing your location',
        notificationText: 'Open the app to stop sharing.',
        enableWakeLock: true,
        setOngoing: true,
      ),
    );
    _posSub = Geolocator.getPositionStream(locationSettings: settings).listen(
      _onPosition,
      onError: (Object e) {
        _locError = 'Location problem: $e';
        _note('Location error: $e');
        _refresh();
      },
    );
    _sharingLocation = true;
    _note('Location sharing started');
    // Send a position every 5 s even when standing still.
    _beat?.cancel();
    _beat = Timer.periodic(const Duration(seconds: 5), (_) => _sendFix());
    _refresh();
  }

  void _onPosition(Position p) {
    _fixCount++;
    _lastFixAt = DateTime.now();
    _locError = null;
    final prev = _me;
    // Keep a better recent fix instead of jumping to a poor one.
    if (prev != null &&
        p.accuracy > 150 &&
        prev.accuracy < p.accuracy &&
        DateTime.now().difference(prev.at).inSeconds < 20) {
      return;
    }
    _me = Fix(p.latitude, p.longitude, p.accuracy, DateTime.now());
    _sendFix();
    _fit(onlyOnce: true);
    _refresh();
  }

  void _fit({bool onlyOnce = false}) {
    if (!_mapReady) return;
    if (onlyOnce && _fitDone) return;
    final points = <LatLng>[
      if (_me != null) _me!.point,
      ..._others.values.map((f) => f.point),
    ];
    if (points.isEmpty) return;
    try {
      if (points.length == 1) {
        _map.move(points.first, 16);
      } else {
        _map.fitCamera(
          CameraFit.coordinates(
            coordinates: points,
            padding: const EdgeInsets.fromLTRB(60, 120, 60, 380),
            maxZoom: 17,
          ),
        );
        _fitDone = true;
      }
    } catch (_) {}
  }

  // ------------------------------------------------------------ diagnostics

  String _diagnosticsText() {
    String ago(DateTime? t) =>
        t == null ? 'never' : '${DateTime.now().difference(t).inSeconds} s ago';
    final b = StringBuffer()
      ..writeln('Connection: ${_room.connectionState.name}')
      ..writeln('App state: ${_life.name}')
      ..writeln('GPS updates: $_fixCount (last ${ago(_lastFixAt)})')
      ..writeln(
        'Location sent: $_sentCount (last ${ago(_lastSentAt)}), '
        'failed $_sendFails',
      )
      ..writeln('Reconnects: $_reconnects, GPS restarts: $_streamRestarts')
      ..writeln(
        'My GPS accuracy: '
        '${_me == null ? 'none yet' : '+/- ${_me!.accuracy.round()} m'}',
      )
      ..writeln('--- log ---');
    for (final line in _log) {
      b.writeln(line);
    }
    return b.toString();
  }

  void _showDiagnostics() {
    final text = _diagnosticsText();
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Diagnostics',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 8),
              ConstrainedBox(
                constraints: BoxConstraints(
                  maxHeight: MediaQuery.of(ctx).size.height * 0.55,
                ),
                child: SingleChildScrollView(
                  child: SelectableText(
                    text,
                    style: const TextStyle(
                      fontSize: 12,
                      fontFamily: 'monospace',
                      height: 1.4,
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: FilledButton(
                      style: FilledButton.styleFrom(
                        backgroundColor: AppColors.orange,
                      ),
                      onPressed: () {
                        Clipboard.setData(ClipboardData(text: text));
                        Navigator.of(ctx).pop();
                      },
                      child: const Text('Copy'),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: OutlinedButton(
                      onPressed: () => openAppSettings(),
                      child: const Text('App settings'),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ------------------------------------------------------------------ build

  String _nameOf(String identity) {
    for (final p in _room.remoteParticipants.values) {
      if (p.identity == identity) {
        return p.name.isNotEmpty ? p.name : p.identity;
      }
    }
    return identity;
  }

  String _initials(String name) {
    final parts = name.trim().split(RegExp(r'\s+'));
    if (parts.isEmpty || parts.first.isEmpty) return '?';
    if (parts.length == 1) {
      return parts.first
          .substring(0, parts.first.length.clamp(1, 2))
          .toUpperCase();
    }
    return (parts.first[0] + parts.last[0]).toUpperCase();
  }

  String _compass(double degrees) {
    const names = [
      'north',
      'north-east',
      'east',
      'south-east',
      'south',
      'south-west',
      'west',
      'north-west',
    ];
    final d = ((degrees % 360) + 360) % 360;
    return names[(d / 45).round() % 8];
  }

  String _distanceText(double meters) {
    if (meters < 1000) return '${meters.round()} m';
    return '${(meters / 1000).toStringAsFixed(1)} km';
  }

  Widget _tile(String label, String value) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: AppColors.sand,
          borderRadius: BorderRadius.circular(14),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              label,
              style: const TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w500,
                color: AppColors.muted,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              value,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontSize: 17,
                fontWeight: FontWeight.w700,
                color: AppColors.ink,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _circleButton(IconData icon, String label, VoidCallback onTap) {
    return Material(
      color: Colors.white,
      elevation: 3,
      shape: const CircleBorder(),
      child: IconButton(
        tooltip: label,
        iconSize: 24,
        constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
        onPressed: onTap,
        icon: Icon(icon, color: AppColors.ink),
      ),
    );
  }

  Widget _banner(String text, {String? actionLabel, VoidCallback? onAction}) {
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.amberSoft,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            text,
            style: const TextStyle(
              fontSize: 13,
              height: 1.35,
              color: AppColors.amberInk,
            ),
          ),
          if (actionLabel != null && onAction != null)
            TextButton(
              style: TextButton.styleFrom(
                padding: EdgeInsets.zero,
                minimumSize: const Size(0, 36),
                alignment: Alignment.centerLeft,
                foregroundColor: AppColors.amberInk,
              ),
              onPressed: onAction,
              child: Text(
                actionLabel,
                style: const TextStyle(fontWeight: FontWeight.w700),
              ),
            ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final me = _me;
    final otherId = _others.isEmpty ? null : _others.keys.first;
    final other = otherId == null ? null : _others[otherId];

    var distance = '-';
    var direction = '-';
    var updated = '-';
    if (other != null) {
      final secs = DateTime.now().difference(other.at).inSeconds;
      updated = secs < 2 ? 'just now' : '$secs s ago';
      if (me != null) {
        final meters = Geolocator.distanceBetween(
          me.lat,
          me.lng,
          other.lat,
          other.lng,
        );
        final bearing = Geolocator.bearingBetween(
          me.lat,
          me.lng,
          other.lat,
          other.lng,
        );
        distance = _distanceText(meters);
        direction = _compass(bearing);
      }
    }

    final partnerName =
        otherId == null ? 'Waiting for partner' : _nameOf(otherId);
    final partnerSpeaking =
        _room.remoteParticipants.values.any((p) => p.isSpeaking);

    var statusLine = _status;
    if (_room.connectionState == ConnectionState.connected && other == null) {
      statusLine = _sharingLocation
          ? 'Connected. Waiting for your partner to share.'
          : 'Connected. Location sharing is off.';
    } else if (other != null) {
      statusLine = 'Connected';
    }
    if (_talking) statusLine = 'You are talking';
    if (partnerSpeaking) statusLine = '$partnerName is talking...';

    final gpsLine = me == null
        ? (_sharingLocation ? 'Finding your GPS...' : '')
        : 'Your GPS: +/- ${me.accuracy.round()} m'
            '${other != null ? '  |  Partner: +/- ${other.accuracy.round()} m' : ''}';

    final circles = <CircleMarker>[
      if (me != null && me.accuracy > 8)
        CircleMarker(
          point: me.point,
          radius: me.accuracy.clamp(5, 800).toDouble(),
          useRadiusInMeter: true,
          color: const Color(0x1FC93A08),
          borderColor: const Color(0x66C93A08),
          borderStrokeWidth: 1,
        ),
      for (final f in _others.values)
        if (f.accuracy > 8)
          CircleMarker(
            point: f.point,
            radius: f.accuracy.clamp(5, 800).toDouble(),
            useRadiusInMeter: true,
            color: const Color(0x1F0B6B5D),
            borderColor: const Color(0x660B6B5D),
            borderStrokeWidth: 1,
          ),
    ];

    final markers = <Marker>[
      if (me != null)
        Marker(
          point: me.point,
          width: 28,
          height: 28,
          child: Container(
            decoration: BoxDecoration(
              color: AppColors.orange,
              shape: BoxShape.circle,
              border: Border.all(color: Colors.white, width: 3),
              boxShadow: const [
                BoxShadow(color: Color(0x4D14201F), blurRadius: 6),
              ],
            ),
          ),
        ),
      for (final entry in _others.entries)
        Marker(
          point: entry.value.point,
          width: 52,
          height: 52,
          child: Container(
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: AppColors.green,
              shape: BoxShape.circle,
              border: Border.all(color: Colors.white, width: 3),
              boxShadow: const [
                BoxShadow(color: Color(0x4D14201F), blurRadius: 8),
              ],
            ),
            child: Text(
              _initials(_nameOf(entry.key)),
              style: const TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.w700,
                fontSize: 15,
              ),
            ),
          ),
        ),
    ];

    final double? lowAccuracy =
        (me != null && me.accuracy > 100) ? me.accuracy : null;

    return Scaffold(
      body: Stack(
        children: [
          Positioned.fill(
            child: FlutterMap(
              mapController: _map,
              options: MapOptions(
                initialCenter: const LatLng(20.5937, 78.9629),
                initialZoom: 4.5,
                onMapReady: () {
                  _mapReady = true;
                  _fit(onlyOnce: true);
                },
              ),
              children: [
                TileLayer(
                  urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                  userAgentPackageName: 'app.circles.talkloc',
                ),
                CircleLayer(circles: circles),
                MarkerLayer(markers: markers),
                RichAttributionWidget(
                  attributions: [
                    TextSourceAttribution('OpenStreetMap contributors'),
                  ],
                ),
              ],
            ),
          ),
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
              child: Row(
                children: [
                  _circleButton(Icons.arrow_back, 'Leave', () {
                    Navigator.of(context).pop();
                  }),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Container(
                      height: 48,
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(24),
                        boxShadow: const [
                          BoxShadow(color: Color(0x2E14201F), blurRadius: 8),
                        ],
                      ),
                      child: Row(
                        children: [
                          Container(
                            width: 10,
                            height: 10,
                            decoration: BoxDecoration(
                              color: other == null
                                  ? AppColors.muted
                                  : AppColors.green,
                              shape: BoxShape.circle,
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              partnerName,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontSize: 15,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  _circleButton(
                    Icons.bug_report_outlined,
                    'Diagnostics',
                    _showDiagnostics,
                  ),
                  const SizedBox(width: 8),
                  _circleButton(Icons.center_focus_strong, 'Show both', () {
                    _fit();
                  }),
                ],
              ),
            ),
          ),
          Align(
            alignment: Alignment.bottomCenter,
            child: Container(
              padding: EdgeInsets.fromLTRB(
                20,
                16,
                20,
                MediaQuery.of(context).padding.bottom + 20,
              ),
              decoration: const BoxDecoration(
                color: AppColors.cream,
                borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
                boxShadow: [
                  BoxShadow(color: Color(0x2414201F), blurRadius: 30),
                ],
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (_connError != null) _banner(_connError!),
                  if (_locError != null) _banner(_locError!),
                  if (lowAccuracy != null)
                    _banner(
                      'Your GPS is only accurate to about '
                      '${lowAccuracy.round()} m, so your pin may be off. '
                      'Go outdoors for a clear sky view, and in the app '
                      'settings turn on "Use precise location".',
                      actionLabel: 'Open app settings',
                      onAction: () => openAppSettings(),
                    ),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      statusLine,
                      style: const TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: AppColors.muted,
                      ),
                    ),
                  ),
                  if (gpsLine.isNotEmpty)
                    Align(
                      alignment: Alignment.centerLeft,
                      child: Padding(
                        padding: const EdgeInsets.only(top: 2),
                        child: Text(
                          gpsLine,
                          style: const TextStyle(
                            fontSize: 12,
                            color: AppColors.muted,
                          ),
                        ),
                      ),
                    ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      _tile('Distance', distance),
                      const SizedBox(width: 8),
                      _tile('Direction', direction),
                      const SizedBox(width: 8),
                      _tile('Updated', updated),
                    ],
                  ),
                  const SizedBox(height: 20),
                  Semantics(
                    button: true,
                    label: 'Hold to talk',
                    child: Listener(
                      onPointerDown: (_) => _talk(true),
                      onPointerUp: (_) => _talk(false),
                      onPointerCancel: (_) => _talk(false),
                      child: AnimatedContainer(
                        duration: const Duration(milliseconds: 120),
                        width: 112,
                        height: 112,
                        decoration: BoxDecoration(
                          color: _talking
                              ? AppColors.orangeDark
                              : AppColors.orange,
                          shape: BoxShape.circle,
                          boxShadow: [
                            BoxShadow(
                              color: const Color(0x40C93A08),
                              blurRadius: 0,
                              spreadRadius: _talking ? 20 : 8,
                            ),
                          ],
                        ),
                        child: const Icon(
                          Icons.mic,
                          color: Colors.white,
                          size: 48,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 14),
                  Text(
                    _talking ? 'Release to listen' : 'Hold to talk',
                    style: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
