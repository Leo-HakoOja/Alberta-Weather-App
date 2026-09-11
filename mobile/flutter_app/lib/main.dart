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

import 'radar_engine.dart';
import 'radar_store.dart';

/// ECCC requires attribution on GeoMet data, on the radar surface itself.
const _radarAttribution = 'Radar: ECCC';
const _forecastAttribution = 'Forecast: ECCC HRDPS model, not observed radar';

/// Natural Resources Canada's Canada Base Map (Transportation), Web Mercator.
///
/// Replaced CARTO, which began watermarking keyless tiles "API KEY REQUIRED" in
/// late August 2026. NRCan needs no key, is free under the Open Government
/// Licence - Canada, and publishes geometry and labels as separate layers, so
/// town names can still sit above the radar. It covers Canada only; south of
/// the 49th the tiles are blank and the dark filter renders them as plain
/// background. ArcGIS tile order is {z}/{y}/{x}.
const _nrcanBaseUrl =
    'https://maps-cartes.services.geo.ca/server2_serveur2/rest/services/'
    'BaseMaps/CBMT_CBCT_GEOM_3857/MapServer/tile/{z}/{y}/{x}';
const _nrcanLabelsUrl =
    'https://maps-cartes.services.geo.ca/server2_serveur2/rest/services/'
    'BaseMaps/CBMT_TXT_3857/MapServer/tile/{z}/{y}/{x}';

/// Required by the Open Government Licence - Canada, in its own wording.
const _basemapAttribution =
    'Basemap © Natural Resources Canada. Contains information licensed under '
    'the Open Government Licence – Canada.';

/// NRCan's map is light. Greyscale it, invert the luminance and dim it, so it
/// reads as a neutral dark map under the radar. A plain colour invert (what
/// flutter_map's darkModeTileBuilder does) turns every lake and river orange.
const _basemapDarkFilter = ColorFilter.matrix(<double>[
  -0.16445, -0.32285, -0.0627, 0, 152.25, //
  -0.16445, -0.32285, -0.0627, 0, 152.25, //
  -0.16445, -0.32285, -0.0627, 0, 152.25, //
  0, 0, 0, 1, 0, //
]);

/// Labels: greyscale and invert, so dark text turns light and its light halo
/// turns dark. Not dimmed, so names stay readable over the radar.
const _labelsDarkFilter = ColorFilter.matrix(<double>[
  -0.299, -0.587, -0.114, 0, 255, //
  -0.299, -0.587, -0.114, 0, 255, //
  -0.299, -0.587, -0.114, 0, 255, //
  0, 0, 0, 1, 0, //
]);

/// The NRCan base geometry, darkened.
///
/// Filtered per tile through `tileBuilder`: flutter_map 7.0.2 exposes no
/// layer-wide container hook on TileLayer, and at the 20 to 30 tiles on
/// screen the per-tile cost is negligible.
Widget _basemapLayer() => TileLayer(
  urlTemplate: _nrcanBaseUrl,
  userAgentPackageName: 'ca.alberta.weather',
  tileBuilder: (context, tile, _) =>
      ColorFiltered(colorFilter: _basemapDarkFilter, child: tile),
);

/// NRCan place names and highway shields, painted above the radar.
Widget _basemapLabelsLayer() => TileLayer(
  urlTemplate: _nrcanLabelsUrl,
  userAgentPackageName: 'ca.alberta.weather',
  tileBuilder: (context, tile, _) =>
      ColorFiltered(colorFilter: _labelsDarkFilter, child: tile),
);

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


/// Started before anything else, so radar-ready is measured from launch.
final Stopwatch _launchClock = Stopwatch()..start();

/// Codemagic's build counter, passed in with --dart-define. Empty locally.
const _buildNumber = String.fromEnvironment('BUILD_NUMBER');

void main() {
  _launchClock.elapsed; // touch: top-level finals initialise lazily
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
  late final RadarStore _radar;
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
    // Prefetch the whole radar window in the background from launch, so the
    // sheet opens onto frames already held (ADR 0010).
    _radar = RadarStore(
      apiBase: _apiOrigin(),
      launchClock: _launchClock,
      build: _buildNumber.isEmpty ? null : _buildNumber,
    );
    _radar.start();
    _radar.refreshWarnings();
    _initLocation();
  }

  @override
  void dispose() {
    _radar.dispose();
    super.dispose();
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

  /// Backend origin for the radar endpoints, from the same configured URL.
  Uri _apiOrigin() {
    final api = Uri.parse(_resolvedApiUrl());
    return Uri(
      scheme: api.scheme,
      host: api.host,
      port: api.hasPort ? api.port : null,
      path: '/',
    );
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

  Future<void> _refresh() async {
    setState(() {
      _weatherFuture = _fetchWeather();
    });
    _radar.start();
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
            radar: _radar,
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
                      radar: _radar,
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
    required this.radar,
    required this.onRadarTap,
    required this.sources,
  });

  final Map<String, dynamic> location;
  final Map<String, dynamic> current;
  final _SavedLocation selectedLocation;
  final Map<String, dynamic>? todayForecast;
  final RadarStore radar;
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
                          '${_fmt(meanLiveTemperature(sources) ?? current['temperature'])}°C',
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
                          child: _RadarPreviewCard(radar: radar),
                        ),
                        CustomPaint(painter: const _AlbertaBorderPainter()),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),
          ],
        ),
      ),
    );
  }
}

/// The hero temperature: the mean of every source that answered with one.
///
/// Per-source temperatures stay in the response (ADR 0001 keeps all three in
/// the data layer) but are no longer rendered; the card shows one number.
/// A source is live when it reported no error and a numeric current
/// temperature. Null when none did, so the caller can fall back.
@visibleForTesting
double? meanLiveTemperature(List<dynamic> sources) {
  final temps = <double>[];
  for (final raw in sources) {
    if (raw is! Map) continue;
    if (raw['error'] != null) continue;
    final current = raw['current'];
    if (current is! Map) continue;
    final temp = current['temperature'];
    if (temp is num && temp.isFinite) temps.add(temp.toDouble());
  }
  if (temps.isEmpty) return null;
  return temps.reduce((a, b) => a + b) / temps.length;
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

/// The hero card's Alberta cutout: the newest real radar scan, still.
class _RadarPreviewCard extends StatefulWidget {
  const _RadarPreviewCard({required this.radar});

  final RadarStore radar;

  @override
  State<_RadarPreviewCard> createState() => _RadarPreviewCardState();
}

class _RadarPreviewCardState extends State<_RadarPreviewCard> {
  ui.Image? _image;
  String? _shownKey;
  String? _pendingKey;

  @override
  void initState() {
    super.initState();
    widget.radar.addListener(_update);
    _update();
  }

  @override
  void dispose() {
    widget.radar.removeListener(_update);
    _image?.dispose();
    super.dispose();
  }

  void _update() {
    final latest = widget.radar.latestObserved;
    final renderer = widget.radar.renderer;
    if (latest == null || renderer == null) return;
    final key = latest.cacheKey;
    if (key == _shownKey || key == _pendingKey) return;
    _pendingKey = key;
    final grid = renderer.grid;
    renderer
        .render(aKey: key)
        .then((rgba) => _imageFromRgba(rgba, grid.width, grid.height))
        .then((image) {
          if (!mounted || _pendingKey != key) {
            image.dispose();
            return;
          }
          setState(() {
            _image?.dispose();
            _image = image;
            _shownKey = key;
          });
        })
        .catchError((Object _) {})
        .whenComplete(() {
          if (_pendingKey == key) _pendingKey = null;
        });
  }

  @override
  Widget build(BuildContext context) {
    final grid = widget.radar.renderer?.grid;
    final image = _image;
    return Stack(
      fit: StackFit.expand,
      children: [
        if (image == null || grid == null)
          Container(
            color: Colors.black.withValues(alpha: 0.25),
            alignment: Alignment.center,
            child: const Icon(Icons.radar, color: Colors.white70, size: 36),
          )
        else
          FlutterMap(
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
              _basemapLayer(),
              _RadarGridLayer(image: image, grid: grid),
              _basemapLabelsLayer(),
            ],
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

Future<ui.Image> _imageFromRgba(Uint8List rgba, int width, int height) {
  final completer = Completer<ui.Image>();
  ui.decodeImageFromPixels(
    rgba,
    width,
    height,
    ui.PixelFormat.rgba8888,
    completer.complete,
  );
  return completer.future;
}

/// One radar frame, drawn on the device and pinned to the map.
///
/// The grid is linear in Web Mercator, the map's own projection, so the image
/// only has to be stretched between its two projected corners to sit on its
/// ground position at every zoom and pan. Wrapped the way flutter_map's own
/// layers are, so rotation follows too.
class _RadarGridLayer extends StatelessWidget {
  const _RadarGridLayer({required this.image, required this.grid});

  final ui.Image? image;
  final RadarGridSpec grid;

  @override
  Widget build(BuildContext context) {
    final image = this.image;
    if (image == null) return const SizedBox.shrink();
    final camera = MapCamera.of(context);
    final nw = camera.project(grid.northWest) - camera.pixelOrigin;
    final se = camera.project(grid.southEast) - camera.pixelOrigin;
    return MobileLayerTransformer(
      child: SizedBox.expand(
        child: CustomPaint(
          painter: _RadarImagePainter(
            image,
            Rect.fromLTRB(nw.x, nw.y, se.x, se.y),
          ),
        ),
      ),
    );
  }
}

class _RadarImagePainter extends CustomPainter {
  const _RadarImagePainter(this.image, this.dst);

  final ui.Image image;
  final Rect dst;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawImageRect(
      image,
      Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble()),
      dst,
      // Bilinear only smooths the drawing of each grid cell on screen. Frame
      // values are never touched by it.
      Paint()..filterQuality = FilterQuality.low,
    );
  }

  @override
  bool shouldRepaint(_RadarImagePainter old) =>
      old.image != image || old.dst != dst;
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
  const _RadarViewerSheet({required this.radar, required this.location});

  final RadarStore radar;
  final _SavedLocation location;

  @override
  State<_RadarViewerSheet> createState() => _RadarViewerSheetState();
}

class _RadarViewerSheetState extends State<_RadarViewerSheet> {
  final MapController _map = MapController();

  /// Real frames held when the schedule was last built, oldest first.
  List<RadarFrameRef> _real = const [];

  /// Real frames plus interpolated ones: what playback steps through.
  List<RadarDisplayFrame> _schedule = const [];
  int _index = 0;

  /// Display index of the newest observed frame, where radar hands to model.
  int? _nowIndex;

  bool _playing = false;
  bool _userPaused = false;
  int _playToken = 0;

  /// Set while a tornado or severe thunderstorm warning overlaps the view, or
  /// while warning status is unknown: real frames only, nothing interpolated.
  bool _realOnly = false;
  String? _realOnlyReason;
  LatLngBounds? _view;

  ui.Image? _shown;
  final Map<String, ui.Image> _images = {};
  final Map<String, Future<ui.Image?>> _inflight = {};
  static const _imageCacheSize = 20;

  bool _showStats = false;

  static const _interpolatedFrameDelay = Duration(milliseconds: 100);
  static const _realFrameDelay = Duration(milliseconds: 600);
  static const _loopHold = Duration(milliseconds: 1200);

  late LatLng _you = LatLng(
    widget.location.latitude,
    widget.location.longitude,
  );

  final DateTime _openedAt = DateTime.now();

  RadarStore get _radar => widget.radar;

  @override
  void initState() {
    super.initState();
    _radar.addListener(_onRadarChanged);
    _rebuildSchedule();
    unawaited(_radar.refreshIfStale());
    _locateYou();
    WidgetsBinding.instance.addPostFrameCallback((_) => _maybeAutoplay());
  }

  @override
  void dispose() {
    _playToken++;
    _radar.removeListener(_onRadarChanged);
    _radar.flushRenderReport(displayFrames: _schedule.length);
    for (final image in _images.values) {
      image.dispose();
    }
    super.dispose();
  }

  void _onRadarChanged() {
    if (!mounted) return;
    setState(_rebuildSchedule);
    _maybeAutoplay();
  }

  void _maybeAutoplay() {
    if (!mounted || _playing || _userPaused) return;
    if (_radar.settled && _schedule.length > 1) _startPlaying();
  }

  // Never prompts: permission is asked for at launch and by the location
  // button. Opening the radar should not throw up a dialog.
  Future<void> _locateYou() async {
    try {
      if (!await Geolocator.isLocationServiceEnabled()) return;
      final permission = await Geolocator.checkPermission();
      if (permission != LocationPermission.whileInUse &&
          permission != LocationPermission.always) {
        return;
      }
      // Last known is instant on a phone; web has no such thing.
      final last = kIsWeb ? null : await Geolocator.getLastKnownPosition();
      if (last != null && mounted) {
        setState(() => _you = LatLng(last.latitude, last.longitude));
      }
      final fix = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          timeLimit: Duration(seconds: 10),
        ),
      );
      if (mounted) {
        setState(() => _you = LatLng(fix.latitude, fix.longitude));
      }
    } catch (_) {
      // No fix: the dot stays on the selected location.
    }
  }

  String _imageKey(RadarDisplayFrame f) {
    final a = _real[f.a].cacheKey;
    if (f.isReal) return a;
    return '$a|${_real[f.b].cacheKey}|${f.t.toStringAsFixed(4)}|${f.blend.name}';
  }

  /// Rebuilds the schedule from the frames held and the warning state, keeping
  /// the playhead on the same moment.
  void _rebuildSchedule() {
    final radar = _radar;
    final keepTime = _schedule.isEmpty ? null : _schedule[_index].time;

    final view = _view;
    if (!radar.warningsKnown) {
      _realOnly = true;
      _realOnlyReason = 'Real frames only: warning status unavailable.';
    } else if (view != null &&
        warningsCoverView(
          radar.warnings,
          south: view.south,
          west: view.west,
          north: view.north,
          east: view.east,
        )) {
      _realOnly = true;
      _realOnlyReason =
          'Real frames only: tornado or severe thunderstorm warning in view.';
    } else {
      _realOnly = false;
      _realOnlyReason = null;
    }

    final real = radar.frames;
    _real = real;
    _schedule = buildDisplaySchedule(
      times: [for (final f in real) f.time],
      forecast: [for (final f in real) f.forecast],
      realOnly: _realOnly,
      hasFlow: (i) => radar.hasFlow(real[i]),
    );

    final lastObserved = real.lastIndexWhere((f) => !f.forecast);
    _nowIndex = lastObserved < 0
        ? null
        : _schedule.indexWhere((d) => d.isReal && d.a == lastObserved);
    if (_nowIndex != null && _nowIndex! < 0) _nowIndex = null;

    if (_schedule.isEmpty) {
      _index = 0;
    } else if (keepTime == null) {
      _index = _nowIndex ?? 0;
    } else {
      var best = 0;
      var bestGap = 1 << 62;
      for (var i = 0; i < _schedule.length; i++) {
        final gap = _schedule[i].time.difference(keepTime).inMilliseconds.abs();
        if (gap < bestGap) {
          best = i;
          bestGap = gap;
        }
      }
      _index = best;
    }
    if (_schedule.isNotEmpty) unawaited(_showIndex(_index));
  }

  void _onMapMoved(MapCamera camera, bool hasGesture) {
    final bounds = camera.visibleBounds;
    _view = bounds;
    final wasRealOnly = _realOnly;
    final covered = !_radar.warningsKnown ||
        warningsCoverView(
          _radar.warnings,
          south: bounds.south,
          west: bounds.west,
          north: bounds.north,
          east: bounds.east,
        );
    if (covered != wasRealOnly) setState(_rebuildSchedule);
  }

  void _onMapReady() => _onMapMoved(_map.camera, false);

  Future<ui.Image?> _imageFor(int index) {
    if (index < 0 || index >= _schedule.length) return Future.value(null);
    final f = _schedule[index];
    final key = _imageKey(f);
    final cached = _images.remove(key);
    if (cached != null) {
      _images[key] = cached; // most recently used goes last
      return Future.value(cached);
    }
    final inflight = _inflight[key];
    if (inflight != null) return inflight;
    final renderer = _radar.renderer;
    if (renderer == null) return Future.value(null);
    final grid = renderer.grid;
    final watch = Stopwatch()..start();
    final future = renderer
        .render(
          aKey: _real[f.a].cacheKey,
          bKey: f.isReal ? null : _real[f.b].cacheKey,
          t: f.t,
          blend: f.blend,
          flowKey: f.blend == RadarBlend.motion ? radarFlowKey(_real[f.a]) : null,
        )
        .then((rgba) => _imageFromRgba(rgba, grid.width, grid.height))
        .then<ui.Image?>((image) {
          _radar.reportRender(watch.elapsedMilliseconds);
          if (!mounted) {
            image.dispose();
            return null;
          }
          _images[key] = image;
          _evict();
          return image;
        })
        .catchError((Object _) => null)
        // A block body, not `=> _inflight.remove(key)`: that returns this very
        // future, and whenComplete waits on a returned future, so the render
        // would wait on itself forever.
        .whenComplete(() {
          _inflight.remove(key);
        });
    _inflight[key] = future;
    return future;
  }

  void _evict() {
    while (_images.length > _imageCacheSize) {
      final oldest = _images.keys.first;
      final image = _images.remove(oldest)!;
      // The engine keeps a drawn image alive until its frame is done, so
      // disposing the Dart handle here is safe even if it is on screen.
      if (!identical(image, _shown)) image.dispose();
    }
  }

  Future<void> _showIndex(int index) async {
    final image = await _imageFor(index);
    if (!mounted || image == null || _index != index) return;
    setState(() => _shown = image);
  }

  void _startPlaying() {
    if (_schedule.length < 2) return;
    final token = ++_playToken;
    setState(() {
      _playing = true;
      _userPaused = false;
    });
    unawaited(_playLoop(token));
  }

  Future<void> _playLoop(int token) async {
    while (mounted && _playing && token == _playToken) {
      final started = DateTime.now();
      final count = _schedule.length;
      if (count < 2) break;
      final next = (_index + 1) % count;
      final image = await _imageFor(next);
      // Start the one after while this one is on screen.
      unawaited(_imageFor((next + 1) % count));
      if (!mounted || !_playing || token != _playToken) return;
      if (next >= _schedule.length) continue; // schedule changed underneath
      setState(() {
        _index = next;
        if (image != null) _shown = image;
      });
      var delay = _schedule[next].isReal && _realOnly
          ? _realFrameDelay
          : _interpolatedFrameDelay;
      if (!_realOnly && _schedule[next].isReal && _realOnlyNeighbours(next)) {
        // A real frame with no interpolation either side (a gap too long to
        // fill, or motion not in yet) holds like a real-only frame would.
        delay = _realFrameDelay;
      }
      if (next == _schedule.length - 1) delay = _loopHold;
      final wait = delay - DateTime.now().difference(started);
      if (wait > Duration.zero) await Future<void>.delayed(wait);
    }
  }

  bool _realOnlyNeighbours(int i) {
    final before = i == 0 || _schedule[i - 1].isReal;
    final after = i == _schedule.length - 1 || _schedule[i + 1].isReal;
    return before && after;
  }

  void _stopPlaying({bool byUser = false}) {
    _playToken++;
    setState(() {
      _playing = false;
      if (byUser) _userPaused = true;
    });
  }

  void _togglePlay() {
    if (_playing) {
      _stopPlaying(byUser: true);
    } else {
      _startPlaying();
    }
  }

  void _scrubTo(int index) {
    if (_playing) _stopPlaying(byUser: true);
    _userPaused = true;
    setState(() => _index = index);
    unawaited(_showIndex(index));
  }

  String _frameLabel(RadarDisplayFrame frame) {
    final dt = frame.time.toLocal();
    String two(int v) => v.toString().padLeft(2, '0');
    final clock = '${two(dt.hour)}:${two(dt.minute)}';
    final isForecast = _nowIndex != null && _index > _nowIndex!;
    if (!isForecast) return clock;
    // Hour 20 of the forecast is not self-evidently tomorrow, so model frames
    // always carry the day.
    const days = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
    return '${days[dt.weekday - 1]} $clock';
  }

  /// Hours from when the sheet opened, for the scrubber's edge labels.
  String _relativeLabel(DateTime t) {
    final hours = (t.difference(_openedAt).inMinutes / 60).round();
    if (hours == 0) return 'now';
    return hours > 0 ? '+$hours h' : '$hours h';
  }

  @override
  Widget build(BuildContext context) {
    final radar = _radar;
    final schedule = _schedule;
    final grid = radar.renderer?.grid;
    final frame = schedule.isEmpty ? null : schedule[_index];
    final forecast = frame != null && _nowIndex != null && _index > _nowIndex!;
    final hasFrames = frame != null && grid != null;

    return Container(
      decoration: const BoxDecoration(
        color: Color(0xFF071F45),
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      child: Column(
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
          GestureDetector(
            // Load and render timings, for reading off a TestFlight run.
            onLongPress: () => setState(() => _showStats = !_showStats),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
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
                  if (forecast) ...[
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
                  if (frame != null)
                    Text(
                      _frameLabel(frame),
                      style: const TextStyle(color: Colors.white70),
                    ),
                ],
              ),
            ),
          ),
          if (_showStats)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Text(
                '${radar.metrics.summary()} '
                'Build ${_buildNumber.isEmpty ? 'local' : _buildNumber}. '
                '${schedule.length} display frames.',
                style: const TextStyle(color: Colors.white54, fontSize: 11),
              ),
            ),
          Expanded(
            child: !hasFrames
                ? Center(
                    child: radar.settled
                        ? const Text(
                            'Radar temporarily unavailable.',
                            style: TextStyle(color: Colors.white70),
                          )
                        : Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const CircularProgressIndicator(),
                              const SizedBox(height: 12),
                              Text(
                                radar.wantedFrames == 0
                                    ? 'Loading radar'
                                    : 'Loading radar: ${radar.frames.length} '
                                          'of ${radar.wantedFrames} frames',
                                style: const TextStyle(color: Colors.white70),
                              ),
                            ],
                          ),
                  )
                : FlutterMap(
                    mapController: _map,
                    options: MapOptions(
                      initialCenter: LatLng(
                        widget.location.latitude,
                        widget.location.longitude,
                      ),
                      initialZoom: 8,
                      minZoom: 4,
                      maxZoom: 11,
                      onPositionChanged: _onMapMoved,
                      onMapReady: _onMapReady,
                    ),
                    children: [
                      // Base map without labels, so town names and highways
                      // can sit on top of the radar instead of under it.
                      _basemapLayer(),
                      _RadarGridLayer(image: _shown, grid: grid),
                      // Labels (town names, highways) painted above the radar.
                      _basemapLabelsLayer(),
                      MarkerLayer(
                        markers: [
                          Marker(
                            point: _you,
                            width: 18,
                            height: 18,
                            child: const _YouAreHereDot(),
                          ),
                        ],
                      ),
                    ],
                  ),
          ),
          if (hasFrames) ...[
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 6, 16, 0),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  [
                    ?_realOnlyReason,
                    if (!_playing && !frame.isReal)
                      'Between real frames: interpolated.',
                    if (radar.manifest?.errors['forecast'] != null)
                      'Forecast unavailable right now.',
                  ].join(' '),
                  style: const TextStyle(color: Colors.white70, fontSize: 11),
                ),
              ),
            ),
            // ECCC requires attribution on its data. It sits on the radar
            // surface itself, not in the portfolio footer.
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 2, 16, 0),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  '${forecast ? _forecastAttribution : _radarAttribution}. '
                  '$_basemapAttribution',
                  style: const TextStyle(color: Colors.white38, fontSize: 11),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 4, 16, 16),
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
                  const SizedBox(width: 6),
                  Expanded(
                    child: _RadarScrubber(
                      count: schedule.length,
                      index: _index,
                      nowIndex: _nowIndex,
                      onChanged: _scrubTo,
                      startLabel: _nowIndex == 0
                          ? null
                          : _relativeLabel(schedule.first.time),
                      endLabel: _nowIndex == schedule.length - 1
                          ? null
                          : _relativeLabel(schedule.last.time),
                    ),
                  ),
                ],
              ),
            ),
          ] else
            const SizedBox(height: 24),
        ],
      ),
    );
  }
}

/// The radar timeline scrubber: one track, observed radar left of the "Now"
/// marker and model forecast right of it.
///
/// Spaced by frame, not by clock time. Observed frames are 6 minutes apart and
/// forecast frames an hour apart, so a clock-true track would squeeze the two
/// observed hours into the first 8% of the width and the playhead would crawl
/// through them then leap. The edge labels carry the actual span instead.
class _RadarScrubber extends StatelessWidget {
  const _RadarScrubber({
    required this.count,
    required this.index,
    required this.nowIndex,
    required this.onChanged,
    this.startLabel,
    this.endLabel,
  });

  final int count;
  final int index;
  final int? nowIndex;
  final ValueChanged<int> onChanged;
  final String? startLabel;
  final String? endLabel;

  static const double _inset = 10;

  int _indexAt(double dx, double width) {
    if (count < 2) return 0;
    final usable = width - 2 * _inset;
    final t = ((dx - _inset) / usable).clamp(0.0, 1.0);
    return (t * (count - 1)).round();
  }

  @override
  Widget build(BuildContext context) {
    const labelStyle = TextStyle(color: Colors.white54, fontSize: 10);
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        void scrub(double dx) {
          final i = _indexAt(dx, width);
          if (i != index) onChanged(i);
        }

        return Semantics(
          slider: true,
          label: 'Radar timeline',
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTapDown: (d) => scrub(d.localPosition.dx),
            onHorizontalDragStart: (d) => scrub(d.localPosition.dx),
            onHorizontalDragUpdate: (d) => scrub(d.localPosition.dx),
            child: SizedBox(
              height: 46,
              child: Stack(
                children: [
                  Positioned.fill(
                    child: CustomPaint(
                      painter: _RadarScrubberPainter(
                        count: count,
                        index: index,
                        nowIndex: nowIndex,
                        inset: _inset,
                      ),
                    ),
                  ),
                  if (startLabel != null)
                    Positioned(
                      left: 0,
                      bottom: 0,
                      child: Text(startLabel!, style: labelStyle),
                    ),
                  if (endLabel != null)
                    Positioned(
                      right: 0,
                      bottom: 0,
                      child: Text(endLabel!, style: labelStyle),
                    ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

class _RadarScrubberPainter extends CustomPainter {
  const _RadarScrubberPainter({
    required this.count,
    required this.index,
    required this.nowIndex,
    required this.inset,
  });

  final int count;
  final int index;
  final int? nowIndex;
  final double inset;

  @override
  void paint(Canvas canvas, Size size) {
    final usable = size.width - 2 * inset;
    double xOf(int i) =>
        count < 2 ? size.width / 2 : inset + usable * i / (count - 1);
    final y = size.height / 2;
    final track = Paint()
      ..strokeWidth = 4
      ..strokeCap = StrokeCap.round;

    final nowX = nowIndex == null ? inset : xOf(nowIndex!);
    // Observed: measured radar, drawn white.
    if (nowIndex != null) {
      canvas.drawLine(
        Offset(inset, y),
        Offset(nowX, y),
        track..color = Colors.white.withValues(alpha: 0.55),
      );
    }
    // Forecast: the model, drawn in the same gold as the FORECAST badge.
    if (nowIndex == null || nowIndex! < count - 1) {
      canvas.drawLine(
        Offset(nowX, y),
        Offset(size.width - inset, y),
        track..color = _albertaGold.withValues(alpha: 0.55),
      );
    }

    if (nowIndex != null) {
      canvas.drawLine(
        Offset(nowX, y - 11),
        Offset(nowX, y + 11),
        Paint()
          ..color = Colors.white
          ..strokeWidth = 2,
      );
      final label = TextPainter(
        text: const TextSpan(
          text: 'Now',
          style: TextStyle(
            color: Colors.white,
            fontSize: 10,
            fontWeight: FontWeight.w700,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      final lx = (nowX - label.width / 2).clamp(0.0, size.width - label.width);
      label.paint(canvas, Offset(lx, y - 13 - label.height));
    }

    final thumbX = xOf(index.clamp(0, count < 1 ? 0 : count - 1));
    canvas.drawCircle(Offset(thumbX, y), 8, Paint()..color = _albertaBlue);
    canvas.drawCircle(
      Offset(thumbX, y),
      6,
      Paint()
        ..color = (nowIndex != null && index > nowIndex!)
            ? _albertaGold
            : Colors.white,
    );
  }

  @override
  bool shouldRepaint(_RadarScrubberPainter old) =>
      old.count != count || old.index != index || old.nowIndex != nowIndex;
}

/// Yellow dot with a dark ring, so it reads over both the dark basemap and
/// bright radar returns.
class _YouAreHereDot extends StatelessWidget {
  const _YouAreHereDot();

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: _albertaGold,
        shape: BoxShape.circle,
        border: Border.all(color: Colors.black87, width: 2),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.5),
            blurRadius: 4,
          ),
        ],
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
