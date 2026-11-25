import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart' hide ConnectionState;
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

class _TalkScreenState extends State<TalkScreen> {
  final Room _room = Room(
    roomOptions: RoomOptions(adaptiveStream: true, dynacast: true),
  );
  EventsListener<RoomEvent>? _events;
  StreamSubscription<Position>? _posSub;
  Timer? _beat;
  Timer? _tick;
  final MapController _map = MapController();

  Fix? _me;
  final Map<String, Fix> _others = <String, Fix>{};
  String _status = 'Starting...';
  String? _error;
  bool _talking = false;
  bool _mapReady = false;
  bool _fitDone = false;
  bool _sharingLocation = false;

  @override
  void initState() {
    super.initState();
    _room.addListener(_refresh);
    _tick = Timer.periodic(const Duration(seconds: 1), (_) => _refresh());
    WidgetsBinding.instance.addPostFrameCallback((_) => _start());
  }

  @override
  void dispose() {
    _tick?.cancel();
    _beat?.cancel();
    _posSub?.cancel();
    _events?.dispose();
    _room.removeListener(_refresh);
    _room.disconnect().then((_) => _room.dispose());
    super.dispose();
  }

  void _refresh() {
    if (mounted) setState(() {});
  }

  // ---------------------------------------------------------------- start

  Future<void> _start() async {
    final agreed = await _showDisclosure();
    var locationOk = false;
    if (agreed) {
      locationOk = await _askPermissions();
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

  // ----------------------------------------------------------- voice + data

  Future<void> _connect() async {
    final events = _room.createListener();
    _events = events;
    events
      ..on<DataReceivedEvent>(_onData)
      ..on<ParticipantConnectedEvent>((e) {
        _sendFix();
        _refresh();
      })
      ..on<ParticipantDisconnectedEvent>((e) {
        _others.remove(e.participant.identity);
        _refresh();
      })
      ..on<RoomDisconnectedEvent>((e) {
        _status = 'Disconnected';
        _refresh();
      })
      ..on<ActiveSpeakersChangedEvent>((e) => _refresh());

    try {
      await _room.connect(widget.url, widget.token);
      try {
        await Hardware.instance.setSpeakerphoneOn(true);
      } catch (_) {}
      _status = 'Connected';
    } catch (e) {
      _error = 'Could not connect: $e';
      _status = 'Not connected';
    }
    _refresh();
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
    } catch (_) {}
  }

  Future<void> _talk(bool on) async {
    if (_talking == on) return;
    setState(() => _talking = on);
    try {
      await _room.localParticipant?.setMicrophoneEnabled(on);
    } catch (e) {
      _error = 'Microphone problem: $e';
    }
    _refresh();
  }

  // --------------------------------------------------------------- location

  Future<void> _startLocation() async {
    if (!await Geolocator.isLocationServiceEnabled()) {
      _error = 'Turn on location (GPS) in your phone settings.';
      _refresh();
      return;
    }
    final settings = AndroidSettings(
      accuracy: LocationAccuracy.high,
      distanceFilter: 3,
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
        _error = 'Location problem: $e';
        _refresh();
      },
    );
    _sharingLocation = true;
    // Send a position every 5 s even when standing still.
    _beat = Timer.periodic(const Duration(seconds: 5), (_) => _sendFix());
    _refresh();
  }

  void _onPosition(Position p) {
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
            padding: const EdgeInsets.fromLTRB(60, 120, 60, 340),
            maxZoom: 17,
          ),
        );
        _fitDone = true;
      }
    } catch (_) {}
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
      return parts.first.substring(0, parts.first.length.clamp(1, 2)).toUpperCase();
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
                  const SizedBox(width: 10),
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
                  if (_error != null)
                    Container(
                      width: double.infinity,
                      margin: const EdgeInsets.only(bottom: 12),
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: AppColors.amberSoft,
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Text(
                        _error!,
                        style: const TextStyle(
                          fontSize: 13,
                          color: AppColors.amberInk,
                        ),
                      ),
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
