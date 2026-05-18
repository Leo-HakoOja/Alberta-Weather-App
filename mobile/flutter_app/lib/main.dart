import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';
import 'package:video_player/video_player.dart';

class _RadarFrame {
  const _RadarFrame({required this.path, required this.unixTime});

  final String path;
  final int unixTime;

  String tileUrlTemplate() {
    return 'https://tilecache.rainviewer.com$path/256/{z}/{x}/{y}/2/1_1.png';
  }
}

class _RadarTimeline {
  const _RadarTimeline({required this.frames});

  final List<_RadarFrame> frames;

  _RadarFrame? get latestOrNull => frames.isEmpty ? null : frames.last;
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
}

const _albertaBlue = Color(0xFF0B3A82);
const _albertaSky = Color(0xFF2F6FB2);
const _albertaGold = Color(0xFFF2C94C);
const _prairieCream = Color(0xFFFFF9EC);
const _defaultSavedLocations = <_SavedLocation>[
  _SavedLocation(
    name: 'Myrnam',
    province: 'AB',
    latitude: 53.66686,
    longitude: -111.23504,
    timezone: 'America/Edmonton',
  ),
  _SavedLocation(
    name: 'Edmonton',
    province: 'AB',
    latitude: 53.5461,
    longitude: -113.4938,
    timezone: 'America/Edmonton',
  ),
  _SavedLocation(
    name: 'Calgary',
    province: 'AB',
    latitude: 51.0447,
    longitude: -114.0719,
    timezone: 'America/Edmonton',
  ),
  _SavedLocation(
    name: 'Vancouver',
    province: 'BC',
    latitude: 49.2827,
    longitude: -123.1207,
    timezone: 'America/Vancouver',
  ),
];

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

  @override
  void initState() {
    super.initState();
    _savedLocations = List<_SavedLocation>.from(_defaultSavedLocations);
    _selectedLocation = _savedLocations.first;
    _weatherFuture = _fetchWeather();
    _radarFuture = _fetchRadarTimeline().catchError(
      (_) => const _RadarTimeline(frames: []),
    );
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

  Future<_RadarTimeline> _fetchRadarTimeline() async {
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

    List<_RadarFrame> parseFrames(List<dynamic> source) {
      return source
          .whereType<Map<String, dynamic>>()
          .map((item) {
            final path = item['path'];
            final time = item['time'];
            if (path is! String || time is! int) {
              return null;
            }
            return _RadarFrame(path: path, unixTime: time);
          })
          .whereType<_RadarFrame>()
          .toList();
    }

    // Use observed radar frames by default so map and forecast feel consistent.
    final observedFrames = parseFrames(past);
    final frames = observedFrames.isNotEmpty
        ? observedFrames
        : parseFrames(nowcast);

    if (frames.isEmpty) {
      throw Exception('No radar frames available');
    }

    return _RadarTimeline(frames: frames);
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
      final exists = _savedLocations.any(
        (saved) =>
            (saved.latitude - location.latitude).abs() < 0.0001 &&
            (saved.longitude - location.longitude).abs() < 0.0001,
      );
      if (!exists) {
        _savedLocations = [..._savedLocations, location];
      }
      _selectedLocation = location;
      _weatherFuture = _fetchWeather();
    });
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
          final province = '${item['admin1'] ?? item['country_code'] ?? '-'}';
          final lat = _toDouble(item['latitude']);
          final lon = _toDouble(item['longitude']);
          final timezone = '${item['timezone'] ?? 'auto'}';
          if (lat == null || lon == null) {
            return null;
          }
          return _SavedLocation(
            name: name,
            province: province,
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
          onSearch: _searchLocations,
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
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
                  children: [
                    _LocationPickerButton(
                      selected: _selectedLocation,
                      onTap: _openLocationPicker,
                      onLongPress: _openLocationPicker,
                    ),
                    const SizedBox(height: 12),
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
    required this.onSearch,
  });

  final _SavedLocation selectedLocation;
  final List<_SavedLocation> savedLocations;
  final Future<List<_SavedLocation>> Function(String query) onSearch;

  @override
  State<_LocationPickerSheet> createState() => _LocationPickerSheetState();
}

class _LocationPickerSheetState extends State<_LocationPickerSheet> {
  final TextEditingController _controller = TextEditingController();
  bool _loading = false;
  String? _error;
  List<_SavedLocation> _results = const [];

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
              const SizedBox(height: 6),
              ...widget.savedLocations.map((location) {
                final selected =
                    location.latitude == widget.selectedLocation.latitude &&
                    location.longitude == widget.selectedLocation.longitude;
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
  });

  final Map<String, dynamic> location;
  final Map<String, dynamic> current;
  final _SavedLocation selectedLocation;
  final Map<String, dynamic>? todayForecast;
  final Future<_RadarTimeline> radarFuture;
  final VoidCallback onRadarTap;

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
        child: Row(
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
                    'Sunrise ${_fmtClockFromIso(current['sunrise'])}   Sunset ${_fmtClockFromIso(current['sunset'])}',
                    maxLines: 1,
                    softWrap: false,
                    overflow: TextOverflow.fade,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: Colors.white70,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 12),
            SizedBox(
              width: 132,
              height: 160,
              child: _RadarPreviewCard(
                timelineFuture: radarFuture,
                location: selectedLocation,
                onTap: onRadarTap,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _RadarPreviewCard extends StatelessWidget {
  const _RadarPreviewCard({
    required this.timelineFuture,
    required this.location,
    required this.onTap,
  });

  final Future<_RadarTimeline> timelineFuture;
  final _SavedLocation location;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(16),
        child: Stack(
          fit: StackFit.expand,
          children: [
            FutureBuilder<_RadarTimeline>(
              future: timelineFuture,
              builder: (context, snapshot) {
                if (!snapshot.hasData || snapshot.data!.latestOrNull == null) {
                  return Container(
                    color: Colors.black.withValues(alpha: 0.25),
                    alignment: Alignment.center,
                    child: const Icon(Icons.radar, color: Colors.white70),
                  );
                }
                return FlutterMap(
                  options: MapOptions(
                    initialCenter: LatLng(
                      location.latitude,
                      location.longitude,
                    ),
                    initialZoom: 6,
                    interactionOptions: const InteractionOptions(
                      flags: InteractiveFlag.none,
                    ),
                  ),
                  children: [
                    TileLayer(
                      urlTemplate:
                          'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                      userAgentPackageName: 'ca.alberta.weather',
                    ),
                    TileLayer(
                      urlTemplate: snapshot.data!.latestOrNull!
                          .tileUrlTemplate(),
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
                    Colors.black.withValues(alpha: 0.44),
                  ],
                  stops: const [0.55, 1],
                ),
              ),
            ),
            Positioned(
              right: 8,
              bottom: 8,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.4),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: const Text(
                  'Radar',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
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

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  void _togglePlay(int max) {
    if (_playing) {
      _timer?.cancel();
      setState(() => _playing = false);
      return;
    }

    setState(() => _playing = true);
    _timer = Timer.periodic(const Duration(milliseconds: 550), (_) {
      if (!mounted) return;
      setState(() {
        _frameIndex = (_frameIndex + 1) % max;
      });
    });
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        color: Color(0xFF071F45),
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      child: FutureBuilder<_RadarTimeline>(
        future: widget.timelineFuture,
        builder: (context, snapshot) {
          if (!snapshot.hasData) {
            return const Center(child: CircularProgressIndicator());
          }

          final frames = snapshot.data!.frames;
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
          final dt = DateTime.fromMillisecondsSinceEpoch(
            frame.unixTime * 1000,
            isUtc: true,
          ).toLocal();

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
                    initialZoom: 6,
                  ),
                  children: [
                    TileLayer(
                      urlTemplate:
                          'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                      userAgentPackageName: 'ca.alberta.weather',
                    ),
                    TileLayer(urlTemplate: frame.tileUrlTemplate()),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(10, 8, 10, 16),
                child: Row(
                  children: [
                    IconButton(
                      onPressed: () => _togglePlay(frames.length),
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
      itemCount: metrics.length,
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 4,
        crossAxisSpacing: 8,
        mainAxisSpacing: 0,
        childAspectRatio: 1.15,
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
      color: _albertaBlue,
      child: Padding(
        padding: const EdgeInsets.all(8),
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
