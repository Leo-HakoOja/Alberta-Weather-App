import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_app/radar_engine.dart';
import 'package:flutter_app/radar_store.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// A tiny grid and a fake backend, so the real store runs end to end: the
/// manifest, gzip'd frames, the disk cache, and the render worker isolate.
const _w = 8, _h = 4;

Map<String, dynamic> _manifest({
  required DateTime newestScan,
  String run = '20260911T120000Z',
}) => {
  'schema': 1,
  'grid': {
    'crs': 'EPSG:3857',
    'xmin': -12700000.0,
    'ymin': 7000000.0,
    'xmax': -12684000.0,
    'ymax': 7008000.0,
    'width': _w,
    'height': _h,
    'pixel_m': 2000.0,
    'row_order': 'north_to_south',
  },
  'codes': {
    'classes': 3,
    'nodata': 255,
    'units': 'mm/h',
    'values': [0.0, 2.0, 5.0, 8.0],
  },
  'observed': [
    for (var m = 120; m >= 0; m -= 6)
      {
        'time': newestScan.subtract(Duration(minutes: m)).toIso8601String(),
        'id': 'o${newestScan.subtract(Duration(minutes: m)).millisecondsSinceEpoch}',
      },
  ],
  'forecast': {
    'run': '2026-09-11T12:00:00Z',
    'run_id': run,
    'frames': [
      for (var h = 1; h <= 3; h++)
        {
          'time': DateTime.utc(
            newestScan.year,
            newestScan.month,
            newestScan.day,
            newestScan.hour,
          ).add(Duration(hours: h)).toIso8601String(),
          'id': 'f$h',
        },
    ],
  },
  'errors': <String, String>{},
};

class _FakeBackend {
  _FakeBackend(this.manifest);

  Map<String, dynamic> manifest;
  final List<String> requested = [];
  final List<Map<String, dynamic>> telemetry = [];

  late final client = MockClient((request) async {
    final path = request.url.path;
    requested.add(path);
    if (path == '/v1/radar/manifest') {
      return http.Response(jsonEncode(manifest), 200);
    }
    if (path == '/v1/radar/telemetry') {
      telemetry.add(jsonDecode(request.body) as Map<String, dynamic>);
      return http.Response('', 204);
    }
    if (path.startsWith('/v1/radar/flow/')) {
      return http.Response(
        jsonEncode({
          'rows': 1,
          'cols': 1,
          'block': 32,
          'dx': [2],
          'dy': [0],
        }),
        200,
      );
    }
    if (path.startsWith('/v1/radar/observed/') ||
        path.startsWith('/v1/radar/forecast/')) {
      final codes = Uint8List(_w * _h)..[3] = 2;
      return http.Response.bytes(gzip.encode(codes), 200);
    }
    return http.Response('', 404);
  });

  int get frameRequests => requested
      .where((p) => p.contains('/observed/') || p.contains('/forecast/'))
      .length;
}

Future<void> _settle(RadarStore store) async {
  await store.start();
  // Let the fire-and-forget telemetry post land.
  await Future<void>.delayed(const Duration(milliseconds: 50));
}

void main() {
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('radar_store_test'));
  tearDown(() => dir.deleteSync(recursive: true));

  final newest = DateTime.now().toUtc().subtract(const Duration(minutes: 3));
  final scan = DateTime.utc(
    newest.year,
    newest.month,
    newest.day,
    newest.hour,
    newest.minute - newest.minute % 6,
  );

  RadarStore store(_FakeBackend backend) => RadarStore(
    apiBase: Uri.parse('https://example.test/'),
    launchClock: Stopwatch()..start(),
    build: 'test',
    client: backend.client,
    cacheDirPath: dir.path,
  );

  test('first launch fetches the window; the next reads it from disk', () async {
    final backend = _FakeBackend(_manifest(newestScan: scan));
    final first = store(backend);
    await _settle(first);
    final wanted = first.wantedFrames;
    expect(wanted, greaterThan(20));
    expect(first.frames.length, wanted);
    expect(backend.frameRequests, wanted);
    expect(backend.telemetry.single['frames_from_network'], wanted);
    expect(backend.telemetry.single['launch_to_ready_ms'], isNotNull);

    // The newest scan renders, through the worker isolate, as its codes.
    final rgba = await first.renderer!.render(aKey: first.latestObserved!.cacheKey);
    expect(rgba.length, _w * _h * 4);
    expect(rgba.buffer.asUint32List()[3], radarColourOf(5));
    expect(rgba.buffer.asUint32List()[0], 0);
    first.dispose();

    // Relaunch six minutes later: one new scan published.
    backend
      ..manifest = _manifest(newestScan: scan.add(const Duration(minutes: 6)))
      ..requested.clear()
      ..telemetry.clear();
    final second = store(backend);
    await _settle(second);
    expect(backend.frameRequests, 1, reason: 'only the scan newer than the cache');
    expect(backend.requested.where((p) => p.contains('/flow/')), isEmpty);
    expect(backend.telemetry.single['frames_from_disk'], second.wantedFrames - 1);
    second.dispose();
  });

  test('a new model run replaces every forecast hour, cached scans stay', () async {
    final backend = _FakeBackend(_manifest(newestScan: scan));
    final first = store(backend);
    await _settle(first);
    first.dispose();

    backend
      ..manifest = _manifest(newestScan: scan, run: '20260911T180000Z')
      ..requested.clear();
    final second = store(backend);
    await _settle(second);
    final fetched = backend.requested.where((p) => p.contains('/forecast/')).toList();
    expect(fetched.length, second.frames.where((f) => f.forecast).length);
    expect(fetched.every((p) => p.contains('20260911T180000Z')), isTrue);
    expect(backend.requested.where((p) => p.contains('/observed/')), isEmpty);
    second.dispose();

    // The superseded run is pruned from disk.
    final names = dir.listSync().map((e) => e.uri.pathSegments.last);
    expect(names.where((n) => n.contains('20260911T120000Z')), isEmpty);
  });

  test('grid corners land exactly where the map projects them', () {
    // The overlay is placed by projecting these two corners with the map's
    // own CRS. If the round trip drifts, radar slides off the roads on zoom.
    final grid = RadarGridSpec.fromJson(
      (_manifestLive['grid'] as Map).cast<String, dynamic>(),
    );
    const crs = Epsg3857();
    final nw = crs.projection.project(grid.northWest);
    final se = crs.projection.project(grid.southEast);
    expect((nw.x - grid.xmin).abs(), lessThan(0.01));
    expect((nw.y - grid.ymax).abs(), lessThan(0.01));
    expect((se.x - grid.xmax).abs(), lessThan(0.01));
    expect((se.y - grid.ymin).abs(), lessThan(0.01));
  });
}

/// The live grid, 2026-09-11.
const _manifestLive = {
  'grid': {
    'crs': 'EPSG:3857',
    'xmin': -13638000.0,
    'ymin': 6190000.0,
    'xmax': -12078000.0,
    'ymax': 8468000.0,
    'width': 780,
    'height': 1139,
    'row_order': 'north_to_south',
  },
};
