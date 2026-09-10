import 'dart:async';
import 'dart:convert';
import 'dart:ui' as ui;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:video_player/video_player.dart';

/// Which service a radar frame is fetched from.
///
/// ADR 0004 makes ECCC GeoMet the single radar source and RainViewer a fallback
/// used only when GeoMet is unreachable. Both shapes are kept because they are
/// fetched completely differently: GeoMet is a WMS that renders on demand and
/// wants an exact timestamp, RainViewer is a static tile CDN keyed by path.
enum _RadarSource { geomet, rainviewer }

/// ECCC GeoMet, precipitation rate for rain, 1 km composite.
const _geometBaseUrl = 'https://geo.weather.gc.ca/geomet?';
const _geometRadarLayer = 'RADAR_1KM_RRAI';

/// Discrete 14-colour ramp. The discrete styles encode to roughly a third the
/// bytes of the continuous ones (~7 KB vs ~23 KB per tile) for the same
/// coverage, which matters across a 31-frame loop on cellular.
const _geometRadarStyle = 'Radar-Rain_Dis-14colors';

const _radarAttribution = 'Radar: ECCC GeoMet';
const _radarAttributionFallback = 'Radar: RainViewer (ECCC unavailable)';

/// Upper bound on frames in one loop.
///
/// Flutter's default ImageCache holds 1000 images. A full-viewport radar loop
/// evicts well before that, so the loop is capped to keep the second pass
/// through the animation from re-fetching every frame.
const _maxRadarFrames = 40;

/// Parses the subset of ISO 8601 durations GeoMet uses for a time step
/// (`PT6M`, `PT1H`). Returns null for anything else rather than guessing.
/// Formats an instant the way GeoMet's time dimension expects it.
///
/// Second-precision, always UTC, no sub-second part. `DateTime.toIso8601String`
/// emits milliseconds, which GeoMet rejects.
@visibleForTesting
String formatGeoMetTime(DateTime instant) {
  final t = instant.toUtc();
  String two(int v) => v.toString().padLeft(2, '0');
  return '${t.year.toString().padLeft(4, '0')}-${two(t.month)}-${two(t.day)}'
      'T${two(t.hour)}:${two(t.minute)}:${two(t.second)}Z';
}

@visibleForTesting
Duration? parseIso8601Period(String value) {
  final match = RegExp(
    r'^PT(?:(\d+)H)?(?:(\d+)M)?(?:(\d+)S)?$',
  ).firstMatch(value.trim());
  if (match == null) return null;
  final h = int.tryParse(match.group(1) ?? '0') ?? 0;
  final m = int.tryParse(match.group(2) ?? '0') ?? 0;
  final sec = int.tryParse(match.group(3) ?? '0') ?? 0;
  if (h == 0 && m == 0 && sec == 0) return null;
  return Duration(hours: h, minutes: m, seconds: sec);
}

class _RadarFrame {
  const _RadarFrame({
    required this.source,
    required this.unixTime,
    this.path,
    this.forecast = false,
  });

  final _RadarSource source;
  final int unixTime;

  /// RainViewer tile path. Null for GeoMet frames, which address a frame by
  /// timestamp rather than by path.
  final String? path;

  /// True for RainViewer nowcast frames (predicted, ~30 min ahead) as opposed
  /// to observed past radar.
  final bool forecast;

  DateTime get utc =>
      DateTime.fromMillisecondsSinceEpoch(unixTime * 1000, isUtc: true);

  /// The exact instant string GeoMet's time dimension expects.
  ///
  /// The layer advertises `nearestValue="0"`, so the server matches the
  /// requested time exactly instead of snapping to the closest frame. A value
  /// that is off by a second returns nothing, which is why frame times are
  /// generated from the advertised extent rather than from the device clock.
  String get geometTime => formatGeoMetTime(utc);

  String rainviewerUrlTemplate() {
    return 'https://tilecache.rainviewer.com$path/256/{z}/{x}/{y}/6/1_1.png';
  }
}

class _RadarTimeline {
  const _RadarTimeline({
    required this.frames,
    this.source = _RadarSource.geomet,
  });

  final List<_RadarFrame> frames;
  final _RadarSource source;

  _RadarFrame? get latestOrNull => frames.isEmpty ? null : frames.last;

  bool get isEmpty => frames.isEmpty;

  String get attribution => source == _RadarSource.geomet
      ? _radarAttribution
      : _radarAttributionFallback;
}

/// Builds the tile layer for one radar frame.
///
/// GeoMet needs no `maxNativeZoom` cap: it renders each tile on request at
/// whatever zoom is asked for. The cap exists only on the RainViewer fallback,
/// whose tiles stop at z7.
Widget _radarTileLayer(_RadarFrame frame, {TileDisplay? tileDisplay}) {
  if (frame.source == _RadarSource.geomet) {
    return TileLayer(
      wmsOptions: WMSTileLayerOptions(
        baseUrl: _geometBaseUrl,
        layers: const [_geometRadarLayer],
        styles: const [_geometRadarStyle],
        version: '1.3.0',
        format: 'image/png',
        transparent: true,
        otherParameters: {'time': frame.geometTime},
      ),
      userAgentPackageName: 'ca.alberta.weather',
      tileDisplay: tileDisplay ?? const TileDisplay.fadeIn(),
    );
  }
  return TileLayer(
    urlTemplate: frame.rainviewerUrlTemplate(),
    // RainViewer radar tiles only exist up to z7; above that the server
    // returns a "Zoom Level Not Supported" placeholder, so cap native fetch
    // at 7 and let flutter_map upscale.
    maxNativeZoom: 7,
    userAgentPackageName: 'ca.alberta.weather',
    tileDisplay: tileDisplay ?? const TileDisplay.fadeIn(),
  );
}

class _SavedLocation {
  const _SavedLocation({
    required this.name,
    required this.province,
    required this.latitude,
    required this.longitude,
    required this.timezone,
  });

  final String name;
  final String province;
  final double latitude;
  final double longitude;
  final String timezone;

  bool sameSpotAs(_SavedLocation other) =>
      (latitude - other.latitude).abs() < 0.0001 &&
      (longitude - other.longitude).abs() < 0.0001;

  Map<String, dynamic> toJson() => {
    'name': name,
    'province': province,
    'latitude': latitude,
    'longitude': longitude,
    'timezone': timezone,
  };

  static _SavedLocation? fromJson(Map<String, dynamic> json) {
    final lat = _toDouble(json['latitude']);
    final lon = _toDouble(json['longitude']);
    if (lat == null || lon == null) {
      return null;
    }
    return _SavedLocation(
      name: '${json['name'] ?? 'Location'}',
      province: '${json['province'] ?? 'AB'}',
      latitude: lat,
      longitude: lon,
      timezone: '${json['timezone'] ?? 'America/Edmonton'}',
    );
  }
}

const _albertaBlue = Color(0xFF0B3A82);
const _albertaSky = Color(0xFF2F6FB2);
const _albertaGold = Color(0xFFF2C94C);
const _prairieCream = Color(0xFFFFF9EC);
// Edmonton, the provincial capital, is the default Location on first launch
// when no base has been set.
const _edmonton = _SavedLocation(
  name: 'Edmonton',
  province: 'AB',
  latitude: 53.5461,
  longitude: -113.4938,
  timezone: 'America/Edmonton',
);
const _defaultSavedLocations = <_SavedLocation>[
  _edmonton,
  _SavedLocation(
    name: 'Calgary',
    province: 'AB',
    latitude: 51.0447,
    longitude: -114.0719,
    timezone: 'America/Edmonton',
  ),
];

// Approximate provincial bounding box used to keep GPS-resolved Locations
// inside Alberta (lat 49N-60N, lon 110W-120W).
const _albertaLatMin = 48.9;
const _albertaLatMax = 60.1;
const _albertaLonMin = -120.1;
const _albertaLonMax = -109.9;
const _baseLocationPrefsKey = 'base_location';

/// Whether a geocoder hit is a place inside Alberta.
///
/// The bounding box alone clips corners of BC and Saskatchewan, so when the
/// geocoder names a province that name wins over the box.
bool _isAlbertaPlace(Map<String, dynamic> item, double lat, double lon) {
  final inBounds =
      lat >= _albertaLatMin &&
      lat <= _albertaLatMax &&
      lon >= _albertaLonMin &&
      lon <= _albertaLonMax;
  if (!inBounds) return false;

  final country = '${item['country_code'] ?? ''}'.toUpperCase();
  if (country.isNotEmpty && country != 'CA') return false;

  final admin1 = '${item['admin1'] ?? ''}'.trim();
  if (admin1.isNotEmpty && admin1 != 'Alberta') return false;

  return true;
}


void main() {
  runApp(const WeatherApp());
}

class WeatherApp extends StatelessWidget {
  const WeatherApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Alberta Weather',
      themeMode: ThemeMode.system,
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: _albertaBlue,
          primary: _albertaBlue,
          secondary: _albertaGold,
          surface: _prairieCream,
          brightness: Brightness.light,
        ),
        scaffoldBackgroundColor: const Color(0xFFF5F8FF),
        appBarTheme: const AppBarTheme(centerTitle: false),
      ),
      darkTheme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: _albertaBlue,
          primary: const Color(0xFF80A9FF),
          secondary: _albertaGold,
          brightness: Brightness.dark,
        ),
      ),
      home: const WeatherHomePage(),
    );
  }
}

class WeatherHomePage extends StatefulWidget {
  const WeatherHomePage({super.key});

  @override
  State<WeatherHomePage> createState() => _WeatherHomePageState();
}

class _WeatherHomePageState extends State<WeatherHomePage> {
  static const String _apiUrl = String.fromEnvironment(
    'WEATHER_API_URL',
    defaultValue: 'http://localhost:8000/v1/weather/myrnam',
  );

  late Future<Map<String, dynamic>> _weatherFuture;
  late Future<_RadarTimeline> _radarFuture;
  late List<_SavedLocation> _savedLocations;
  late _SavedLocation _selectedLocation;
  _SavedLocation? _baseLocation;
  bool _locating = false;

  @override
  void initState() {
    super.initState();
    _savedLocations = [..._defaultSavedLocations];
    _selectedLocation = _edmonton;
    _weatherFuture = _fetchWeather();
    _radarFuture = _fetchRadarTimeline().catchError(
      (_) => const _RadarTimeline(frames: []),
    );
    _initLocation();
  }

  // Opens on the operator's chosen base Location if one was saved. Otherwise
  // tries the device's current location automatically, falling back to
  // Edmonton (set above) if GPS is off, denied, or outside Alberta.
  Future<void> _initLocation() async {
    final hasBase = await _restoreBaseLocation();
    if (!hasBase) {
      await _useCurrentLocation(silent: true);
    }
  }

  Future<bool> _restoreBaseLocation() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_baseLocationPrefsKey);
    if (raw == null) {
      return false;
    }
    final decoded = jsonDecode(raw);
    if (decoded is! Map<String, dynamic>) {
      return false;
    }
    final base = _SavedLocation.fromJson(decoded);
    if (base == null || !mounted) {
      return false;
    }
    setState(() {
      _baseLocation = base;
      final alreadySaved = _savedLocations.any(base.sameSpotAs);
      if (!alreadySaved) {
        _savedLocations = [..._savedLocations, base];
      }
      _selectedLocation = base;
      _weatherFuture = _fetchWeather();
    });
    return true;
  }

  Future<void> _setAsBase(_SavedLocation location) async {
    setState(() => _baseLocation = location);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_baseLocationPrefsKey, jsonEncode(location.toJson()));
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('${location.name} set as your base location.')),
      );
    }
  }

  String _resolvedApiUrl() {
    if (!kIsWeb) {
      return _apiUrl;
    }

    final configured = Uri.parse(_apiUrl);
    if (configured.host != 'localhost' && configured.host != '127.0.0.1') {
      return _apiUrl;
    }

    final webHost = Uri.base.host;
    if (webHost.isEmpty) {
      return _apiUrl;
    }

    return configured.replace(host: webHost).toString();
  }

  String _urlForSelectedLocation() {
    final configured = Uri.parse(_resolvedApiUrl());

    if (_selectedLocation.name == 'Myrnam') {
      return configured.toString();
    }

    final base = Uri(
      scheme: configured.scheme,
      host: configured.host,
      port: configured.hasPort ? configured.port : null,
      path: '/v1/weather',
      queryParameters: {
        'lat': _selectedLocation.latitude.toString(),
        'lon': _selectedLocation.longitude.toString(),
        'timezone': _selectedLocation.timezone,
      },
    );
    return base.toString();
  }

  Future<Map<String, dynamic>> _fetchWeather() async {
    final response = await http.get(Uri.parse(_urlForSelectedLocation()));
    if (response.statusCode != 200) {
      throw Exception('API error ${response.statusCode}: ${response.body}');
    }

    final decoded = jsonDecode(response.body);
    if (decoded is! Map<String, dynamic>) {
      throw Exception('Unexpected API response format');
    }
    return decoded;
  }

  /// ADR 0004: ECCC GeoMet is the radar source, RainViewer is the fallback.
  Future<_RadarTimeline> _fetchRadarTimeline() async {
    try {
      return await _fetchGeoMetTimeline();
    } catch (_) {
      // GeoMet is a render-on-demand government service; when it is down or
      // slow the app still has to show radar, so fall through rather than
      // surfacing an error the user can do nothing about.
      return await _fetchRainViewerTimeline();
    }
  }

  /// Expands GeoMet's advertised time dimension into concrete frames.
  ///
  /// GeoMet publishes an ISO 8601 interval (`start/end/period`) rather than a
  /// frame list, so the frames are generated locally. This is also why the
  /// whole capabilities document is fetched only once per refresh instead of
  /// per frame.
  Future<_RadarTimeline> _fetchGeoMetTimeline() async {
    final response = await http
        .get(
          Uri.parse(
            '${_geometBaseUrl}service=WMS&version=1.3.0'
            '&request=GetCapabilities&LAYERS=$_geometRadarLayer',
          ),
        )
        .timeout(const Duration(seconds: 12));
    if (response.statusCode != 200) {
      throw Exception('GeoMet unavailable (${response.statusCode})');
    }

    final match = RegExp(
      r'<Dimension name="time"[^>]*>([^<]+)</Dimension>',
    ).firstMatch(response.body);
    if (match == null) {
      throw Exception('GeoMet returned no time dimension');
    }

    final parts = match.group(1)!.trim().split('/');
    if (parts.length != 3) {
      throw Exception('Unexpected GeoMet time extent');
    }

    final start = DateTime.tryParse(parts[0])?.toUtc();
    final end = DateTime.tryParse(parts[1])?.toUtc();
    final step = parseIso8601Period(parts[2]);
    if (start == null || end == null || step == null || step.inSeconds <= 0) {
      throw Exception('Unparseable GeoMet time extent');
    }

    final frames = <_RadarFrame>[];
    for (
      var t = start;
      !t.isAfter(end) && frames.length < _maxRadarFrames;
      t = t.add(step)
    ) {
      frames.add(
        _RadarFrame(
          source: _RadarSource.geomet,
          unixTime: t.millisecondsSinceEpoch ~/ 1000,
        ),
      );
    }

    if (frames.isEmpty) {
      throw Exception('No GeoMet radar frames available');
    }
    return _RadarTimeline(frames: frames, source: _RadarSource.geomet);
  }

  Future<_RadarTimeline> _fetchRainViewerTimeline() async {
    final response = await http.get(
      Uri.parse('https://api.rainviewer.com/public/weather-maps.json'),
    );
    if (response.statusCode != 200) {
      throw Exception('Radar source unavailable (${response.statusCode})');
    }

    final decoded = jsonDecode(response.body);
    if (decoded is! Map<String, dynamic>) {
      throw Exception('Unexpected radar response');
    }

    final radar = decoded['radar'] as Map<String, dynamic>? ?? const {};
    final past = radar['past'] as List<dynamic>? ?? const [];
    final nowcast = radar['nowcast'] as List<dynamic>? ?? const [];

    List<_RadarFrame> parseFrames(
      List<dynamic> source, {
      bool forecast = false,
    }) {
      return source
          .whereType<Map<String, dynamic>>()
          .map((item) {
            final path = item['path'];
            final time = item['time'];
            if (path is! String || time is! int) {
              return null;
            }
            return _RadarFrame(
              source: _RadarSource.rainviewer,
              path: path,
              unixTime: time,
              forecast: forecast,
            );
          })
          .whereType<_RadarFrame>()
          .toList();
    }

    // Observed past radar, then RainViewer's short nowcast (predicted ~30 min)
    // so the loop plays straight through into the near future.
    final frames = [
      ...parseFrames(past),
      ...parseFrames(nowcast, forecast: true),
    ]..sort((a, b) => a.unixTime.compareTo(b.unixTime));

    if (frames.isEmpty) {
      throw Exception('No radar frames available');
    }

    return _RadarTimeline(frames: frames, source: _RadarSource.rainviewer);
  }


  Future<void> _refresh() async {
    setState(() {
      _weatherFuture = _fetchWeather();
      _radarFuture = _fetchRadarTimeline().catchError(
        (_) => const _RadarTimeline(frames: []),
      );
    });
    await _weatherFuture;
  }

  void _selectLocation(_SavedLocation location) {
    setState(() {
      if (!_savedLocations.any(location.sameSpotAs)) {
        _savedLocations = [..._savedLocations, location];
      }
      _selectedLocation = location;
      _weatherFuture = _fetchWeather();
    });
  }

  // Resolves the device's current spot and switches to it. Used both by the
  // location button (silent: false, reports failures via snackbar) and by
  // app launch (silent: true, fails quietly back to Edmonton). Stays inside
  // the province per the product scope.
  Future<void> _useCurrentLocation({bool silent = false}) async {
    if (_locating) {
      return;
    }
    setState(() => _locating = true);
    try {
      if (!await Geolocator.isLocationServiceEnabled()) {
        if (!silent) _showLocationMessage('Turn on location services to use this.');
        return;
      }
      var permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }
      if (permission == LocationPermission.denied ||
          permission == LocationPermission.deniedForever) {
        if (!silent) _showLocationMessage('Location permission denied.');
        return;
      }

      final position = await Geolocator.getCurrentPosition();
      final lat = position.latitude;
      final lon = position.longitude;
      final inAlberta =
          lat >= _albertaLatMin &&
          lat <= _albertaLatMax &&
          lon >= _albertaLonMin &&
          lon <= _albertaLonMax;
      if (!inAlberta) {
        if (!silent) {
          _showLocationMessage(
            'Alberta Weather only covers locations in Alberta.',
          );
        }
        return;
      }

      final current = _SavedLocation(
        name: 'Current location',
        province: 'AB',
        latitude: lat,
        longitude: lon,
        timezone: 'America/Edmonton',
      );
      setState(() {
        _savedLocations = [
          ..._savedLocations.where((l) => l.name != 'Current location'),
          current,
        ];
        _selectedLocation = current;
        _weatherFuture = _fetchWeather();
      });
    } catch (_) {
      if (!silent) _showLocationMessage('Could not get your location.');
    } finally {
      if (mounted) {
        setState(() => _locating = false);
      }
    }
  }

  void _showLocationMessage(String message) {
    if (!mounted) {
      return;
    }
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  Future<List<_SavedLocation>> _searchLocations(String query) async {
    final trimmed = query.trim();
    if (trimmed.isEmpty) {
      return [];
    }

    final uri = Uri.https('geocoding-api.open-meteo.com', '/v1/search', {
      'name': trimmed,
      'count': '8',
      'language': 'en',
      'format': 'json',
    });

    final response = await http.get(uri);
    if (response.statusCode != 200) {
      throw Exception('Location lookup failed (${response.statusCode})');
    }

    final decoded = jsonDecode(response.body);
    if (decoded is! Map<String, dynamic>) {
      return [];
    }

    final results = (decoded['results'] as List<dynamic>? ?? []);
    return results
        .whereType<Map<String, dynamic>>()
        .map((item) {
          final name = '${item['name'] ?? 'Unknown'}';
          final lat = _toDouble(item['latitude']);
          final lon = _toDouble(item['longitude']);
          final timezone = '${item['timezone'] ?? 'auto'}';
          if (lat == null || lon == null) {
            return null;
          }
          // CONTEXT.md: a Saved Location is always inside Alberta. The geocoder
          // is a world feed and will happily return Vancouver or Phoenix, so
          // the provincial boundary is enforced here rather than trusted.
          if (!_isAlbertaPlace(item, lat, lon)) {
            return null;
          }
          return _SavedLocation(
            name: name,
            province: 'AB',
            latitude: lat,
            longitude: lon,
            timezone: timezone,
          );
        })
        .whereType<_SavedLocation>()
        .toList();
  }

  Future<void> _openLocationPicker() async {
    final selected = await showModalBottomSheet<_SavedLocation>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (context) {
        return _LocationPickerSheet(
          selectedLocation: _selectedLocation,
          savedLocations: _savedLocations,
          baseLocation: _baseLocation,
          onSearch: _searchLocations,
          onSetBase: _setAsBase,
        );
      },
    );

    if (selected != null) {
      _selectLocation(selected);
    }
  }

  Future<void> _openDayDetailsOverlay({
    required Map<String, dynamic> day,
    required Map<String, dynamic>? dayparts,
    Offset? tapPosition,
  }) async {
    final media = MediaQuery.of(context);
    final screenHeight = media.size.height;
    final normalizedY = tapPosition == null
        ? 0.5
        : (tapPosition.dy / screenHeight).clamp(0.06, 0.94);
    final alignmentY = (normalizedY * 2) - 1;

    await showGeneralDialog<void>(
      context: context,
      barrierDismissible: true,
      barrierLabel: 'Close day details',
      barrierColor: Colors.black.withValues(alpha: 0.38),
      transitionDuration: const Duration(milliseconds: 220),
      pageBuilder: (dialogContext, _, _) {
        return SafeArea(
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => Navigator.of(dialogContext).pop(),
            child: Align(
              alignment: Alignment(0, alignmentY),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 14),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 640),
                  child: _InlineDayDetailsCard(day: day, dayparts: dayparts),
                ),
              ),
            ),
          ),
        );
      },
      transitionBuilder: (_, animation, secondaryAnimation, child) {
        final curved = CurvedAnimation(
          parent: animation,
          curve: Curves.easeOutCubic,
          reverseCurve: Curves.easeInCubic,
        );
        return FadeTransition(
          opacity: curved,
          child: ScaleTransition(
            scale: Tween<double>(begin: 0.94, end: 1).animate(curved),
            child: child,
          ),
        );
      },
    );
  }

  Future<void> _openHourlyDetailsOverlay(
    Map<String, dynamic> item, {
    Offset? tapPosition,
  }) async {
    final media = MediaQuery.of(context);
    final screenHeight = media.size.height;
    final normalizedY = tapPosition == null
        ? 0.5
        : (tapPosition.dy / screenHeight).clamp(0.06, 0.94);
    final alignmentY = (normalizedY * 2) - 1;

    await showGeneralDialog<void>(
      context: context,
      barrierDismissible: true,
      barrierLabel: 'Close hourly details',
      barrierColor: Colors.black.withValues(alpha: 0.38),
      transitionDuration: const Duration(milliseconds: 220),
      pageBuilder: (dialogContext, _, _) {
        return SafeArea(
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => Navigator.of(dialogContext).pop(),
            child: Align(
              alignment: Alignment(0, alignmentY),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 14),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 640),
                  child: _InlineHourlyDetailsCard(item: item),
                ),
              ),
            ),
          ),
        );
      },
      transitionBuilder: (_, animation, secondaryAnimation, child) {
        final curved = CurvedAnimation(
          parent: animation,
          curve: Curves.easeOutCubic,
          reverseCurve: Curves.easeInCubic,
        );
        return FadeTransition(
          opacity: curved,
          child: ScaleTransition(
            scale: Tween<double>(begin: 0.94, end: 1).animate(curved),
            child: child,
          ),
        );
      },
    );
  }

  Future<void> _openRadarViewer() async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Colors.transparent,
      builder: (context) {
        return FractionallySizedBox(
          heightFactor: 0.92,
          child: _RadarViewerSheet(
            timelineFuture: _radarFuture,
            location: _selectedLocation,
          ),
        );
      },
    );
  }

  Map<String, dynamic>? _todayForecast({
    required dynamic currentTime,
    required List<dynamic> daily7,
    required List<dynamic> daily14,
  }) {
    final date = _extractDate(currentTime);
    final all = [...daily7, ...daily14];

    if (date != null) {
      for (final item in all.whereType<Map<String, dynamic>>()) {
        if ('${item['date'] ?? ''}' == date) {
          return item;
        }
      }
    }

    for (final item in all) {
      if (item is Map<String, dynamic>) {
        return item;
      }
    }
    return null;
  }

  String? _extractDate(dynamic iso) {
    final value = '$iso';
    if (value.contains('T')) {
      return value.split('T').first;
    }
    if (value.length >= 10 && value.contains('-')) {
      return value.substring(0, 10);
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      body: FutureBuilder<Map<String, dynamic>>(
        future: _weatherFuture,
        builder: (context, snapshot) {
          final data = snapshot.data;
          final current = (data?['current'] as Map<String, dynamic>? ?? {});

          if (snapshot.connectionState == ConnectionState.waiting) {
            return Stack(
              children: [
                const Positioned.fill(child: _CrestWeatherBackground()),
                const Center(child: CircularProgressIndicator()),
              ],
            );
          }

          if (snapshot.hasError) {
            return Stack(
              children: [
                const Positioned.fill(child: _CrestWeatherBackground()),
                RefreshIndicator(
                  onRefresh: _refresh,
                  child: ListView(
                    children: [
                      const SizedBox(height: 120),
                      Center(
                        child: Padding(
                          padding: const EdgeInsets.all(24),
                          child: Text(
                            'Could not load weather.\n${snapshot.error}',
                            textAlign: TextAlign.center,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            );
          }

          final weatherData = snapshot.data!;
          final location =
              (weatherData['location'] as Map<String, dynamic>? ?? {});
          final hourly =
              (weatherData['hourly_next_24h'] as List<dynamic>? ?? []);
          final daily7 = (weatherData['daily_7d'] as List<dynamic>? ?? []);
          final daily14 =
              (weatherData['daily_14d_extended'] as List<dynamic>? ?? []);
          final sources =
              (weatherData['sources'] as List<dynamic>? ?? const []);
          final alerts =
              (weatherData['alerts'] as List<dynamic>? ?? const []);
          final dayparts =
              (weatherData['dayparts_14d'] as List<dynamic>? ?? const []);
          final daypartsByDate = <String, Map<String, dynamic>>{
            for (final item in dayparts.whereType<Map<String, dynamic>>())
              if ('${item['date']}'.isNotEmpty) '${item['date']}': item,
          };

          return Stack(
            children: [
              const Positioned.fill(child: _CrestWeatherBackground()),
              RefreshIndicator(
                onRefresh: _refresh,
                child: ListView(
                  padding: EdgeInsets.fromLTRB(
                    16,
                    12 + MediaQuery.of(context).padding.top,
                    16,
                    24,
                  ),
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: _LocationPickerButton(
                            selected: _selectedLocation,
                            onTap: _openLocationPicker,
                            onLongPress: _openLocationPicker,
                          ),
                        ),
                        const SizedBox(width: 8),
                        SizedBox(
                          height: 48,
                          child: FilledButton(
                            style: FilledButton.styleFrom(
                              backgroundColor: _albertaGold,
                              foregroundColor: _albertaBlue,
                              padding: const EdgeInsets.symmetric(
                                horizontal: 14,
                              ),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(14),
                              ),
                            ),
                            onPressed: _locating ? null : _useCurrentLocation,
                            child: _locating
                                ? const SizedBox(
                                    width: 18,
                                    height: 18,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                    ),
                                  )
                                : const Icon(Icons.my_location_rounded),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    // ADR 0005: alerts are life-safety, so they sit above the
                    // forecast rather than inside it.
                    if (alerts.isNotEmpty) ...[
                      _AlertsStrip(alerts: alerts),
                      const SizedBox(height: 12),
                    ],
                    _HeroCurrentCard(
                      location: location,
                      current: current,
                      selectedLocation: _selectedLocation,
                      todayForecast: _todayForecast(
                        currentTime: current['time'],
                        daily7: daily7,
                        daily14: daily14,
                      ),
                      radarFuture: _radarFuture,
                      onRadarTap: _openRadarViewer,
                      sources: sources,
                    ),
                    const SizedBox(height: 16),
                    _SectionHeader(title: 'Highlights'),
                    const SizedBox(height: 8),
                    _MetricsGrid(current: current),
                    const SizedBox(height: 20),
                    _SectionHeader(title: 'Hourly'),
                    const SizedBox(height: 8),
                    SizedBox(
                      height: 138,
                      child: ListView.separated(
                        scrollDirection: Axis.horizontal,
                        itemCount: hourly.length > 24 ? 24 : hourly.length,
                        separatorBuilder: (_, _) => const SizedBox(width: 10),
                        itemBuilder: (context, index) {
                          final item = hourly[index] as Map<String, dynamic>;
                          return _HourlyTile(
                            item: item,
                            onTapUp: (tapPosition) => _openHourlyDetailsOverlay(
                              item,
                              tapPosition: tapPosition,
                            ),
                          );
                        },
                      ),
                    ),
                    const SizedBox(height: 20),
                    _SectionHeader(title: '7-Day Forecast'),
                    const SizedBox(height: 8),
                    ...daily7.whereType<Map<String, dynamic>>().map((item) {
                      final dateKey = '${item['date'] ?? ''}';
                      return _DailyForecastRow(
                        item: item,
                        theme: theme,
                        onTapUp: (tapPosition) => _openDayDetailsOverlay(
                          day: item,
                          dayparts: daypartsByDate[dateKey],
                          tapPosition: tapPosition,
                        ),
                      );
                    }),
                    const SizedBox(height: 20),
                    _SectionHeader(title: '14-Day Extended'),
                    const SizedBox(height: 8),
                    ...daily14.whereType<Map<String, dynamic>>().map((item) {
                      final dateKey = '${item['date'] ?? ''}';
                      return _DailyForecastRow(
                        item: item,
                        theme: theme,
                        compact: true,
                        onTapUp: (tapPosition) => _openDayDetailsOverlay(
                          day: item,
                          dayparts: daypartsByDate[dateKey],
                          tapPosition: tapPosition,
                        ),
                      );
                    }),
                    const _BuiltByFooter(),
                  ],
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _LocationPickerButton extends StatelessWidget {
  const _LocationPickerButton({
    required this.selected,
    required this.onTap,
    required this.onLongPress,
  });

  final _SavedLocation selected;
  final VoidCallback onTap;
  final VoidCallback onLongPress;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onLongPress: onLongPress,
      child: FilledButton.icon(
        style: FilledButton.styleFrom(
          backgroundColor: _albertaBlue,
          foregroundColor: Colors.white,
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
          ),
        ),
        onPressed: onTap,
        icon: const Icon(Icons.place_rounded),
        label: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Flexible(
              child: Text(
                '${selected.name}, ${selected.province}',
                overflow: TextOverflow.ellipsis,
              ),
            ),
            const SizedBox(width: 6),
            const Icon(Icons.unfold_more_rounded, size: 18),
          ],
        ),
      ),
    );
  }
}

class _LocationPickerSheet extends StatefulWidget {
  const _LocationPickerSheet({
    required this.selectedLocation,
    required this.savedLocations,
    required this.baseLocation,
    required this.onSearch,
    required this.onSetBase,
  });

  final _SavedLocation selectedLocation;
  final List<_SavedLocation> savedLocations;
  final _SavedLocation? baseLocation;
  final Future<List<_SavedLocation>> Function(String query) onSearch;
  final void Function(_SavedLocation location) onSetBase;

  @override
  State<_LocationPickerSheet> createState() => _LocationPickerSheetState();
}

class _LocationPickerSheetState extends State<_LocationPickerSheet> {
  final TextEditingController _controller = TextEditingController();
  bool _loading = false;
  bool _searched = false;
  String? _error;
  List<_SavedLocation> _results = const [];
  _SavedLocation? _base;

  @override
  void initState() {
    super.initState();
    _base = widget.baseLocation;
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _runSearch() async {
    final query = _controller.text.trim();
    if (query.isEmpty) {
      setState(() {
        _results = const [];
        _error = null;
        _searched = false;
      });
      return;
    }

    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      final found = await widget.onSearch(query);
      if (!mounted) return;
      setState(() {
        _results = found;
        _searched = true;
      });
    } catch (err) {
      if (!mounted) return;
      setState(() {
        _error = '$err';
      });
    } finally {
      if (mounted) {
        setState(() {
          _loading = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.only(
          left: 16,
          right: 16,
          top: 8,
          bottom: 16 + MediaQuery.of(context).viewInsets.bottom,
        ),
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Choose location',
                style: Theme.of(
                  context,
                ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 6),
              Text(
                'Tap a saved location or search a new one.',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _controller,
                decoration: InputDecoration(
                  hintText: 'Search city (e.g., Red Deer)',
                  prefixIcon: const Icon(Icons.search),
                  suffixIcon: IconButton(
                    onPressed: _loading ? null : _runSearch,
                    icon: const Icon(Icons.arrow_forward_rounded),
                  ),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
                textInputAction: TextInputAction.search,
                onSubmitted: (_) => _runSearch(),
              ),
              if (_loading)
                const Padding(
                  padding: EdgeInsets.only(top: 12),
                  child: LinearProgressIndicator(),
                ),
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.only(top: 10),
                  child: Text(
                    _error!,
                    style: Theme.of(
                      context,
                    ).textTheme.bodySmall?.copyWith(color: Colors.redAccent),
                  ),
                ),
              if (_searched && _results.isEmpty && !_loading && _error == null)
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: Text(
                    'No Alberta match. This app covers Alberta only, so '
                    'places outside the province are not offered.',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
              if (_results.isNotEmpty) ...[
                const SizedBox(height: 14),
                Text(
                  'Search results',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: 8),
                ..._results.map(
                  (location) => ListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.add_location_alt_outlined),
                    title: Text('${location.name}, ${location.province}'),
                    subtitle: Text(location.timezone),
                    onTap: () => Navigator.of(context).pop(location),
                  ),
                ),
              ],
              const SizedBox(height: 12),
              Text(
                'Saved locations',
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 2),
              Text(
                'Tap to view. Tap the star to set your base — the location '
                'the app opens to.',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const SizedBox(height: 6),
              ...widget.savedLocations.map((location) {
                final selected = location.sameSpotAs(widget.selectedLocation);
                final isBase = _base != null && location.sameSpotAs(_base!);
                return ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(
                    selected
                        ? Icons.radio_button_checked
                        : Icons.radio_button_unchecked,
                    color: selected ? _albertaBlue : null,
                  ),
                  title: Text('${location.name}, ${location.province}'),
                  subtitle: Text(location.timezone),
                  trailing: IconButton(
                    icon: Icon(
                      isBase ? Icons.star_rounded : Icons.star_border_rounded,
                      color: isBase ? _albertaGold : null,
                    ),
                    tooltip: isBase ? 'Base location' : 'Set as base',
                    onPressed: () {
                      setState(() => _base = location);
                      widget.onSetBase(location);
                    },
                  ),
                  onTap: () => Navigator.of(context).pop(location),
                );
              }),
            ],
          ),
        ),
      ),
    );
  }
}

class _CrestWeatherBackground extends StatefulWidget {
  const _CrestWeatherBackground();

  @override
  State<_CrestWeatherBackground> createState() =>
      _CrestWeatherBackgroundState();
}

class _CrestWeatherBackgroundState extends State<_CrestWeatherBackground> {
  late final VideoPlayerController _controller;
  bool _videoAvailable = true;

  @override
  void initState() {
    super.initState();
    _controller = VideoPlayerController.asset('assets/videos/good_one.mp4')
      ..setLooping(true)
      ..setVolume(0);

    try {
      _controller
          .initialize()
          .then((_) {
            if (!mounted) return;
            setState(() {});
            unawaited(_controller.play());
          })
          .catchError((_) {
            if (!mounted) return;
            setState(() {
              _videoAvailable = false;
            });
          });
    } catch (_) {
      _videoAvailable = false;
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!_videoAvailable || !_controller.value.isInitialized) {
      return Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Color(0xFF0A2E66), Color(0xFF051734)],
          ),
        ),
      );
    }

    return Stack(
      fit: StackFit.expand,
      children: [
        Transform.scale(
          scale: 1.12,
          child: FittedBox(
            fit: BoxFit.cover,
            child: SizedBox(
              width: _controller.value.size.width,
              height: _controller.value.size.height,
              child: VideoPlayer(_controller),
            ),
          ),
        ),
        Container(color: Colors.black.withValues(alpha: 0.30)),
      ],
    );
  }
}

class _HeroCurrentCard extends StatelessWidget {
  const _HeroCurrentCard({
    required this.location,
    required this.current,
    required this.selectedLocation,
    required this.todayForecast,
    required this.radarFuture,
    required this.onRadarTap,
    required this.sources,
  });

  final Map<String, dynamic> location;
  final Map<String, dynamic> current;
  final _SavedLocation selectedLocation;
  final Map<String, dynamic>? todayForecast;
  final Future<_RadarTimeline> radarFuture;
  final VoidCallback onRadarTap;
  final List<dynamic> sources;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final weather = '${current['weather'] ?? '-'}';
    final locationName = '${location['name'] ?? ''}'.trim().isEmpty
        ? selectedLocation.name
        : '${location['name']}';
    final province = '${location['province'] ?? ''}'.trim().isEmpty
        ? selectedLocation.province
        : '${location['province']}';

    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(20),
        gradient: const LinearGradient(
          colors: [_albertaBlue, _albertaSky],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '$locationName, $province',
                      style: theme.textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.w700,
                        color: Colors.white,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      'Built for Alberta days',
                      style: theme.textTheme.labelMedium?.copyWith(
                        color: Colors.white,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '${current['time'] ?? ''}',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: Colors.white70,
                      ),
                    ),
                    const SizedBox(height: 14),
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        _weatherGlyph(
                          weather,
                          current['weather_code'],
                          current['is_daylight'],
                          _scaledGlyphSize(32),
                          current['time'],
                        ),
                        const SizedBox(width: 10),
                        Text(
                          '${_fmt(current['temperature'])}°C',
                          style: theme.textTheme.displaySmall?.copyWith(
                            fontWeight: FontWeight.w700,
                            height: 1,
                            color: Colors.white,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'H ${_fmt(todayForecast?['temperature_max'])}°C   L ${_fmt(todayForecast?['temperature_min'])}°C',
                      style: theme.textTheme.titleMedium?.copyWith(
                        color: Colors.white,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      weather,
                      style: theme.textTheme.titleMedium?.copyWith(
                        color: Colors.white,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      'Feels like ${_fmt(current['apparent_temperature'])}°C',
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: Colors.white70,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      'Sunrise ${_fmtClockFromIso(current['sunrise'])}',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: Colors.white70,
                      ),
                    ),
                    Text(
                      'Sunset ${_fmtClockFromIso(current['sunset'])}',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: Colors.white70,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              SizedBox(
                // Sized so the Alberta cutout stands the full height of the text
                // column beside it (~236pt) instead of stopping short. Width and
                // height move together: the ratio is Alberta's real proportions,
                // so changing only one axis stretches the province.
                width: 128,
                child: AspectRatio(
                  aspectRatio: 128 / 236,
                  child: GestureDetector(
                    onTap: onRadarTap,
                    behavior: HitTestBehavior.opaque,
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        ClipPath(
                          clipper: const _AlbertaShapeClipper(),
                          child: _RadarPreviewCard(
                            timelineFuture: radarFuture,
                            location: selectedLocation,
                          ),
                        ),
                        CustomPaint(painter: const _AlbertaBorderPainter()),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),
            // ADR 0001 makes multi-source side-by-side the product's
            // differentiator. The strip was built but never mounted, so the
            // comparison shipped invisible. It sits under the hero row at full
            // card width so the chips can wrap instead of fighting the radar.
            if (sources.isNotEmpty) ...[
              const SizedBox(height: 14),
              Divider(
                height: 1,
                thickness: 1,
                color: Colors.white.withValues(alpha: 0.15),
              ),
              const SizedBox(height: 12),
              _SourceComparisonStrip(sources: sources),
            ],
          ],
        ),
      ),
    );
  }
}

class _SourceComparisonStrip extends StatelessWidget {
  const _SourceComparisonStrip({required this.sources});

  final List<dynamic> sources;

  static const Map<String, String> _shortLabels = {
    'open-meteo': 'Open-Meteo',
    'eccc': 'ECCC',
    'apple-weatherkit': 'WeatherKit',
  };

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final chips = <Widget>[];
    for (final raw in sources) {
      if (raw is! Map) continue;
      final source = raw.cast<String, dynamic>();
      final id = '${source['source_id'] ?? ''}';
      final label = _shortLabels[id] ?? id;
      final current = source['current'] as Map<String, dynamic>?;
      final temp = current?['temperature'];
      final error = source['error'];
      final tempText = (temp is num) ? '${temp.toStringAsFixed(0)}°' : '—';

      chips.add(
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
          decoration: BoxDecoration(
            color: error == null
                ? Colors.white.withValues(alpha: 0.18)
                : Colors.white.withValues(alpha: 0.08),
            borderRadius: BorderRadius.circular(999),
            border: Border.all(
              color: Colors.white.withValues(alpha: 0.25),
              width: 0.5,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                label,
                style: theme.textTheme.labelSmall?.copyWith(
                  color: Colors.white70,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(width: 6),
              Text(
                error == null ? tempText : '—',
                style: theme.textTheme.labelMedium?.copyWith(
                  color: Colors.white,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
        ),
      );
    }

    if (chips.isEmpty) return const SizedBox.shrink();

    return Wrap(spacing: 6, runSpacing: 6, children: chips);
  }
}

/// ECCC severe-weather alerts.
///
/// ADR 0005 sets a passive posture: this widget owns layout, typography and
/// severity colour, and nothing else. The alert text is ECCC's, rendered whole.
/// It is never paraphrased, condensed, or ellipsised, because the moment we
/// reword a tornado warning we take on interpretive liability for a life-safety
/// message. Long alerts get a scrollable body rather than a shortened one.
class _AlertsStrip extends StatelessWidget {
  const _AlertsStrip({required this.alerts});

  final List<dynamic> alerts;

  @override
  Widget build(BuildContext context) {
    final cards = alerts
        .whereType<Map<String, dynamic>>()
        .map((alert) => _AlertCard(alert: alert))
        .toList();
    if (cards.isEmpty) return const SizedBox.shrink();

    return Column(
      children: [
        for (var i = 0; i < cards.length; i++) ...[
          if (i > 0) const SizedBox(height: 8),
          cards[i],
        ],
      ],
    );
  }
}

class _AlertCard extends StatefulWidget {
  const _AlertCard({required this.alert});

  final Map<String, dynamic> alert;

  @override
  State<_AlertCard> createState() => _AlertCardState();
}

class _AlertCardState extends State<_AlertCard> {
  bool _expanded = false;

  /// ECCC publishes its own risk colour. Using it keeps severity presentation
  /// consistent with WeatherCAN and every other official channel, rather than
  /// inventing a second severity language.
  Color _riskColour(String raw) {
    switch (raw.trim().toLowerCase()) {
      case 'red':
        return const Color(0xFFC62828);
      case 'orange':
        return const Color(0xFFE65100);
      case 'yellow':
        return const Color(0xFFF9A825);
      case 'grey':
      case 'gray':
        return const Color(0xFF546E7A);
      default:
        return const Color(0xFF546E7A);
    }
  }

  String _expiryLabel(Object? raw) {
    if (raw is! String || raw.trim().isEmpty) return '';
    final parsed = DateTime.tryParse(raw);
    if (parsed == null) return '';
    final local = parsed.toLocal();
    String two(int v) => v.toString().padLeft(2, '0');
    return 'Until ${two(local.hour)}:${two(local.minute)}';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final alert = widget.alert;

    final name = '${alert['name'] ?? ''}'.trim();
    final region = '${alert['region'] ?? ''}'.trim();
    final text = '${alert['text'] ?? ''}'.trim();
    final colour = _riskColour('${alert['risk_colour'] ?? ''}');
    final expiry = _expiryLabel(alert['expires_at']);
    final hasBody = text.isNotEmpty;

    return Semantics(
      liveRegion: true,
      container: true,
      label: 'Weather alert: $name${region.isEmpty ? '' : ', $region'}',
      child: Material(
        color: colour,
        borderRadius: BorderRadius.circular(14),
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: hasBody ? () => setState(() => _expanded = !_expanded) : null,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Icon(
                      Icons.warning_amber_rounded,
                      color: Colors.white,
                      size: 22,
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            // ECCC's own wording, capitalisation included.
                            name,
                            style: theme.textTheme.titleSmall?.copyWith(
                              color: Colors.white,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                          if (region.isNotEmpty)
                            Text(
                              region,
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: Colors.white70,
                              ),
                            ),
                        ],
                      ),
                    ),
                    if (expiry.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(left: 8),
                        child: Text(
                          expiry,
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: Colors.white70,
                          ),
                        ),
                      ),
                    if (hasBody)
                      Icon(
                        _expanded
                            ? Icons.expand_less_rounded
                            : Icons.expand_more_rounded,
                        color: Colors.white70,
                        size: 20,
                      ),
                  ],
                ),
                if (_expanded && hasBody) ...[
                  const SizedBox(height: 10),
                  // ECCC alert bodies run long and must not be truncated, so
                  // the card caps its height and scrolls instead.
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxHeight: 260),
                    child: SingleChildScrollView(
                      child: Text(
                        text,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: Colors.white,
                          height: 1.35,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Issued by Environment and Climate Change Canada',
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: Colors.white60,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _RadarPreviewCard extends StatelessWidget {
  const _RadarPreviewCard({
    required this.timelineFuture,
    required this.location,
  });

  final Future<_RadarTimeline> timelineFuture;
  final _SavedLocation location;

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        FutureBuilder<_RadarTimeline>(
          future: timelineFuture,
          builder: (context, snapshot) {
            if (!snapshot.hasData || snapshot.data!.latestOrNull == null) {
              return Container(
                color: Colors.black.withValues(alpha: 0.25),
                alignment: Alignment.center,
                child: const Icon(Icons.radar, color: Colors.white70, size: 36),
              );
            }
            return FlutterMap(
              options: MapOptions(
                initialCameraFit: CameraFit.bounds(
                  bounds: LatLngBounds(
                    const LatLng(48.9, -120.1),
                    const LatLng(60.1, -109.9),
                  ),
                  padding: const EdgeInsets.all(4),
                ),
                interactionOptions: const InteractionOptions(
                  flags: InteractiveFlag.none,
                ),
              ),
              children: [
                TileLayer(
                  urlTemplate:
                      'https://{s}.basemaps.cartocdn.com/dark_all/{z}/{x}/{y}.png',
                  userAgentPackageName: 'ca.alberta.weather',
                ),
                // Static newest frame; no cross-dissolve needed in the
                // preview, so it paints instantly rather than fading in.
                _radarTileLayer(
                  snapshot.data!.latestOrNull!,
                  tileDisplay: const TileDisplay.instantaneous(),
                ),
              ],
            );
          },
        ),
        DecoratedBox(
          decoration: BoxDecoration(
            gradient: RadialGradient(
              center: Alignment.center,
              radius: 1.0,
              colors: [
                Colors.transparent,
                Colors.black.withValues(alpha: 0.38),
              ],
              stops: const [0.6, 1],
            ),
          ),
        ),
        Positioned(
          right: 10,
          bottom: 10,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            decoration: BoxDecoration(
              color: Colors.black.withValues(alpha: 0.45),
              borderRadius: BorderRadius.circular(10),
            ),
            child: const Text(
              'Radar',
              style: TextStyle(
                color: Colors.white,
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ),
      ],
    );
  }
}

// 49-point simplified Alberta border derived from Natural Earth 1:10m data
// (Ramer-Douglas-Peucker ε=0.05°). Normalised to bounding box
// [48.993–60.0°N, 120.001–109.999°W]: x=0→120°W, x=1→110°W, y=0→60°N, y=1→49°N.
const List<Offset> _kAlbertaNorm = [
  Offset(1.0, 1.0),
  Offset(0.5936, 1.0),
  Offset(0.5846, 0.9859),
  Offset(0.5624, 0.9807),
  Offset(0.5422, 0.9635),
  Offset(0.5424, 0.9488),
  Offset(0.5256, 0.9459),
  Offset(0.5375, 0.9284),
  Offset(0.5339, 0.9026),
  Offset(0.5225, 0.8763),
  Offset(0.5, 0.8573),
  Offset(0.478, 0.8585),
  Offset(0.4665, 0.8426),
  Offset(0.4354, 0.8311),
  Offset(0.4428, 0.8267),
  Offset(0.438, 0.8203),
  Offset(0.3743, 0.7891),
  Offset(0.3705, 0.7767),
  Offset(0.3424, 0.7591),
  Offset(0.3329, 0.7444),
  Offset(0.3063, 0.7522),
  Offset(0.2682, 0.7102),
  Offset(0.241, 0.7149),
  Offset(0.2247, 0.7086),
  Offset(0.2179, 0.7014),
  Offset(0.2264, 0.6912),
  Offset(0.2009, 0.6828),
  Offset(0.1774, 0.6931),
  Offset(0.1793, 0.683),
  Offset(0.1653, 0.6708),
  Offset(0.1695, 0.6652),
  Offset(0.158, 0.6504),
  Offset(0.1377, 0.6462),
  Offset(0.1329, 0.6328),
  Offset(0.1224, 0.6311),
  Offset(0.1249, 0.6255),
  Offset(0.1151, 0.6193),
  Offset(0.1004, 0.6144),
  Offset(0.0972, 0.6237),
  Offset(0.0738, 0.6179),
  Offset(0.0608, 0.6028),
  Offset(0.0359, 0.6038),
  Offset(0.0096, 0.5885),
  Offset(0.0074, 0.5801),
  Offset(0.0268, 0.5793),
  Offset(0.0, 0.5612),
  Offset(0.0001, 0.0),
  Offset(0.9999, 0.0),
  Offset(1.0, 1.0),
];

class _AlbertaShapeClipper extends CustomClipper<ui.Path> {
  const _AlbertaShapeClipper();

  static ui.Path _build(Size s) {
    final path = ui.Path();
    for (var i = 0; i < _kAlbertaNorm.length; i++) {
      final pt = _kAlbertaNorm[i];
      final x = pt.dx * s.width;
      final y = pt.dy * s.height;
      i == 0 ? path.moveTo(x, y) : path.lineTo(x, y);
    }
    return path..close();
  }

  @override
  ui.Path getClip(Size size) => _build(size);

  @override
  bool shouldReclip(_AlbertaShapeClipper old) => false;
}

class _AlbertaBorderPainter extends CustomPainter {
  const _AlbertaBorderPainter();

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawPath(
      _AlbertaShapeClipper._build(size),
      ui.Paint()
        ..color = _albertaGold.withValues(alpha: 0.75)
        ..style = ui.PaintingStyle.stroke
        ..strokeWidth = 1.5
        ..strokeJoin = ui.StrokeJoin.miter,
    );
  }

  @override
  bool shouldRepaint(_AlbertaBorderPainter old) => false;
}

class _RadarViewerSheet extends StatefulWidget {
  const _RadarViewerSheet({
    required this.timelineFuture,
    required this.location,
  });

  final Future<_RadarTimeline> timelineFuture;
  final _SavedLocation location;

  @override
  State<_RadarViewerSheet> createState() => _RadarViewerSheetState();
}

class _RadarViewerSheetState extends State<_RadarViewerSheet> {
  Timer? _timer;
  int _frameIndex = 0;
  bool _playing = false;

  /// The resolved timeline.
  ///
  /// This is held in state rather than read out of a FutureBuilder snapshot
  /// inside build(). The previous version wrote the frame count from build()
  /// and read it from the playback timer, so a rebuild landing between two
  /// ticks could advance the index against a stale count.
  _RadarTimeline? _timeline;
  bool _resolving = true;

  List<_RadarFrame> get _frames => _timeline?.frames ?? const [];

  @override
  void initState() {
    super.initState();
    widget.timelineFuture
        .then((timeline) {
          if (!mounted) return;
          setState(() {
            _timeline = timeline;
            _resolving = false;
            _frameIndex = timeline.frames.isEmpty
                ? 0
                : timeline.frames.length - 1;
          });
          // Auto-play the loop as soon as the frames are ready.
          if (timeline.frames.length > 1) _startPlaying();
        })
        .catchError((Object _) {
          if (!mounted) return;
          setState(() {
            _timeline = const _RadarTimeline(frames: []);
            _resolving = false;
          });
        });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  void _startPlaying() {
    _timer?.cancel();
    if (_frames.length < 2) return;
    setState(() => _playing = true);
    _timer = Timer.periodic(const Duration(milliseconds: 800), (_) {
      if (!mounted) return;
      final count = _frames.length;
      if (count < 2) return;
      setState(() => _frameIndex = (_frameIndex + 1) % count);
    });
  }

  void _stopPlaying() {
    _timer?.cancel();
    setState(() => _playing = false);
  }

  void _togglePlay() {
    if (_playing) {
      _stopPlaying();
    } else {
      _startPlaying();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        color: Color(0xFF071F45),
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      child: Builder(
        builder: (context) {
          if (_resolving) {
            return const Center(child: CircularProgressIndicator());
          }

          final frames = _frames;
          if (frames.isEmpty) {
            return const Center(
              child: Text(
                'Radar temporarily unavailable.',
                style: TextStyle(color: Colors.white70),
              ),
            );
          }
          if (_frameIndex >= frames.length) {
            _frameIndex = frames.length - 1;
          }
          final frame = frames[_frameIndex];
          final dt = frame.utc.toLocal();

          return Column(
            children: [
              const SizedBox(height: 8),
              Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: Colors.white30,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 10),
                child: Row(
                  children: [
                    const Icon(Icons.radar, color: Colors.white),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'Radar • ${widget.location.name}, ${widget.location.province}',
                        style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.w700,
                          fontSize: 16,
                        ),
                      ),
                    ),
                    if (frame.forecast) ...[
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 3,
                        ),
                        decoration: BoxDecoration(
                          color: _albertaGold,
                          borderRadius: BorderRadius.circular(999),
                        ),
                        child: const Text(
                          'FORECAST',
                          style: TextStyle(
                            color: _albertaBlue,
                            fontWeight: FontWeight.w800,
                            fontSize: 11,
                            letterSpacing: 0.5,
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                    ],
                    Text(
                      '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}',
                      style: const TextStyle(color: Colors.white70),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: FlutterMap(
                  options: MapOptions(
                    initialCenter: LatLng(
                      widget.location.latitude,
                      widget.location.longitude,
                    ),
                    initialZoom: 8,
                    minZoom: 4,
                    maxZoom: 11,
                  ),
                  children: [
                    // Base map without labels, so town names and highways can
                    // sit on top of the radar instead of being hidden under it.
                    TileLayer(
                      urlTemplate:
                          'https://{s}.basemaps.cartocdn.com/dark_nolabels/{z}/{x}/{y}.png',
                      subdomains: const ['a', 'b', 'c'],
                      maxNativeZoom: 19,
                      userAgentPackageName: 'ca.alberta.weather',
                    ),
                    // Cross-dissolve each frame into the next so the loop reads
                    // smoothly instead of hard-cutting between steps.
                    _radarTileLayer(
                      frame,
                      tileDisplay: const TileDisplay.fadeIn(
                        duration: Duration(milliseconds: 500),
                      ),
                    ),
                    // Labels (town names, highways) painted above the radar.
                    TileLayer(
                      urlTemplate:
                          'https://{s}.basemaps.cartocdn.com/dark_only_labels/{z}/{x}/{y}.png',
                      subdomains: const ['a', 'b', 'c'],
                      maxNativeZoom: 19,
                      userAgentPackageName: 'ca.alberta.weather',
                    ),
                  ],
                ),
              ),
              // ECCC requires attribution on GeoMet data. It sits on the radar
              // surface itself, not in the portfolio footer, which is a
              // separate commercial element under Ad-Free.
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 0),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    _timeline?.attribution ?? _radarAttribution,
                    style: const TextStyle(
                      color: Colors.white38,
                      fontSize: 11,
                    ),
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(10, 4, 10, 16),
                child: Row(
                  children: [
                    IconButton(
                      onPressed: _togglePlay,
                      icon: Icon(
                        _playing ? Icons.pause_circle : Icons.play_circle,
                        color: Colors.white,
                        size: 34,
                      ),
                    ),
                    Expanded(
                      child: Slider(
                        value: _frameIndex.toDouble(),
                        min: 0,
                        max: (frames.length - 1).toDouble(),
                        divisions: frames.length > 1 ? frames.length - 1 : 1,
                        activeColor: _albertaGold,
                        onChanged: (value) {
                          _timer?.cancel();
                          setState(() {
                            _playing = false;
                            _frameIndex = value.round();
                          });
                        },
                      ),
                    ),
                  ],
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _MetricsGrid extends StatelessWidget {
  const _MetricsGrid({required this.current});

  final Map<String, dynamic> current;

  @override
  Widget build(BuildContext context) {
    final metrics = [
      ('Humidity', '${_fmt(current['humidity'])}%'),
      ('Wind', '${_fmt(current['wind_speed'])} km/h'),
      (
        'Direction',
        '${current['wind_direction_compass'] ?? '-'} '
            '(${_fmt(current['wind_direction_degrees'])}°)',
      ),
      ('UV Index', _fmt(current['uv_index'])),
    ];

    return GridView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      padding: EdgeInsets.zero,
      itemCount: metrics.length,
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 4,
        crossAxisSpacing: 8,
        mainAxisSpacing: 8,
        mainAxisExtent: 68,
      ),
      itemBuilder: (context, index) {
        return _MetricCard(label: metrics[index].$1, value: metrics[index].$2);
      },
    );
  }
}

class _MetricCard extends StatelessWidget {
  const _MetricCard({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Card(
      elevation: 0,
      margin: EdgeInsets.zero,
      color: _albertaBlue,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(
                context,
              ).textTheme.labelSmall?.copyWith(color: Colors.white70),
            ),
            const SizedBox(height: 2),
            Text(
              value,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.w700,
                color: Colors.white,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({required this.title});

  final String title;

  @override
  Widget build(BuildContext context) {
    return Text(
      title,
      style: Theme.of(context).textTheme.titleLarge?.copyWith(
        fontWeight: FontWeight.w700,
        color: Colors.white,
      ),
    );
  }
}

class _HourlyTile extends StatelessWidget {
  const _HourlyTile({required this.item, this.onTapUp});

  final Map<String, dynamic> item;
  final ValueChanged<Offset>? onTapUp;

  @override
  Widget build(BuildContext context) {
    final pop = item['precipitation_probability'];
    final popValue = _toDouble(pop);
    final hasPrecip = popValue != null && popValue > 0;

    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTapUp: (details) => onTapUp?.call(details.globalPosition),
        child: Ink(
          width: 112,
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(14),
            color: _albertaBlue,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Text(
                '${item['label'] ?? '-'}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: Theme.of(
                  context,
                ).textTheme.labelLarge?.copyWith(color: Colors.white),
              ),
              Expanded(
                child: Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      _weatherGlyph(
                        '${item['weather'] ?? ''}',
                        item['weather_code'],
                        item['is_daylight'],
                        _scaledGlyphSize(26),
                        item['time'],
                      ),
                      const SizedBox(height: 6),
                      Text(
                        '${_fmt(item['temperature'])}°C',
                        style: Theme.of(context).textTheme.titleLarge?.copyWith(
                          fontWeight: FontWeight.w700,
                          color: Colors.white,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              if (hasPrecip)
                Text(
                  'Rain ${_fmtPercent(pop)}',
                  style: Theme.of(
                    context,
                  ).textTheme.labelSmall?.copyWith(color: Colors.white70),
                )
              else
                const SizedBox(height: 16),
            ],
          ),
        ),
      ),
    );
  }
}

class _InlineHourlyDetailsCard extends StatelessWidget {
  const _InlineHourlyDetailsCard({required this.item});

  final Map<String, dynamic> item;

  @override
  Widget build(BuildContext context) {
    final directionCompass = '${item['wind_direction_compass'] ?? '-'}';
    final directionDegrees = _fmt(item['wind_direction_degrees']);
    final direction = directionDegrees == '-'
        ? directionCompass
        : '$directionCompass ($directionDegrees°)';

    final metrics = [
      ('Feels like', '${_fmt(item['apparent_temperature'])}°C'),
      ('Humidity', _fmtPercent(item['humidity'])),
      ('Wind', '${_fmt(item['wind_speed'])} km/h'),
      ('Direction', direction),
      ('UV Index', _fmt(item['uv_index'])),
      ('Rain chance', _fmtPercent(item['precipitation_probability'])),
    ];

    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
      decoration: BoxDecoration(
        color: const Color(0xF20A2E66),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Colors.white24),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              _weatherGlyph(
                '${item['weather'] ?? ''}',
                item['weather_code'],
                item['is_daylight'],
                _scaledGlyphSize(30),
                item['time'],
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '${item['label'] ?? 'Hourly details'}',
                      style: Theme.of(context).textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.w700,
                        color: Colors.white,
                      ),
                    ),
                    Text(
                      '${item['weather'] ?? '-'} • ${_fmt(item['temperature'])}°C',
                      style: Theme.of(
                        context,
                      ).textTheme.bodyMedium?.copyWith(color: Colors.white70),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          GridView.builder(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            itemCount: metrics.length,
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 2,
              crossAxisSpacing: 8,
              mainAxisSpacing: 8,
              childAspectRatio: 2.2,
            ),
            itemBuilder: (context, index) {
              return _MetricCard(
                label: metrics[index].$1,
                value: metrics[index].$2,
              );
            },
          ),
        ],
      ),
    );
  }
}

class _DailyForecastRow extends StatelessWidget {
  const _DailyForecastRow({
    required this.item,
    required this.theme,
    this.compact = false,
    this.onTapUp,
  });

  final Map<String, dynamic> item;
  final ThemeData theme;
  final bool compact;
  final ValueChanged<Offset>? onTapUp;

  @override
  Widget build(BuildContext context) {
    final min = _toDouble(item['temperature_min']);
    final max = _toDouble(item['temperature_max']);
    final precipitationChance = _toDouble(
      item['precipitation_probability_max'],
    );
    final precipitationMm = _toDouble(item['precipitation_amount_mm']);
    final weatherText = '${item['weather'] ?? ''}';
    final weatherCode = item['weather_code'];
    final isSnow =
        _isSnowWeatherCode(weatherCode) || _isSnowWeather(weatherText);
    final hasExpectedPrecipitation =
        (precipitationChance != null && precipitationChance > 0) ||
        (precipitationMm != null && precipitationMm > 0);

    return Card(
      elevation: 0,
      color: _albertaBlue,
      margin: const EdgeInsets.only(bottom: 8),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTapUp: (_) {
          final box = context.findRenderObject() as RenderBox?;
          if (box == null) return;
          final topLeft = box.localToGlobal(Offset.zero);
          final center = Offset(
            topLeft.dx + (box.size.width / 2),
            topLeft.dy + (box.size.height / 2),
          );
          onTapUp?.call(center);
        },
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          child: Row(
            children: [
              SizedBox(
                width: compact ? 86 : 96,
                child: Text(
                  '${item['label'] ?? '-'}',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                    color: Colors.white,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Row(
                  children: [
                    _weatherGlyph(
                      '${item['weather'] ?? ''}',
                      item['weather_code'],
                      item['is_daylight'],
                      _scaledGlyphSize(18),
                      item['date'],
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        '${item['weather'] ?? '-'}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: Colors.white,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 10),
              SizedBox(
                width: 74,
                child: hasExpectedPrecipitation
                    ? Column(
                        crossAxisAlignment: CrossAxisAlignment.end,
                        children: [
                          Text(
                            '${isSnow ? '❄️' : '💧'} ${_fmt(precipitationChance)}%',
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: Colors.white,
                              fontWeight: FontWeight.w600,
                              fontSize:
                                  (theme.textTheme.bodySmall?.fontSize ?? 12) *
                                  0.9,
                            ),
                          ),
                          Text(
                            isSnow
                                ? '${_fmtCmFromMm(precipitationMm)} cm'
                                : '${_fmtMm(precipitationMm)} mm',
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: Colors.white70,
                            ),
                          ),
                        ],
                      )
                    : const SizedBox.shrink(),
              ),
              const SizedBox(width: 10),
              SizedBox(
                width: 68,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Text(
                      'H ${_fmt(max)}°C',
                      style: theme.textTheme.bodyMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                        color: Colors.white,
                      ),
                    ),
                    Text(
                      'L ${_fmt(min)}°C',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: Colors.white70,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _InlineDayDetailsCard extends StatelessWidget {
  const _InlineDayDetailsCard({required this.day, required this.dayparts});

  final Map<String, dynamic> day;
  final Map<String, dynamic>? dayparts;

  @override
  Widget build(BuildContext context) {
    final periods =
        (dayparts?['periods'] as Map<String, dynamic>? ?? <String, dynamic>{});

    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.fromLTRB(10, 8, 10, 6),
      decoration: BoxDecoration(
        color: const Color(0xF20A2E66),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Colors.white24),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '${day['label'] ?? day['date'] ?? 'Day details'}',
            style: Theme.of(context).textTheme.titleMedium?.copyWith(
              color: Colors.white,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            '${day['weather'] ?? '-'} • H ${_fmt(day['temperature_max'])}°C / L ${_fmt(day['temperature_min'])}°C',
            style: Theme.of(
              context,
            ).textTheme.bodySmall?.copyWith(color: Colors.white70),
          ),
          const SizedBox(height: 8),
          _DayPeriodTile(
            title: 'Overnight',
            data: periods['overnight'] as Map<String, dynamic>?,
          ),
          _DayPeriodTile(
            title: 'Morning',
            data: periods['morning'] as Map<String, dynamic>?,
          ),
          _DayPeriodTile(
            title: 'Afternoon',
            data: periods['afternoon'] as Map<String, dynamic>?,
          ),
          _DayPeriodTile(
            title: 'Evening',
            data: periods['evening'] as Map<String, dynamic>?,
          ),
        ],
      ),
    );
  }
}

class _DayPeriodTile extends StatelessWidget {
  const _DayPeriodTile({required this.title, required this.data});

  final String title;
  final Map<String, dynamic>? data;

  @override
  Widget build(BuildContext context) {
    final weather = '${data?['weather'] ?? 'No detailed data'}';
    final weatherCode = data?['weather_code'];
    final amountMm = _toDouble(data?['precipitation_amount_mm']);
    final isSnow =
        _isSnowWeatherCode(weatherCode) ||
        _isSnowWeather(weather.toLowerCase());
    final hasPrecipAmount = amountMm != null && amountMm > 0;
    final amountLabel = hasPrecipAmount
        ? isSnow
              ? '${_fmtCmFromMm(amountMm)} cm'
              : '${_fmtMm(amountMm)} mm'
        : '';

    return Card(
      color: _albertaBlue,
      elevation: 0,
      margin: const EdgeInsets.only(bottom: 8),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        child: Row(
          children: [
            SizedBox(
              width: 88,
              child: Text(
                title,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: Colors.white,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            SizedBox(
              width: _scaledGlyphSize(30),
              child: _weatherGlyph(
                weather,
                weatherCode,
                data?['is_daylight'],
                _scaledGlyphSize(20),
                data?['time'] ?? data?['date'],
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                weather,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(
                  context,
                ).textTheme.bodySmall?.copyWith(color: Colors.white70),
              ),
            ),
            const SizedBox(width: 8),
            Text(
              '${hasPrecipAmount ? '${isSnow ? '❄️' : '💧'} $amountLabel  ' : ''}'
              'H ${_fmt(data?['temperature_max'])}°  '
              'L ${_fmt(data?['temperature_min'])}°',
              textAlign: TextAlign.right,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Colors.white,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

String _fmtClockFromIso(dynamic value) {
  final raw = '$value'.trim();
  if (raw.isEmpty || raw == 'null') {
    return '--';
  }
  try {
    final parsed = DateTime.parse(raw);
    final hour24 = parsed.hour;
    final minute = parsed.minute.toString().padLeft(2, '0');
    final hour12 = hour24 == 0 ? 12 : (hour24 > 12 ? hour24 - 12 : hour24);
    final suffix = hour24 >= 12 ? 'PM' : 'AM';
    return '$hour12:$minute $suffix';
  } catch (_) {
    return raw;
  }
}

String _fmt(dynamic value) {
  final parsed = _toDouble(value);
  if (parsed == null) {
    return '-';
  }
  return parsed.round().toString();
}

String _fmtPercent(dynamic value) {
  final formatted = _fmt(value);
  return formatted == '-' ? '-' : '$formatted%';
}

String _fmtMm(dynamic value) {
  final parsed = _toDouble(value);
  if (parsed == null) {
    return '-';
  }
  final oneDecimal = parsed.toStringAsFixed(1);
  return oneDecimal.endsWith('.0')
      ? oneDecimal.substring(0, oneDecimal.length - 2)
      : oneDecimal;
}

String _fmtCmFromMm(dynamic value) {
  final parsed = _toDouble(value);
  if (parsed == null) {
    return '-';
  }
  final cm = parsed / 10.0;
  final oneDecimal = cm.toStringAsFixed(1);
  return oneDecimal.endsWith('.0')
      ? oneDecimal.substring(0, oneDecimal.length - 2)
      : oneDecimal;
}

double? _toDouble(dynamic value) {
  if (value == null) {
    return null;
  }
  if (value is num) {
    return value.toDouble();
  }
  return double.tryParse('$value');
}

bool _isSnowWeatherCode(dynamic weatherCode) {
  final code = weatherCode is int ? weatherCode : int.tryParse('$weatherCode');
  if (code == null) return false;
  return {71, 73, 75, 77, 85, 86}.contains(code);
}

bool _isSnowWeather(String weather) {
  final w = weather.toLowerCase();
  return w.contains('snow') || w.contains('blizzard') || w.contains('sleet');
}

enum _WeatherGlyphKind {
  thunder,
  snow,
  rain,
  fog,
  overcast,
  partlyCloudyDay,
  partlyCloudyNight,
  clearDay,
  clearNight,
}

const double _glyphScale = 1.35;

double _scaledGlyphSize(double baseSize) => baseSize * _glyphScale;

Widget _weatherGlyph(
  String weather, [
  dynamic weatherCode,
  dynamic isDaylightValue,
  double size = 20,
  dynamic timeValue,
]) {
  final kind = _resolveWeatherGlyphKind(weather, weatherCode, isDaylightValue);
  return _buildWeatherGlyph(kind: kind, size: size, timeValue: timeValue);
}

_WeatherGlyphKind _resolveWeatherGlyphKind(
  String weather,
  dynamic weatherCode,
  dynamic isDaylightValue,
) {
  final w = weather.toLowerCase();
  final code = weatherCode is int ? weatherCode : int.tryParse('$weatherCode');
  final isDaylight = isDaylightValue is bool ? isDaylightValue : null;

  final isThunder =
      w.contains('thunder') || code == 95 || code == 96 || code == 99;
  final isSnow = w.contains('snow') || _isSnowWeatherCode(code);
  final isRain =
      w.contains('rain') ||
      w.contains('drizzle') ||
      {51, 53, 55, 56, 57, 61, 63, 65, 66, 67, 80, 81, 82}.contains(code);
  final isFog = w.contains('fog') || code == 45 || code == 48;
  final isOvercast = w.contains('overcast') || code == 3;
  final isPartlyCloudy =
      w.contains('partly cloudy') || w.contains('cloud') || code == 2;
  final isMainlyClear = w.contains('mainly clear') || code == 1;
  final isClear = w.contains('clear') || code == 0;

  if (isThunder) return _WeatherGlyphKind.thunder;
  if (isSnow) return _WeatherGlyphKind.snow;
  if (isRain) return _WeatherGlyphKind.rain;
  if (isFog) return _WeatherGlyphKind.fog;
  if (isOvercast) return _WeatherGlyphKind.overcast;

  if (isDaylight == false) {
    if (isPartlyCloudy) return _WeatherGlyphKind.partlyCloudyNight;
    if (isMainlyClear || isClear) return _WeatherGlyphKind.clearNight;
    return _WeatherGlyphKind.clearNight;
  }

  if (isPartlyCloudy) return _WeatherGlyphKind.partlyCloudyDay;
  if (isMainlyClear || isClear) return _WeatherGlyphKind.clearDay;
  return _WeatherGlyphKind.partlyCloudyDay;
}

int _moonPhaseIndex(dynamic timeValue) {
  final when = _parseWeatherDateTime(timeValue) ?? DateTime.now().toUtc();
  const synodicMonthDays = 29.53058867;
  final referenceNewMoon = DateTime.utc(2000, 1, 6, 18, 14);
  final daysSinceReference =
      when.toUtc().difference(referenceNewMoon).inSeconds / 86400.0;

  var cycleDays = daysSinceReference % synodicMonthDays;
  if (cycleDays < 0) cycleDays += synodicMonthDays;

  final phase = cycleDays / synodicMonthDays;
  return ((phase * 8).round()) % 8;
}

DateTime? _parseWeatherDateTime(dynamic value) {
  if (value == null) return null;
  if (value is DateTime) return value;

  final raw = '$value'.trim();
  if (raw.isEmpty || raw == 'null') return null;

  final parsed = DateTime.tryParse(raw);
  if (parsed != null) return parsed;

  if (RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(raw)) {
    return DateTime.tryParse('${raw}T12:00:00Z');
  }

  return null;
}

const Map<_WeatherGlyphKind, String> _weatherGlyphAssetPaths = {
  _WeatherGlyphKind.thunder: 'assets/glyphs/thunder.png',
  _WeatherGlyphKind.snow: 'assets/glyphs/snow.png',
  _WeatherGlyphKind.rain: 'assets/glyphs/rain.png',
  _WeatherGlyphKind.fog: 'assets/glyphs/fog.png',
  _WeatherGlyphKind.overcast: 'assets/glyphs/overcast.png',
  _WeatherGlyphKind.partlyCloudyDay: 'assets/glyphs/partly_cloudy_day.png',
  _WeatherGlyphKind.clearDay: 'assets/glyphs/clear_day.png',
};

Widget _buildWeatherGlyph({
  required _WeatherGlyphKind kind,
  required double size,
  dynamic timeValue,
}) {
  final phaseIndex = _moonPhaseIndex(timeValue);
  final assetPath = switch (kind) {
    _WeatherGlyphKind.clearNight => 'assets/glyphs/clear_night_$phaseIndex.png',
    _WeatherGlyphKind.partlyCloudyNight =>
      'assets/glyphs/partly_cloudy_night_$phaseIndex.png',
    _ => _weatherGlyphAssetPaths[kind],
  };

  if (assetPath == null) {
    return _buildWeatherGlyphFallback(kind: kind, size: size);
  }

  return Image.asset(
    assetPath,
    width: size,
    height: size,
    fit: BoxFit.contain,
    filterQuality: FilterQuality.high,
    errorBuilder: (context, error, stackTrace) {
      return _buildWeatherGlyphFallback(kind: kind, size: size);
    },
  );
}

Widget _buildWeatherGlyphFallback({
  required _WeatherGlyphKind kind,
  required double size,
}) {
  switch (kind) {
    case _WeatherGlyphKind.thunder:
      return _detailedIcon(
        icon: Icons.thunderstorm_rounded,
        size: size,
        baseColor: const Color(0xFFFFD76A),
        highlightColor: const Color(0xFFFFF2BE),
      );
    case _WeatherGlyphKind.snow:
      return _detailedIcon(
        icon: Icons.ac_unit_rounded,
        size: size,
        baseColor: const Color(0xFFD4EDFF),
        highlightColor: Colors.white,
      );
    case _WeatherGlyphKind.rain:
      return _detailedIcon(
        icon: Icons.grain_rounded,
        size: size,
        baseColor: const Color(0xFFA7DAFF),
        highlightColor: const Color(0xFFE6F6FF),
      );
    case _WeatherGlyphKind.fog:
      return _wispyFogGlyph(size: size);
    case _WeatherGlyphKind.overcast:
      return _detailedIcon(
        icon: Icons.cloud_rounded,
        size: size,
        baseColor: const Color(0xFFDCE7FF),
        highlightColor: const Color(0xFFFFFFFF),
      );
    case _WeatherGlyphKind.partlyCloudyDay:
      return _sunCloudGlyph(size: size);
    case _WeatherGlyphKind.partlyCloudyNight:
      return _cloudMoonGlyph(size: size);
    case _WeatherGlyphKind.clearDay:
      return _detailedIcon(
        icon: Icons.wb_sunny_rounded,
        size: size,
        baseColor: const Color(0xFFFFD76A),
        highlightColor: const Color(0xFFFFF0B2),
      );
    case _WeatherGlyphKind.clearNight:
      return _moonStarGlyph(size: size);
  }
}

Widget _detailedIcon({
  required IconData icon,
  required double size,
  required Color baseColor,
  required Color highlightColor,
}) {
  return SizedBox(
    width: size,
    height: size,
    child: Stack(
      clipBehavior: Clip.none,
      children: [
        Positioned(
          left: size * 0.04,
          top: size * 0.06,
          child: Icon(
            icon,
            size: size,
            color: Colors.black.withValues(alpha: 0.35),
          ),
        ),
        Icon(icon, size: size, color: baseColor),
        Positioned(
          left: size * 0.015,
          top: -size * 0.02,
          child: Icon(
            icon,
            size: size * 0.9,
            color: highlightColor.withValues(alpha: 0.55),
          ),
        ),
      ],
    ),
  );
}

Widget _wispyFogGlyph({required double size}) {
  Widget fogBand(double widthFactor, double top, double opacity) {
    return Positioned(
      top: top,
      left: size * ((1.45 - widthFactor) / 2),
      child: Container(
        width: size * widthFactor,
        height: size * 0.11,
        decoration: BoxDecoration(
          gradient: LinearGradient(
            colors: [
              const Color(0xFFE3EEFF).withValues(alpha: opacity),
              Colors.white.withValues(alpha: opacity * 0.9),
            ],
          ),
          borderRadius: BorderRadius.circular(size),
        ),
      ),
    );
  }

  return SizedBox(
    width: size * 1.45,
    height: size * 1.22,
    child: Stack(
      clipBehavior: Clip.none,
      children: [
        Positioned(
          top: -size * 0.02,
          left: size * 0.23,
          child: _detailedIcon(
            icon: Icons.cloud_rounded,
            size: size * 0.9,
            baseColor: const Color(0xFFDCE7FF),
            highlightColor: Colors.white,
          ),
        ),
        fogBand(1.35, size * 0.57, 0.88),
        fogBand(1.05, size * 0.74, 0.75),
        fogBand(1.2, size * 0.91, 0.62),
      ],
    ),
  );
}

Widget _sunCloudGlyph({required double size}) {
  return SizedBox(
    width: size * 1.15,
    height: size,
    child: Stack(
      clipBehavior: Clip.none,
      children: [
        Positioned(
          left: size * 0.2,
          top: 0,
          child: _detailedIcon(
            icon: Icons.wb_sunny_rounded,
            size: size * 0.74,
            baseColor: const Color(0xFFFFD76A),
            highlightColor: const Color(0xFFFFF1BA),
          ),
        ),
        Positioned(
          left: 0,
          top: size * 0.2,
          child: _detailedIcon(
            icon: Icons.cloud_rounded,
            size: size,
            baseColor: const Color(0xFFDCE7FF),
            highlightColor: Colors.white,
          ),
        ),
      ],
    ),
  );
}

Widget _moonStarGlyph({required double size}) {
  return SizedBox(
    width: size * 1.15,
    height: size,
    child: Stack(
      clipBehavior: Clip.none,
      children: [
        Positioned(
          left: 0,
          top: 0,
          child: _detailedIcon(
            icon: Icons.nightlight_round,
            size: size,
            baseColor: const Color(0xFFD5DEFF),
            highlightColor: const Color(0xFFF4F7FF),
          ),
        ),
        Positioned(
          left: size * 0.35,
          top: size * 0.08,
          child: _detailedIcon(
            icon: Icons.star_rounded,
            size: size * 0.28,
            baseColor: const Color(0xFFFFE69A),
            highlightColor: const Color(0xFFFFF3CB),
          ),
        ),
        Positioned(
          left: size * 0.22,
          top: -size * 0.01,
          child: _detailedIcon(
            icon: Icons.star_rounded,
            size: size * 0.14,
            baseColor: const Color(0xFFFFE69A),
            highlightColor: const Color(0xFFFFF3CB),
          ),
        ),
        Positioned(
          left: size * 0.52,
          top: size * 0.4,
          child: _detailedIcon(
            icon: Icons.star_rounded,
            size: size * 0.18,
            baseColor: const Color(0xFFFFE69A),
            highlightColor: const Color(0xFFFFF3CB),
          ),
        ),
      ],
    ),
  );
}

Widget _cloudMoonGlyph({required double size}) {
  return SizedBox(
    width: size * 1.2,
    height: size,
    child: Stack(
      clipBehavior: Clip.none,
      children: [
        Positioned(
          left: size * 0.24,
          top: 0,
          child: _moonStarGlyph(size: size * 0.9),
        ),
        Positioned(
          left: 0,
          top: size * 0.2,
          child: _detailedIcon(
            icon: Icons.cloud_rounded,
            size: size,
            baseColor: const Color(0xFFDCE7FF),
            highlightColor: Colors.white,
          ),
        ),
      ],
    ),
  );
}

class _BuiltByFooter extends StatelessWidget {
  const _BuiltByFooter();

  static const _siteUrl = 'https://hakoojaservices.ca';

  // Colours lifted from hako-oja-react cta-metal / hammered-copper-surface
  static const _copperBorder = Color(0xD9D48A61);   // rgba(212,138,97,0.85)
  static const _copperText   = Color(0xFFE6AE84);   // --copper-1
  static const _copperGlow   = Color(0x40D48A61);   // rgba(212,138,97,0.25)

  Future<void> _launch() async {
    final uri = Uri.parse(_siteUrl);
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 32, bottom: 12),
      child: Center(
        child: GestureDetector(
          onTap: _launch,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(16),
            child: BackdropFilter(
              filter: ui.ImageFilter.blur(sigmaX: 10, sigmaY: 10),
              child: Container(
                width: 260,
                padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 20),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(16),
                  gradient: const LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [
                      Color(0xE8251510),
                      Color(0xF01A0D08),
                      Color(0xF6100705),
                      Color(0xFC080402),
                    ],
                    stops: [0.0, 0.38, 0.70, 1.0],
                  ),
                  border: Border.all(color: _copperBorder, width: 1.2),
                  boxShadow: const [
                    BoxShadow(color: _copperGlow, blurRadius: 24, spreadRadius: 2),
                  ],
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      'This application was built by',
                      style: TextStyle(
                        fontSize: 11,
                        letterSpacing: 0.7,
                        color: _copperText,
                        shadows: const [
                          Shadow(color: Color(0x996F3524), blurRadius: 12),
                        ],
                      ),
                    ),
                    const SizedBox(height: 14),
                    SvgPicture.asset(
                      'assets/images/hakooja_logo.svg',
                      height: 112,
                      fit: BoxFit.contain,
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
