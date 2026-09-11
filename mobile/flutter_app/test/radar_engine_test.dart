import 'dart:typed_data';

import 'package:flutter_app/radar_engine.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';

/// The live grid from 2026-09-11; codes table shortened.
Map<String, dynamic> manifestJson({String run = '20260911T120000Z'}) => {
  'schema': 1,
  'grid': {
    'crs': 'EPSG:3857',
    'xmin': -13638000.0,
    'ymin': 6190000.0,
    'xmax': -12078000.0,
    'ymax': 8468000.0,
    'width': 780,
    'height': 1139,
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
    for (var m = 0; m <= 132; m += 6)
      {
        'time': DateTime.utc(2026, 9, 11, 14, 24).add(Duration(minutes: m)).toIso8601String(),
        'id': 'obs$m',
      },
  ],
  'forecast': {
    'run': '2026-09-11T12:00:00Z',
    'run_id': run,
    'frames': [
      for (var h = 16; h <= 41; h++)
        {
          'time': DateTime.utc(2026, 9, 11).add(Duration(hours: h)).toIso8601String(),
          'id': 'fc$h',
        },
    ],
  },
  'errors': <String, String>{},
};

void main() {
  final now = DateTime.utc(2026, 9, 11, 16, 40);

  group('manifest and delta cache', () {
    test('parses grid corners back to Alberta', () {
      final m = RadarManifest.fromJson(manifestJson());
      expect(m.grid.northWest.latitude, closeTo(60.3, 0.1));
      expect(m.grid.northWest.longitude, closeTo(-122.5, 0.1));
      expect(m.grid.southEast.latitude, closeTo(48.5, 0.1));
      expect(m.grid.southEast.longitude, closeTo(-108.5, 0.1));
      expect(m.codes.lut[255], -1);
      expect(m.codes.lut[2], 5.0);
    });

    test('the window is two hours of radar then 24 model hours', () {
      final real = selectRealFrames(RadarManifest.fromJson(manifestJson()), now);
      final observed = real.where((f) => !f.forecast).toList();
      final forecast = real.where((f) => f.forecast).toList();
      expect(observed.first.time, DateTime.utc(2026, 9, 11, 14, 42));
      expect(observed.last.time, DateTime.utc(2026, 9, 11, 16, 36));
      expect(forecast.first.time, DateTime.utc(2026, 9, 11, 17));
      expect(forecast.length, 24);
    });

    test('a later launch fetches only frames newer than the cache', () {
      final m = RadarManifest.fromJson(manifestJson());
      final real = selectRealFrames(m, now);
      // Cache from a launch 12 minutes earlier: everything but the two newest scans.
      final cached = {
        for (final f in real)
          if (f.forecast || f.time.isBefore(DateTime.utc(2026, 9, 11, 16, 30))) f.cacheKey,
      };
      final fetch = framesToFetch(real, cached);
      expect(fetch.map((f) => f.id), ['obs126', 'obs132']);
    });

    test('a new model run refetches every forecast hour', () {
      final old = selectRealFrames(RadarManifest.fromJson(manifestJson()), now);
      final cached = {for (final f in old) f.cacheKey};
      final fresh = selectRealFrames(
        RadarManifest.fromJson(manifestJson(run: '20260911T180000Z')),
        now,
      );
      final fetch = framesToFetch(fresh, cached);
      expect(fetch.every((f) => f.forecast), isTrue);
      expect(fetch.length, 24);
    });

    test('motion fields pair consecutive hours of one run only', () {
      final real = selectRealFrames(RadarManifest.fromJson(manifestJson()), now);
      final sources = flowSources(real);
      expect(sources.length, 23);
      expect(sources.every((f) => f.forecast), isTrue);
      expect(radarFlowKey(sources.first), 'flow_20260911T120000Z_fc17');
    });

    test('keys to keep cover frames and motion, nothing superseded', () {
      final real = selectRealFrames(RadarManifest.fromJson(manifestJson()), now);
      final keep = radarKeysToKeep(real);
      expect(keep.length, real.length + 23);
      expect(keep.contains('obs_obs0'), isFalse); // older than two hours
    });
  });

  group('display schedule', () {
    List<RadarDisplayFrame> schedule({
      bool realOnly = false,
      bool flows = true,
      List<DateTime>? times,
      List<bool>? forecast,
    }) {
      times ??= [
        DateTime.utc(2026, 9, 11, 16, 24),
        DateTime.utc(2026, 9, 11, 16, 30),
        DateTime.utc(2026, 9, 11, 16, 36),
        DateTime.utc(2026, 9, 11, 17),
        DateTime.utc(2026, 9, 11, 18),
      ];
      forecast ??= [false, false, false, true, true];
      return buildDisplaySchedule(
        times: times,
        forecast: forecast,
        realOnly: realOnly,
        hasFlow: (_) => flows,
      );
    }

    test('fills radar gaps by the minute and model hours by ten minutes', () {
      final s = schedule();
      // 5 + 5 between scans, 1 across the 24-minute seam, 5 in the hour.
      expect(s.length, 5 + 5 + 5 + 1 + 5);
      expect(s.where((f) => f.blend == RadarBlend.linear).length, 11);
      expect(s.where((f) => f.blend == RadarBlend.motion).length, 5);
    });

    test('every real frame appears once, in order, untouched', () {
      final s = schedule();
      final real = s.where((f) => f.isReal).toList();
      expect([for (final f in real) f.a], [0, 1, 2, 3, 4]);
      for (final f in real) {
        expect(f.t, 0);
        expect(f.b, f.a);
      }
    });

    test('time only moves forward', () {
      final s = schedule();
      for (var i = 1; i < s.length; i++) {
        expect(s[i].time.isAfter(s[i - 1].time), isTrue);
      }
    });

    test('a warning in view means real frames only', () {
      final s = schedule(realOnly: true);
      expect(s.length, 5);
      expect(s.every((f) => f.isReal), isTrue);
    });

    test('a model hour whose motion is not in yet is left unfilled', () {
      final s = schedule(flows: false);
      expect(s.where((f) => f.blend == RadarBlend.motion), isEmpty);
      expect(s.length, 5 + 5 + 5 + 1);
    });

    test('a radar outage is shown as a jump, not invented', () {
      final s = schedule(
        times: [DateTime.utc(2026, 9, 11, 15), DateTime.utc(2026, 9, 11, 15, 30)],
        forecast: [false, false],
      );
      expect(s.length, 2);
    });
  });

  group('rendering', () {
    final codes = RadarCodeTable(values: const [0, 2, 5, 8], nodata: 255);
    final tables = RadarRenderTables(codes);

    test('a real frame is its codes through the ramp, nothing else', () {
      final a = Uint8List.fromList([0, 1, 2, 3, 255, 1]);
      final out = Uint32List(6);
      renderRadarFrame(width: 3, height: 2, a: a, tables: tables, out: out);
      for (var i = 0; i < 6; i++) {
        expect(out[i], tables.codeColours[a[i]]);
      }
      expect(out[0], 0, reason: 'dry is transparent');
      expect(out[4], 0, reason: 'no coverage is transparent');
      expect(out[1], radarColourOf(2));
    });

    test('interpolation blends mm/h, then colours', () {
      // 2 mm/h and 8 mm/h halfway is 5 mm/h, drawn in 5's colour: not the
      // average of the blue-green and green the two ends are drawn in.
      final a = Uint8List.fromList([1]);
      final b = Uint8List.fromList([3]);
      final out = Uint32List(1);
      renderRadarFrame(
        width: 1,
        height: 1,
        a: a,
        b: b,
        t: 0.5,
        blend: RadarBlend.linear,
        tables: tables,
        out: out,
      );
      int channel(int c, int shift) => (c >> shift) & 0xff;
      final want = radarColourOf(5);
      for (final shift in [0, 8, 16, 24]) {
        expect((channel(out[0], shift) - channel(want, shift)).abs(), lessThanOrEqualTo(2));
      }
    });

    test('no coverage on both sides stays transparent when blended', () {
      final out = Uint32List(1);
      renderRadarFrame(
        width: 1,
        height: 1,
        a: Uint8List.fromList([255]),
        b: Uint8List.fromList([255]),
        t: 0.3,
        blend: RadarBlend.linear,
        tables: tables,
        out: out,
      );
      expect(out[0], 0);
    });

    test('motion carries a storm across the hour instead of cross-fading', () {
      const w = 64, h = 32;
      Uint8List cell(int cx) {
        final f = Uint8List(w * h);
        for (var y = 12; y < 20; y++) {
          for (var x = cx - 4; x < cx + 4; x++) {
            f[y * w + x] = 3;
          }
        }
        return f;
      }

      final a = cell(12);
      final b = cell(44);
      final flow = RadarFlowField(
        rows: 1,
        cols: 2,
        block: 32,
        dx: Int8List.fromList([32, 32]),
        dy: Int8List.fromList([0, 0]),
      );
      Uint32List draw(RadarBlend blend) {
        final out = Uint32List(w * h);
        renderRadarFrame(
          width: w,
          height: h,
          a: a,
          b: b,
          t: 0.5,
          blend: blend,
          flow: flow,
          tables: tables,
          out: out,
        );
        return out;
      }

      final moved = draw(RadarBlend.motion);
      final faded = draw(RadarBlend.linear);
      final mid = 16 * w + 28;
      expect(moved[mid], radarColourOf(8), reason: 'halfway, at full strength');
      expect(moved[16 * w + 12], 0, reason: 'gone from where it started');
      expect(faded[mid], 0, reason: 'a blend never passes through the middle');
      expect(faded[16 * w + 12], isNot(0));
    });

    test('one ramp: ECCC colours at the class edges, clear below 0.1', () {
      expect(radarColourOf(0.05), 0);
      expect(radarColourOf(0.1) & 0xffffff, 152 | (203 << 8) | (255 << 16));
      expect(radarColourOf(16) & 0xffffff, 255 | (255 << 8));
      expect(radarColourOf(500) & 0xffffff, 102 | (152 << 16));
      expect(radarColourOf(4) >>> 24, radarAlpha);
    });

    test('a flow field must match its declared size', () {
      expect(
        () => RadarFlowField.fromJson({
          'rows': 2,
          'cols': 2,
          'block': 32,
          'dx': [1, 2, 3],
          'dy': [1, 2, 3, 4],
        }),
        throwsFormatException,
      );
    });
  });

  group('warnings in view', () {
    RadarWarning box(double s, double w, double n, double e) => RadarWarning(
      name: 'tornado warning',
      rings: [
        [LatLng(s, w), LatLng(s, e), LatLng(n, e), LatLng(n, w), LatLng(s, w)],
      ],
    );

    bool covers(List<RadarWarning> ws) =>
        warningsCoverView(ws, south: 53, west: -114, north: 54, east: -113);

    test('a warning inside the view', () {
      expect(covers([box(53.4, -113.6, 53.6, -113.4)]), isTrue);
    });

    test('the view inside a warning', () {
      expect(covers([box(50, -120, 58, -110)]), isTrue);
    });

    test('a warning clipping one corner', () {
      expect(covers([box(53.9, -113.1, 55, -112)]), isTrue);
    });

    test('a thin warning crossing the view with no vertex inside', () {
      final ring = [
        const LatLng(53.49, -116),
        const LatLng(53.49, -111),
        const LatLng(53.51, -111),
        const LatLng(53.51, -116),
        const LatLng(53.49, -116),
      ];
      expect(covers([RadarWarning(name: 'x', rings: [ring])]), isTrue);
    });

    test('a warning elsewhere in Alberta does not', () {
      expect(covers([box(49, -114, 50, -113)]), isFalse);
      expect(covers(const []), isFalse);
    });
  });
}
