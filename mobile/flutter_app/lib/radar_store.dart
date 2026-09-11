/// On-device radar (ADR 0010): fetching, the disk cache, and the render worker.
///
/// [RadarStore] starts at app launch and pulls every real frame in the window
/// in the background, so the radar sheet opens onto frames already held. On
/// later launches it reads what it has from disk and fetches only frames the
/// cache does not hold: new radar scans, and all hours of a new model run.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io' as io;
import 'dart:isolate';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import 'radar_engine.dart';

/// What one launch cost. Sent to the backend once, so radar-ready time can be
/// read off a real TestFlight run rather than estimated.
class RadarMetrics {
  int? manifestMs;
  int? firstFrameMs;
  int? readyMs;
  int? flowsMs;
  int realFrames = 0;
  int framesFromNetwork = 0;
  int framesFromDisk = 0;
  int networkBytes = 0;
  int diskBytes = 0;
  int flowsFromNetwork = 0;
  int flowBytes = 0;
  int decodeMs = 0;
  String? error;

  Map<String, Object?> toJson() => {
    'launch_to_manifest_ms': manifestMs,
    'launch_to_first_frame_ms': firstFrameMs,
    'launch_to_ready_ms': readyMs,
    'launch_to_flows_ms': flowsMs,
    'real_frames': realFrames,
    'frames_from_network': framesFromNetwork,
    'frames_from_disk': framesFromDisk,
    'network_bytes': networkBytes,
    'disk_bytes': diskBytes,
    'flows_from_network': flowsFromNetwork,
    'flow_bytes': flowBytes,
    'decode_ms': decodeMs,
    'error': error,
  };

  String summary() {
    String mb(int b) => '${(b / 1e6).toStringAsFixed(2)} MB';
    String s(int? ms) => ms == null ? '-' : '${(ms / 1000).toStringAsFixed(1)} s';
    return 'Ready ${s(readyMs)} after launch (manifest ${s(manifestMs)}, '
        'first frame ${s(firstFrameMs)}, motion ${s(flowsMs)}). '
        '$realFrames real frames: $framesFromNetwork fetched (${mb(networkBytes)}), '
        '$framesFromDisk from cache (${mb(diskBytes)}). '
        '$flowsFromNetwork motion fields (${mb(flowBytes)}).';
  }
}

class RadarStore extends ChangeNotifier {
  RadarStore({
    required this.apiBase,
    required this.launchClock,
    this.build,
    http.Client? client,
    @visibleForTesting String? cacheDirPath,
  }) : _client = client ?? http.Client(),
       _cacheDirPath = cacheDirPath;

  final String? _cacheDirPath;

  /// Backend origin, e.g. https://alberta-weather-api.fly.dev/
  final Uri apiBase;

  /// Started in main(), so "launch" means process start.
  final Stopwatch launchClock;
  final String? build;
  final http.Client _client;

  RadarManifest? _manifest;
  DateTime? _manifestAt;
  List<RadarFrameRef> _real = const [];
  final Set<String> _loaded = {};
  final Set<String> _flowsLoaded = {};
  RadarRenderer? _renderer;
  io.Directory? _dir;
  bool _settled = false;
  String? _error;
  Future<void>? _running;
  bool _reported = false;

  List<RadarWarning> _warnings = const [];
  DateTime? _warningsAt;
  bool _warningsFailed = false;

  final RadarMetrics metrics = RadarMetrics();
  final List<int> _renderMs = [];

  RadarManifest? get manifest => _manifest;
  RadarRenderer? get renderer => _renderer;

  /// Every real frame in the window has been tried at least once.
  bool get settled => _settled;
  String? get error => _error;

  /// Real frames held and ready to draw, oldest first.
  List<RadarFrameRef> get frames => [
    for (final f in _real)
      if (_loaded.contains(f.cacheKey)) f,
  ];

  int get wantedFrames => _real.length;

  RadarFrameRef? get latestObserved {
    for (final f in frames.reversed) {
      if (!f.forecast) return f;
    }
    return null;
  }

  bool hasFlow(RadarFrameRef from) => _flowsLoaded.contains(radarFlowKey(from));

  List<RadarWarning> get warnings => _warnings;

  /// With no warning data less than ten minutes old, the store cannot say a
  /// tornado warning is *not* in view, and the viewer treats that as if one is.
  bool get warningsKnown =>
      !_warningsFailed ||
      (_warningsAt != null &&
          DateTime.now().difference(_warningsAt!) < const Duration(minutes: 10));

  /// Kick off the launch prefetch. Safe to call again; runs once at a time.
  Future<void> start() => _running ??= _sync().whenComplete(() {
    _running = null;
  });

  /// Delta refresh when the sheet opens, if the frames are a few minutes old.
  Future<void> refreshIfStale() {
    final at = _manifestAt;
    if (_warningsAt == null ||
        DateTime.now().difference(_warningsAt!) > const Duration(seconds: 60)) {
      unawaited(refreshWarnings());
    }
    if (at == null || DateTime.now().difference(at) > const Duration(minutes: 3)) {
      return start();
    }
    return _running ?? Future.value();
  }

  void reportRender(int ms) {
    _renderMs.add(ms);
  }

  /// Sends render timings gathered while the sheet was open.
  void flushRenderReport({required int displayFrames}) {
    if (_renderMs.isEmpty) return;
    final avg = _renderMs.reduce((a, b) => a + b) / _renderMs.length;
    _renderMs.clear();
    unawaited(_post({'render_ms_avg': avg, 'display_frames': displayFrames}));
  }

  Uri _uri(String path) => apiBase.resolve(path);

  Future<void> _sync() async {
    final first = !_reported;
    try {
      final dir = await _cacheDir();
      final manifestResponse = await _client
          .get(_uri('v1/radar/manifest'))
          .timeout(const Duration(seconds: 45));
      if (manifestResponse.statusCode != 200) {
        throw Exception('Radar manifest ${manifestResponse.statusCode}');
      }
      final manifest = RadarManifest.fromJson(
        jsonDecode(manifestResponse.body) as Map<String, dynamic>,
      );
      if (first) metrics.manifestMs = launchClock.elapsedMilliseconds;

      if (_manifest?.formatSignature != manifest.formatSignature) {
        _renderer?.dispose();
        _renderer = RadarRenderer.create(manifest.grid, manifest.codes);
        _loaded.clear();
        _flowsLoaded.clear();
        await _checkDiskFormat(dir, manifest.formatSignature);
      }
      _manifest = manifest;
      _manifestAt = DateTime.now();
      _error = null;

      final real = selectRealFrames(manifest, DateTime.now());
      final keep = radarKeysToKeep(real);
      _real = real;
      _loaded.retainAll(keep);
      _flowsLoaded.retainAll(keep);
      _renderer!.drop(keep);
      if (first) metrics.realFrames = real.length;
      notifyListeners();

      final onDisk = await _listDisk(dir);
      final pending = [
        for (final f in real)
          if (!_loaded.contains(f.cacheKey)) f,
      ];
      final fromNetwork = framesToFetch(pending, onDisk);
      // The newest scan first: it is what the hero preview and the sheet open on.
      fromNetwork.sort((a, b) {
        if (a.forecast != b.forecast) return a.forecast ? 1 : -1;
        return a.forecast ? a.time.compareTo(b.time) : b.time.compareTo(a.time);
      });

      final flowTask = _loadFlows(
        [
          for (final f in flowSources(real))
            if (!_flowsLoaded.contains(radarFlowKey(f))) f,
        ],
        onDisk,
        dir,
        first,
      );

      for (final f in pending) {
        if (!onDisk.contains(f.cacheKey)) continue;
        try {
          final bytes = await io.File('${dir!.path}/${f.cacheKey}.gz').readAsBytes();
          _accept(f, _inflate(bytes), first);
          if (first) {
            metrics.framesFromDisk++;
            metrics.diskBytes += bytes.length;
          }
        } catch (_) {
          fromNetwork.add(f);
        }
      }

      Future<void> fetchFrame(RadarFrameRef f) async {
        final suffix = kIsWeb ? '?transport=http' : '';
        final response = await _client
            .get(_uri('v1/radar/${f.path}$suffix'))
            .timeout(const Duration(seconds: 60));
        if (response.statusCode != 200) {
          throw Exception('Radar frame ${f.id}: ${response.statusCode}');
        }
        final bytes = response.bodyBytes;
        _accept(f, _inflate(bytes), first);
        if (first) {
          metrics.framesFromNetwork++;
          metrics.networkBytes += bytes.length;
        }
        if (dir != null) {
          await io.File('${dir.path}/${f.cacheKey}.gz').writeAsBytes(bytes, flush: false);
        }
      }

      // One more pass for anything that failed: GeoMet occasionally fails a
      // single request in a burst that succeeds seconds later.
      final failed = await _pool(fromNetwork, 6, fetchFrame);
      if (failed.isNotEmpty) await _pool(failed, 3, fetchFrame);

      _settled = true;
      if (first) metrics.readyMs = launchClock.elapsedMilliseconds;
      notifyListeners();

      await flowTask;
      if (first) metrics.flowsMs = launchClock.elapsedMilliseconds;
      await _prune(dir, keep);
    } catch (err) {
      _error = '$err';
      _settled = true;
      if (first) metrics.error = _error;
      notifyListeners();
    }
    if (first) {
      _reported = true;
      unawaited(_post(metrics.toJson()));
    }
  }

  Uint8List _inflate(Uint8List bytes) {
    final watch = Stopwatch()..start();
    // The web build asks for transport gzip, which the browser has already
    // undone. Natively the body is the gzip itself, cached as received.
    final raw = kIsWeb ? bytes : Uint8List.fromList(io.gzip.decode(bytes));
    metrics.decodeMs += watch.elapsedMilliseconds;
    return raw;
  }

  void _accept(RadarFrameRef f, Uint8List codes, bool first) {
    final grid = _manifest!.grid;
    if (codes.length != grid.pixels) {
      throw FormatException('Radar frame ${f.id} is ${codes.length} bytes');
    }
    _renderer!.putFrame(f.cacheKey, codes);
    _loaded.add(f.cacheKey);
    if (first && metrics.firstFrameMs == null) {
      metrics.firstFrameMs = launchClock.elapsedMilliseconds;
    }
    notifyListeners();
  }

  Future<void> _loadFlows(
    List<RadarFrameRef> sources,
    Set<String> onDisk,
    io.Directory? dir,
    bool first,
  ) async {
    Future<void> fetchFlow(RadarFrameRef f) async {
      final key = radarFlowKey(f);
      String? text;
      if (onDisk.contains(key) && dir != null) {
        try {
          text = await io.File('${dir.path}/$key.json').readAsString();
        } catch (_) {
          text = null;
        }
      }
      if (text == null) {
        final response = await _client
            .get(_uri('v1/radar/flow/${f.runId}/${f.id}'))
            .timeout(const Duration(seconds: 90));
        if (response.statusCode != 200) {
          throw Exception('Radar motion ${f.id}: ${response.statusCode}');
        }
        text = response.body;
        if (first) {
          metrics.flowsFromNetwork++;
          metrics.flowBytes += response.bodyBytes.length;
        }
        if (dir != null) {
          await io.File('${dir.path}/$key.json').writeAsString(text);
        }
      }
      final field = RadarFlowField.fromJson(jsonDecode(text) as Map<String, dynamic>);
      _renderer!.putFlow(key, field);
      _flowsLoaded.add(key);
      notifyListeners();
    }

    final failed = await _pool(sources, 3, fetchFlow);
    if (failed.isNotEmpty) await _pool(failed, 2, fetchFlow);
  }

  Future<void> refreshWarnings() async {
    try {
      final response = await _client
          .get(_uri('v1/radar/warnings'))
          .timeout(const Duration(seconds: 30));
      if (response.statusCode != 200) {
        throw Exception('Warnings ${response.statusCode}');
      }
      final json = jsonDecode(response.body) as Map<String, dynamic>;
      _warnings = [
        for (final w in json['warnings'] as List<dynamic>)
          RadarWarning.fromJson(w as Map<String, dynamic>),
      ];
      _warningsAt = DateTime.now();
      _warningsFailed = false;
    } catch (_) {
      _warningsFailed = true;
    }
    notifyListeners();
  }

  /// Runs [task] over [items], at most [width] at a time, and returns the
  /// items that failed. A failure is skipped, not fatal: one missing frame
  /// must not cost the rest.
  static Future<List<T>> _pool<T>(
    List<T> items,
    int width,
    Future<void> Function(T) task,
  ) async {
    var next = 0;
    final failed = <T>[];
    Future<void> worker() async {
      while (next < items.length) {
        final item = items[next++];
        try {
          await task(item);
        } catch (err) {
          failed.add(item);
          debugPrint('radar: $err');
        }
      }
    }

    await Future.wait([for (var i = 0; i < width; i++) worker()]);
    return failed;
  }

  Future<void> _post(Map<String, Object?> body) async {
    try {
      await _client
          .post(
            _uri('v1/radar/telemetry'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({
              'build': build,
              'platform': kIsWeb ? 'web' : io.Platform.operatingSystem,
              for (final e in body.entries)
                if (e.value != null) e.key: e.value,
            }),
          )
          .timeout(const Duration(seconds: 20));
    } catch (_) {
      // Timing reports are a convenience; never let one surface.
    }
  }

  // -------------------------------------------------------------------------
  // Disk
  // -------------------------------------------------------------------------

  /// Caches directory without a plugin: on iOS the app's tmp directory sits
  /// beside Library/Caches in the container; on Android systemTemp already is
  /// the app cache. The OS may clear either, which only costs a refetch.
  Future<io.Directory?> _cacheDir() async {
    if (kIsWeb) return null;
    if (_dir != null) return _dir;
    try {
      if (_cacheDirPath != null) {
        return _dir = await io.Directory(_cacheDirPath).create(recursive: true);
      }
      var tmp = io.Directory.systemTemp.path;
      while (tmp.endsWith('/')) {
        tmp = tmp.substring(0, tmp.length - 1);
      }
      final base = io.Platform.isIOS
          ? '${io.Directory(tmp).parent.path}/Library/Caches'
          : tmp;
      final dir = io.Directory('$base/radar-v1');
      await dir.create(recursive: true);
      return _dir = dir;
    } catch (_) {
      return null;
    }
  }

  Future<void> _checkDiskFormat(io.Directory? dir, String signature) async {
    if (dir == null) return;
    final marker = io.File('${dir.path}/format.txt');
    try {
      if (await marker.exists() && await marker.readAsString() == signature) return;
      await for (final e in dir.list()) {
        if (e is io.File) await e.delete();
      }
      await marker.writeAsString(signature);
    } catch (_) {}
  }

  Future<Set<String>> _listDisk(io.Directory? dir) async {
    if (dir == null) return {};
    final keys = <String>{};
    try {
      await for (final e in dir.list()) {
        final name = e.uri.pathSegments.last;
        if (name.endsWith('.gz')) keys.add(name.substring(0, name.length - 3));
        if (name.endsWith('.json')) keys.add(name.substring(0, name.length - 5));
      }
    } catch (_) {}
    return keys;
  }

  Future<void> _prune(io.Directory? dir, Set<String> keep) async {
    if (dir == null) return;
    try {
      await for (final e in dir.list()) {
        if (e is! io.File) continue;
        final name = e.uri.pathSegments.last;
        if (name == 'format.txt') continue;
        final key = name.replaceAll(RegExp(r'\.(gz|json)$'), '');
        if (!keep.contains(key)) await e.delete();
      }
    } catch (_) {}
  }

  @override
  void dispose() {
    _renderer?.dispose();
    _client.close();
    super.dispose();
  }
}

// ---------------------------------------------------------------------------
// Render worker
// ---------------------------------------------------------------------------

/// Draws display frames to RGBA. On a phone this runs in its own isolate: a
/// motion frame is about a million pixels of work and would otherwise stall
/// the UI mid-pan. The web has no isolates, so there it runs inline.
abstract class RadarRenderer {
  factory RadarRenderer.create(RadarGridSpec grid, RadarCodeTable codes) =>
      kIsWeb ? _InlineRenderer(grid, codes) : _IsolateRenderer(grid, codes);

  RadarGridSpec get grid;

  void putFrame(String key, Uint8List codes);
  void putFlow(String key, RadarFlowField flow);
  void drop(Set<String> keep);

  /// RGBA bytes, width * height * 4, rows north to south.
  Future<Uint8List> render({
    required String aKey,
    String? bKey,
    double t = 0,
    RadarBlend blend = RadarBlend.real,
    String? flowKey,
  });

  void dispose();
}

class _InlineRenderer implements RadarRenderer {
  _InlineRenderer(this.grid, RadarCodeTable codes)
    : _tables = RadarRenderTables(codes);

  @override
  final RadarGridSpec grid;
  final RadarRenderTables _tables;
  final _frames = <String, Uint8List>{};
  final _flows = <String, RadarFlowField>{};

  @override
  void putFrame(String key, Uint8List codes) => _frames[key] = codes;

  @override
  void putFlow(String key, RadarFlowField flow) => _flows[key] = flow;

  @override
  void drop(Set<String> keep) {
    _frames.removeWhere((k, _) => !keep.contains(k));
    _flows.removeWhere((k, _) => !keep.contains(k));
  }

  @override
  Future<Uint8List> render({
    required String aKey,
    String? bKey,
    double t = 0,
    RadarBlend blend = RadarBlend.real,
    String? flowKey,
  }) async {
    final out = _renderInto(
      grid,
      _tables,
      _frames,
      _flows,
      aKey,
      bKey,
      t,
      blend,
      flowKey,
    );
    return out.buffer.asUint8List();
  }

  @override
  void dispose() {
    _frames.clear();
    _flows.clear();
  }
}

Uint32List _renderInto(
  RadarGridSpec grid,
  RadarRenderTables tables,
  Map<String, Uint8List> frames,
  Map<String, RadarFlowField> flows,
  String aKey,
  String? bKey,
  double t,
  RadarBlend blend,
  String? flowKey,
) {
  final a = frames[aKey];
  if (a == null) throw StateError('Radar frame $aKey not loaded');
  final b = bKey == null ? null : frames[bKey];
  if (bKey != null && b == null) throw StateError('Radar frame $bKey not loaded');
  final flow = flowKey == null ? null : flows[flowKey];
  if (blend == RadarBlend.motion && flow == null) {
    throw StateError('Radar motion $flowKey not loaded');
  }
  final out = Uint32List(grid.pixels);
  renderRadarFrame(
    width: grid.width,
    height: grid.height,
    a: a,
    b: b,
    t: t,
    blend: blend,
    flow: flow,
    tables: tables,
    out: out,
  );
  return out;
}

class _IsolateRenderer implements RadarRenderer {
  _IsolateRenderer(this.grid, RadarCodeTable codes) {
    _port = ReceivePort();
    final ready = Completer<SendPort>();
    _port.listen((msg) {
      if (msg is SendPort) {
        ready.complete(msg);
        return;
      }
      if (msg is List && msg.length == 2) {
        final completer = _pending.remove(msg[0] as int);
        if (completer == null) return;
        final payload = msg[1];
        if (payload is TransferableTypedData) {
          completer.complete(payload.materialize().asUint8List());
        } else {
          completer.completeError(StateError('$payload'));
        }
      }
    });
    _send = ready.future;
    Isolate.spawn(_radarWorkerMain, <Object>[
      _port.sendPort,
      grid.width,
      grid.height,
      codes.values,
      codes.nodata,
    ]).then((isolate) => _isolate = isolate);
  }

  @override
  final RadarGridSpec grid;
  late final ReceivePort _port;
  late final Future<SendPort> _send;
  Isolate? _isolate;
  final _pending = <int, Completer<Uint8List>>{};
  int _nextId = 0;
  bool _disposed = false;

  void _post(Object message) {
    if (_disposed) return;
    _send.then((port) => port.send(message));
  }

  @override
  void putFrame(String key, Uint8List codes) =>
      _post(['frame', key, TransferableTypedData.fromList([codes])]);

  @override
  void putFlow(String key, RadarFlowField flow) => _post([
    'flow',
    key,
    flow.rows,
    flow.cols,
    flow.block,
    TransferableTypedData.fromList([flow.dx]),
    TransferableTypedData.fromList([flow.dy]),
  ]);

  @override
  void drop(Set<String> keep) => _post(['drop', keep.toList()]);

  @override
  Future<Uint8List> render({
    required String aKey,
    String? bKey,
    double t = 0,
    RadarBlend blend = RadarBlend.real,
    String? flowKey,
  }) {
    if (_disposed) return Future.error(StateError('Renderer disposed'));
    final id = _nextId++;
    final completer = Completer<Uint8List>();
    _pending[id] = completer;
    _post(['render', id, aKey, bKey, t, blend.index, flowKey]);
    return completer.future;
  }

  @override
  void dispose() {
    _disposed = true;
    _isolate?.kill(priority: Isolate.immediate);
    _port.close();
    for (final c in _pending.values) {
      c.completeError(StateError('Renderer disposed'));
    }
    _pending.clear();
  }
}

void _radarWorkerMain(List<Object> args) {
  final reply = args[0] as SendPort;
  final grid = RadarGridSpec(
    xmin: 0,
    ymin: 0,
    xmax: 0,
    ymax: 0,
    width: args[1] as int,
    height: args[2] as int,
  );
  final tables = RadarRenderTables(
    RadarCodeTable(
      values: (args[3] as List).cast<double>(),
      nodata: args[4] as int,
    ),
  );
  final frames = <String, Uint8List>{};
  final flows = <String, RadarFlowField>{};
  final inbox = ReceivePort();
  reply.send(inbox.sendPort);
  inbox.listen((raw) {
    final m = raw as List;
    switch (m[0] as String) {
      case 'frame':
        frames[m[1] as String] =
            (m[2] as TransferableTypedData).materialize().asUint8List();
      case 'flow':
        flows[m[1] as String] = RadarFlowField(
          rows: m[2] as int,
          cols: m[3] as int,
          block: m[4] as int,
          dx: (m[5] as TransferableTypedData).materialize().asInt8List(),
          dy: (m[6] as TransferableTypedData).materialize().asInt8List(),
        );
      case 'drop':
        final keep = (m[1] as List).cast<String>().toSet();
        frames.removeWhere((k, _) => !keep.contains(k));
        flows.removeWhere((k, _) => !keep.contains(k));
      case 'render':
        final id = m[1] as int;
        try {
          final out = _renderInto(
            grid,
            tables,
            frames,
            flows,
            m[2] as String,
            m[3] as String?,
            m[4] as double,
            RadarBlend.values[m[5] as int],
            m[6] as String?,
          );
          reply.send([id, TransferableTypedData.fromList([out.buffer.asUint8List()])]);
        } catch (err) {
          reply.send([id, '$err']);
        }
    }
  });
}
