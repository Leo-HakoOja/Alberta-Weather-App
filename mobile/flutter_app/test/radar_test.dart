import 'package:flutter_app/main.dart';
import 'package:flutter_app/radar_engine.dart';
import 'package:flutter_test/flutter_test.dart';

/// The continuous radar timeline and the hero's single temperature.
void main() {
  // -------------------------------------------------------------------------
  // One continuous timeline, now - 2 h to now + 24 h.
  // -------------------------------------------------------------------------

  group('continuousRadarWindow', () {
    List<DateTime> steps(DateTime start, DateTime end, Duration step) => [
      for (var t = start; !t.isAfter(end); t = t.add(step)) t,
    ];

    // Live-shaped extents from 2026-09-11: radar keeps 3 h at 6 min, HRDPS
    // advertises 48 hourly steps from the run.
    final observed = steps(
      DateTime.utc(2026, 9, 11, 13, 36),
      DateTime.utc(2026, 9, 11, 16, 36),
      const Duration(minutes: 6),
    );
    final forecast = steps(
      DateTime.utc(2026, 9, 11, 13),
      DateTime.utc(2026, 9, 13, 12),
      const Duration(hours: 1),
    );
    final now = DateTime.utc(2026, 9, 11, 16, 40);

    ({List<DateTime> observed, List<DateTime> forecast}) window({
      List<DateTime>? obs,
      List<DateTime>? fc,
      DateTime? at,
    }) => continuousRadarWindow<DateTime>(
      observed: obs ?? observed,
      forecast: fc ?? forecast,
      timeOf: (t) => t,
      now: at ?? now,
    );

    test('keeps two hours of observed radar, inclusive', () {
      final w = window();
      expect(w.observed.first, DateTime.utc(2026, 9, 11, 14, 42));
      expect(w.observed.last, DateTime.utc(2026, 9, 11, 16, 36));
      expect(w.observed.length, 20);
    });

    test('forecast starts strictly after the newest observed frame', () {
      final w = window();
      expect(w.forecast.first, DateTime.utc(2026, 9, 11, 17));
      // The model hours that overlap measured radar are not shown twice.
      expect(
        w.forecast.any((t) => !t.isAfter(w.observed.last)),
        isFalse,
      );
    });

    test('forecast stops at now + 24 h', () {
      final w = window();
      expect(w.forecast.last, DateTime.utc(2026, 9, 12, 16));
      expect(w.forecast.length, 24);
    });

    test('the joined timeline is strictly increasing across the seam', () {
      final w = window();
      final all = [...w.observed, ...w.forecast];
      for (var i = 1; i < all.length; i++) {
        expect(all[i].isAfter(all[i - 1]), isTrue, reason: 'at $i');
      }
    });

    test('a slow device clock does not hide the newest radar', () {
      final w = window(at: DateTime.utc(2026, 9, 11, 16, 30));
      expect(w.observed.last, DateTime.utc(2026, 9, 11, 16, 36));
      expect(w.forecast.first, DateTime.utc(2026, 9, 11, 17));
    });

    test('with no observed radar the forecast starts after now', () {
      final w = window(obs: const []);
      expect(w.observed, isEmpty);
      expect(w.forecast.first, DateTime.utc(2026, 9, 11, 17));
    });

    test('with no forecast the timeline is observed only', () {
      final w = window(fc: const []);
      expect(w.forecast, isEmpty);
      expect(w.observed.length, 20);
    });

    test('never invents instants', () {
      final w = window();
      for (final t in [...w.observed, ...w.forecast]) {
        expect(observed.contains(t) || forecast.contains(t), isTrue);
      }
    });

    test('a local now is compared in UTC', () {
      final w = window(at: now.toLocal());
      expect(w.forecast.first, DateTime.utc(2026, 9, 11, 17));
    });
  });

  group('meanLiveTemperature', () {
    Map<String, dynamic> src(String id, Object? temp, {String? error}) => {
      'source_id': id,
      'current': temp == null ? null : {'temperature': temp},
      'error': error,
    };

    test('averages every live source', () {
      // Live values for Myrnam, 2026-09-11.
      final mean = meanLiveTemperature([
        src('open-meteo', 10.7),
        src('eccc', 9.7),
        src('apple-weatherkit', 10.54),
      ]);
      expect(mean, closeTo(10.3133, 1e-3));
    });

    test('skips a source that errored, even with a stale value', () {
      final mean = meanLiveTemperature([
        src('open-meteo', 10.0),
        src('eccc', 30.0, error: 'No ECCC citypage site'),
        src('apple-weatherkit', 12.0),
      ]);
      expect(mean, 11.0);
    });

    test('skips a source with no current block or a non-numeric temp', () {
      final mean = meanLiveTemperature([
        src('open-meteo', 8),
        src('eccc', null),
        src('apple-weatherkit', '9'),
      ]);
      expect(mean, 8.0);
    });

    test('is null when no source is live, so the caller falls back', () {
      expect(meanLiveTemperature(const []), isNull);
      expect(
        meanLiveTemperature([src('eccc', null, error: 'down')]),
        isNull,
      );
    });
  });
}
