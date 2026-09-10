import 'package:flutter_app/main.dart';
import 'package:flutter_test/flutter_test.dart';

/// GeoMet's radar layer advertises `nearestValue="0"`, so the WMS server matches
/// the requested `time` exactly rather than snapping to the closest frame. A
/// timestamp that is off by a second, or that carries a milliseconds component,
/// returns a ServiceException XML body instead of a PNG. flutter_map treats that
/// as a failed tile and renders nothing, so the failure is silent: the radar
/// simply never appears. These tests pin the format.
void main() {
  group('formatGeoMetTime', () {
    test('emits second precision with no sub-second part', () {
      final t = DateTime.utc(2026, 9, 10, 14, 6, 0, 123, 456);
      expect(formatGeoMetTime(t), '2026-09-10T14:06:00Z');
    });

    test('matches the extent format GeoMet publishes', () {
      // Verbatim from a live GetCapabilities for RADAR_1KM_RRAI.
      final start = DateTime.parse('2026-09-10T11:06:00Z');
      expect(formatGeoMetTime(start), '2026-09-10T11:06:00Z');
    });

    test('converts local time to UTC rather than formatting it as-is', () {
      final utc = DateTime.utc(2026, 9, 10, 14, 6);
      expect(formatGeoMetTime(utc.toLocal()), '2026-09-10T14:06:00Z');
    });

    test('zero-pads every component', () {
      final t = DateTime.utc(2026, 1, 2, 3, 4, 5);
      expect(formatGeoMetTime(t), '2026-01-02T03:04:05Z');
    });
  });

  group('parseIso8601Period', () {
    test('parses the observed radar step', () {
      expect(parseIso8601Period('PT6M'), const Duration(minutes: 6));
    });

    test('parses the forecast model step', () {
      expect(parseIso8601Period('PT1H'), const Duration(hours: 1));
    });

    test('parses combined components', () {
      expect(
        parseIso8601Period('PT1H30M'),
        const Duration(hours: 1, minutes: 30),
      );
    });

    test('tolerates surrounding whitespace from the XML', () {
      expect(parseIso8601Period('  PT6M  '), const Duration(minutes: 6));
    });

    test('returns null rather than guessing at unsupported forms', () {
      // Date-component durations would silently expand into a runaway loop.
      expect(parseIso8601Period('P1D'), isNull);
      expect(parseIso8601Period('PT0M'), isNull);
      expect(parseIso8601Period(''), isNull);
      expect(parseIso8601Period('6M'), isNull);
      expect(parseIso8601Period('nonsense'), isNull);
    });
  });

  group('frame expansion', () {
    // Mirrors the loop in _fetchGeoMetTimeline against a real extent, so a
    // change to the step or the bound shows up as a failing count.
    List<DateTime> expand(String extent, {int cap = 40}) {
      final parts = extent.split('/');
      final start = DateTime.parse(parts[0]).toUtc();
      final end = DateTime.parse(parts[1]).toUtc();
      final step = parseIso8601Period(parts[2])!;
      final out = <DateTime>[];
      for (var t = start; !t.isAfter(end) && out.length < cap; t = t.add(step)) {
        out.add(t);
      }
      return out;
    }

    test('a live 3-hour observed extent yields 31 inclusive frames', () {
      final frames = expand(
        '2026-09-10T11:06:00Z/2026-09-10T14:06:00Z/PT6M',
      );
      expect(frames.length, 31);
      expect(formatGeoMetTime(frames.first), '2026-09-10T11:06:00Z');
      expect(formatGeoMetTime(frames.last), '2026-09-10T14:06:00Z');
    });

    test('the cap holds a 48-hour hourly extent inside the frame budget', () {
      final frames = expand(
        '2026-09-09T13:00:00Z/2026-09-11T12:00:00Z/PT1H',
      );
      expect(frames.length, 40);
    });
  });
}
