/// On-device radar (ADR 0010): the pure parts.
///
/// The backend serves observed radar and the HRDPS forecast as grids of class
/// codes on one Web Mercator grid over Alberta. Everything here is plain Dart on
/// typed arrays, with no widgets and no I/O, so it can run in a worker isolate
/// and be tested directly:
///
/// * the grid and code table the manifest describes,
/// * which real frames make up the timeline and which the device must fetch,
/// * the display schedule: real frames plus interpolated ones between them,
/// * rendering a frame to RGBA through the one colour ramp both sources share,
/// * whether a tornado or severe thunderstorm warning covers the view.
library;

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:latlong2/latlong.dart';

const double _earthRadiusM = 6378137.0;

double lonOfMercatorX(double x) => x / _earthRadiusM * 180 / math.pi;

double latOfMercatorY(double y) =>
    (2 * math.atan(math.exp(y / _earthRadiusM)) - math.pi / 2) * 180 / math.pi;

/// The grid every frame is drawn on. EPSG:3857, row 0 at the north edge.
///
/// Because the grid is linear in Web Mercator, the same projection the map
/// uses, placing the image between its two projected corners keeps every
/// pixel on its ground position at any zoom. A lat/lon grid would need warping.
class RadarGridSpec {
  const RadarGridSpec({
    required this.xmin,
    required this.ymin,
    required this.xmax,
    required this.ymax,
    required this.width,
    required this.height,
  });

  factory RadarGridSpec.fromJson(Map<String, dynamic> json) {
    if (json['crs'] != 'EPSG:3857' || json['row_order'] != 'north_to_south') {
      throw const FormatException('Unsupported radar grid');
    }
    return RadarGridSpec(
      xmin: (json['xmin'] as num).toDouble(),
      ymin: (json['ymin'] as num).toDouble(),
      xmax: (json['xmax'] as num).toDouble(),
      ymax: (json['ymax'] as num).toDouble(),
      width: json['width'] as int,
      height: json['height'] as int,
    );
  }

  final double xmin;
  final double ymin;
  final double xmax;
  final double ymax;
  final int width;
  final int height;

  int get pixels => width * height;

  LatLng get northWest => LatLng(latOfMercatorY(ymax), lonOfMercatorX(xmin));

  LatLng get southEast => LatLng(latOfMercatorY(ymin), lonOfMercatorX(xmax));

  String get signature => '$xmin,$ymin,$xmax,$ymax,$width,$height';
}

/// Class codes to mm/h. Code 0 is dry; [nodata] is outside radar coverage.
class RadarCodeTable {
  RadarCodeTable({required this.values, required this.nodata})
    : assert(values.isNotEmpty && values.first == 0);

  factory RadarCodeTable.fromJson(Map<String, dynamic> json) => RadarCodeTable(
    values: [
      for (final v in json['values'] as List<dynamic>) (v as num).toDouble(),
    ],
    nodata: json['nodata'] as int,
  );

  final List<double> values;
  final int nodata;

  /// mm/h for every byte value. -1 marks no data. Codes past the table (never
  /// sent, but a byte can hold them) read as the top class.
  late final Float32List lut = () {
    final lut = Float32List(256);
    for (var c = 0; c < 256; c++) {
      lut[c] = c == nodata
          ? -1
          : values[c < values.length ? c : values.length - 1];
    }
    return lut;
  }();

  String get signature => '${values.length}:$nodata:${values.last}';
}

/// One real frame: a radar scan or a model hour, exactly as ECCC published it.
class RadarFrameRef {
  const RadarFrameRef({
    required this.time,
    required this.id,
    required this.forecast,
    this.runId,
  });

  final DateTime time;
  final String id;

  /// True for HRDPS model hours, false for observed radar.
  final bool forecast;

  /// The model run a forecast hour belongs to. A new run re-forecasts hours
  /// already held, so run is part of a forecast frame's identity.
  final String? runId;

  String get cacheKey => forecast ? 'fc_${runId}_$id' : 'obs_$id';

  String get path => forecast ? 'forecast/$runId/$id' : 'observed/$id';

  @override
  bool operator ==(Object other) =>
      other is RadarFrameRef && other.cacheKey == cacheKey;

  @override
  int get hashCode => cacheKey.hashCode;
}

/// Key of the motion field carrying forecast hour [from] onto the next hour.
String radarFlowKey(RadarFrameRef from) => 'flow_${from.runId}_${from.id}';

class RadarManifest {
  const RadarManifest({
    required this.grid,
    required this.codes,
    required this.observed,
    required this.forecast,
    required this.runId,
    required this.errors,
  });

  factory RadarManifest.fromJson(Map<String, dynamic> json) {
    if (json['schema'] != 1) {
      throw const FormatException('Unsupported radar manifest');
    }
    DateTime parse(Object? v) => DateTime.parse(v as String).toUtc();
    final fc = json['forecast'] as Map<String, dynamic>?;
    final runId = fc?['run_id'] as String?;
    return RadarManifest(
      grid: RadarGridSpec.fromJson(json['grid'] as Map<String, dynamic>),
      codes: RadarCodeTable.fromJson(json['codes'] as Map<String, dynamic>),
      observed: [
        for (final f in (json['observed'] as List<dynamic>? ?? const []))
          RadarFrameRef(
            time: parse((f as Map)['time']),
            id: f['id'] as String,
            forecast: false,
          ),
      ],
      forecast: [
        for (final f in (fc?['frames'] as List<dynamic>? ?? const []))
          RadarFrameRef(
            time: parse((f as Map)['time']),
            id: f['id'] as String,
            forecast: true,
            runId: runId,
          ),
      ],
      runId: runId,
      errors: {
        for (final e in ((json['errors'] as Map?) ?? const {}).entries)
          '${e.key}': '${e.value}',
      },
    );
  }

  final RadarGridSpec grid;
  final RadarCodeTable codes;
  final List<RadarFrameRef> observed;
  final List<RadarFrameRef> forecast;
  final String? runId;
  final Map<String, String> errors;

  /// Changes when frames on disk would no longer decode the same way.
  String get formatSignature => '${grid.signature}|${codes.signature}';
}

/// How far back the radar timeline reaches.
const radarObservedWindow = Duration(hours: 2);

/// How far ahead the model forecast runs.
const radarForecastWindow = Duration(hours: 24);

/// Joins observed radar and the model forecast into one timeline running from
/// `now - past` to `now + ahead`.
///
/// Observed frames older than the window are dropped; none are dropped for
/// being "after" now, because a device clock running slow must not hide the
/// newest radar. Forecast frames start strictly after the newest observed
/// frame, so the seam is where measurement ends and the model takes over, and
/// no instant appears twice. With no observed frames the seam is `now`.
///
/// Frame instants are never generated here, only filtered: GeoMet matches
/// `time` exactly, so every instant must come from an advertised extent.
({List<T> observed, List<T> forecast}) continuousRadarWindow<T>({
  required List<T> observed,
  required List<T> forecast,
  required DateTime Function(T) timeOf,
  required DateTime now,
  Duration past = radarObservedWindow,
  Duration ahead = radarForecastWindow,
}) {
  final utcNow = now.toUtc();
  final from = utcNow.subtract(past);
  final to = utcNow.add(ahead);
  final keptObserved = [
    for (final f in observed)
      if (!timeOf(f).toUtc().isBefore(from)) f,
  ];
  final seam = keptObserved.isEmpty
      ? utcNow
      : timeOf(keptObserved.last).toUtc();
  final keptForecast = [
    for (final f in forecast)
      if (timeOf(f).toUtc().isAfter(seam) && !timeOf(f).toUtc().isAfter(to)) f,
  ];
  return (observed: keptObserved, forecast: keptForecast);
}

/// Every real frame the timeline shows, oldest first.
List<RadarFrameRef> selectRealFrames(RadarManifest manifest, DateTime now) {
  final w = continuousRadarWindow<RadarFrameRef>(
    observed: manifest.observed,
    forecast: manifest.forecast,
    timeOf: (f) => f.time,
    now: now,
  );
  return [...w.observed, ...w.forecast];
}

/// Motion fields the timeline needs: one per pair of consecutive forecast
/// hours from the same run. Keyed by [radarFlowKey] of the earlier hour.
List<RadarFrameRef> flowSources(List<RadarFrameRef> real) => [
  for (var i = 0; i + 1 < real.length; i++)
    if (real[i].forecast &&
        real[i + 1].forecast &&
        real[i].runId == real[i + 1].runId &&
        real[i + 1].time.difference(real[i].time) == const Duration(hours: 1))
      real[i],
];

/// The delta: which of [wanted] must come over the network, given the keys
/// already held. Everything else is read from disk.
///
/// Observed frames never change once published, so a cached one is final.
/// Forecast frames are keyed by run, so a new model run misses the cache for
/// every hour and the whole forecast is fetched fresh, which is the point: a
/// newer run is a better forecast of the same hours.
List<RadarFrameRef> framesToFetch(
  List<RadarFrameRef> wanted,
  Set<String> cachedKeys,
) => [
  for (final f in wanted)
    if (!cachedKeys.contains(f.cacheKey)) f,
];

/// Cache keys worth keeping on disk: the frames and motion fields in view.
/// Anything else is an old scan or a superseded run.
Set<String> radarKeysToKeep(List<RadarFrameRef> real) => {
  for (final f in real) f.cacheKey,
  for (final f in flowSources(real)) radarFlowKey(f),
};

// ---------------------------------------------------------------------------
// Display schedule
// ---------------------------------------------------------------------------

enum RadarBlend {
  /// A real frame, drawn from its codes and nothing else.
  real,

  /// Straight blend of values between the frames either side. Used between
  /// radar scans (6 minutes apart, too close for motion to matter) and across
  /// the seam, where radar hands to the model and motion between the two is
  /// not a meaningful thing to estimate.
  linear,

  /// Values carried along the motion field between two forecast hours, so a
  /// storm moves across the hour instead of fading out in one place and in at
  /// the next.
  motion,
}

class RadarDisplayFrame {
  const RadarDisplayFrame({
    required this.time,
    required this.a,
    required this.b,
    required this.t,
    required this.blend,
  });

  final DateTime time;

  /// Indexes into the real-frame list. For a real frame, a == b and t == 0.
  final int a;
  final int b;
  final double t;
  final RadarBlend blend;

  bool get isReal => blend == RadarBlend.real;

  @override
  bool operator ==(Object other) =>
      other is RadarDisplayFrame &&
      other.a == a &&
      other.b == b &&
      other.t == t &&
      other.blend == blend;

  @override
  int get hashCode => Object.hash(a, b, t, blend);
}

/// Playback spacing between radar scans: one frame a minute.
const radarObservedStep = Duration(minutes: 1);

/// Playback spacing through the forecast, and across the seam.
const radarForecastStep = Duration(minutes: 10);

/// Gaps longer than these are left alone. A radar outage or a missing model
/// hour is shown as a jump, never filled with invented weather.
const radarMaxObservedGap = Duration(minutes: 18);
const radarMaxForecastGap = Duration(hours: 1);

/// Real frames, in order, with interpolated frames between them.
///
/// Real frames are always present and always drawn as-is. With [realOnly]
/// (an active tornado or severe thunderstorm warning in view) nothing is
/// inserted at all. A forecast gap whose motion field has not arrived yet is
/// left without interpolation rather than blended linearly, so the method
/// between two hours never changes under the viewer.
List<RadarDisplayFrame> buildDisplaySchedule({
  required List<DateTime> times,
  required List<bool> forecast,
  required bool realOnly,
  required bool Function(int a) hasFlow,
  Duration observedStep = radarObservedStep,
  Duration forecastStep = radarForecastStep,
}) {
  assert(times.length == forecast.length);
  final out = <RadarDisplayFrame>[];
  for (var i = 0; i < times.length; i++) {
    out.add(
      RadarDisplayFrame(
        time: times[i],
        a: i,
        b: i,
        t: 0,
        blend: RadarBlend.real,
      ),
    );
    if (realOnly || i + 1 >= times.length) continue;

    final gap = times[i + 1].difference(times[i]);
    final RadarBlend blend;
    final Duration step;
    final Duration maxGap;
    if (!forecast[i] && !forecast[i + 1]) {
      blend = RadarBlend.linear;
      step = observedStep;
      maxGap = radarMaxObservedGap;
    } else if (forecast[i] && forecast[i + 1]) {
      if (!hasFlow(i)) continue;
      blend = RadarBlend.motion;
      step = forecastStep;
      maxGap = radarMaxForecastGap;
    } else {
      blend = RadarBlend.linear;
      step = forecastStep;
      maxGap = radarMaxForecastGap;
    }
    if (gap <= Duration.zero || gap > maxGap) continue;

    final inserted = (gap.inSeconds / step.inSeconds).round() - 1;
    for (var k = 1; k <= inserted; k++) {
      final t = k / (inserted + 1);
      out.add(
        RadarDisplayFrame(
          time: times[i].add(
            Duration(milliseconds: (gap.inMilliseconds * t).round()),
          ),
          a: i,
          b: i + 1,
          t: t,
          blend: blend,
        ),
      );
    }
  }
  return out;
}

// ---------------------------------------------------------------------------
// Colour
// ---------------------------------------------------------------------------

/// ECCC's 14 radar colours at the lower edge of each class, from GeoMet's
/// `Radar-Rain_Dis-14colors` legend. The ramp blends between them in log mm/h,
/// which is what GeoMet's continuous `Radar-Rain_14colors` does (build 40's
/// test style). One ramp for observed and forecast, so nothing changes colour
/// at the seam.
const List<(double, int, int, int)> radarRampStops = [
  (0.1, 152, 203, 255),
  (1, 0, 152, 255),
  (2, 0, 255, 102),
  (4, 0, 203, 0),
  (8, 0, 152, 0),
  (12, 0, 102, 0),
  (16, 255, 255, 0),
  (24, 255, 203, 0),
  (32, 255, 152, 0),
  (50, 255, 102, 0),
  (64, 255, 0, 0),
  (100, 255, 0, 152),
  (125, 152, 51, 203),
  (200, 102, 0, 152),
];

const double radarRampMinMmh = 0.1;
const double radarRampMaxMmh = 200;

/// Per-pixel alpha for any precipitation. Just short of opaque so roads under
/// a heavy cell still read.
const int radarAlpha = 235;

const int _rampSize = 2048;
final double _rampLogMin = math.log(radarRampMinMmh);
final double _rampLogScale =
    (_rampSize - 1) / (math.log(radarRampMaxMmh) - math.log(radarRampMinMmh));

int _pack(int r, int g, int b, int a) => r | (g << 8) | (b << 16) | (a << 24);

/// RGBA of one value, packed for a little-endian Uint32 view of RGBA bytes.
/// Transparent below 0.1 mm/h.
int radarColourOf(double mmh) {
  if (!(mmh >= radarRampMinMmh)) return 0;
  final stops = radarRampStops;
  if (mmh >= stops.last.$1) {
    final s = stops.last;
    return _pack(s.$2, s.$3, s.$4, radarAlpha);
  }
  var i = 0;
  while (i + 1 < stops.length && stops[i + 1].$1 <= mmh) {
    i++;
  }
  final lo = stops[i];
  final hi = stops[i + 1];
  final f =
      (math.log(mmh) - math.log(lo.$1)) / (math.log(hi.$1) - math.log(lo.$1));
  int mix(int a, int b) => (a + (b - a) * f).round().clamp(0, 255);
  return _pack(mix(lo.$2, hi.$2), mix(lo.$3, hi.$3), mix(lo.$4, hi.$4), radarAlpha);
}

/// The ramp sampled at [_rampSize] log-spaced values, for per-pixel lookup.
Uint32List buildRadarRamp() {
  final ramp = Uint32List(_rampSize);
  for (var i = 0; i < _rampSize; i++) {
    ramp[i] = radarColourOf(math.exp(_rampLogMin + i / _rampLogScale));
  }
  return ramp;
}

/// Colour of each code, straight from the ramp at the code's value. Real
/// frames are drawn through this and nothing else.
Uint32List buildCodeColours(RadarCodeTable codes) {
  final out = Uint32List(256);
  for (var c = 0; c < 256; c++) {
    final v = codes.lut[c];
    out[c] = v < 0 ? 0 : radarColourOf(v);
  }
  return out;
}

// ---------------------------------------------------------------------------
// Rendering
// ---------------------------------------------------------------------------

/// Motion between two forecast hours, per 32-pixel cell, in grid pixels.
class RadarFlowField {
  const RadarFlowField({
    required this.rows,
    required this.cols,
    required this.block,
    required this.dx,
    required this.dy,
  });

  factory RadarFlowField.fromJson(Map<String, dynamic> json) {
    final rows = json['rows'] as int;
    final cols = json['cols'] as int;
    Int8List ints(Object? raw) {
      final list = raw as List<dynamic>;
      if (list.length != rows * cols) {
        throw const FormatException('Flow field size mismatch');
      }
      return Int8List.fromList([for (final v in list) (v as num).toInt()]);
    }

    return RadarFlowField(
      rows: rows,
      cols: cols,
      block: json['block'] as int,
      dx: ints(json['dx']),
      dy: ints(json['dy']),
    );
  }

  final int rows;
  final int cols;
  final int block;
  final Int8List dx;
  final Int8List dy;
}

class RadarRenderTables {
  RadarRenderTables(this.codes)
    : ramp = buildRadarRamp(),
      codeColours = buildCodeColours(codes);

  final RadarCodeTable codes;
  final Uint32List ramp;
  final Uint32List codeColours;
}

int _rampColour(double v, Uint32List ramp) {
  if (v < radarRampMinMmh) return 0;
  var i = ((math.log(v) - _rampLogMin) * _rampLogScale).floor();
  if (i >= _rampSize) i = _rampSize - 1;
  return ramp[i];
}

/// Draws one display frame into [out], one packed RGBA per grid pixel.
///
/// A real frame reads its codes and nothing else. An interpolated frame
/// blends *values* in mm/h, then colours the result, so a blend of 2 and
/// 8 mm/h is drawn as 5 mm/h, not as a mix of two colours.
void renderRadarFrame({
  required int width,
  required int height,
  required Uint8List a,
  Uint8List? b,
  double t = 0,
  RadarBlend blend = RadarBlend.real,
  RadarFlowField? flow,
  required RadarRenderTables tables,
  required Uint32List out,
}) {
  final n = width * height;
  assert(a.length == n && out.length == n);
  if (blend == RadarBlend.real || b == null) {
    final colours = tables.codeColours;
    for (var i = 0; i < n; i++) {
      out[i] = colours[a[i]];
    }
    return;
  }

  final lut = tables.codes.lut;
  final ramp = tables.ramp;
  final s = 1 - t;

  if (blend == RadarBlend.linear || flow == null) {
    for (var i = 0; i < n; i++) {
      var va = lut[a[i]];
      var vb = lut[b[i]];
      if (va < 0 && vb < 0) {
        out[i] = 0;
        continue;
      }
      if (va < 0) va = 0;
      if (vb < 0) vb = 0;
      final v = va * s + vb * t;
      out[i] = v < radarRampMinMmh ? 0 : _rampColour(v, ramp);
    }
    return;
  }

  // Motion: out(x) = s * A(x - t*u(x)) + t * B(x + s*u(x)), with u bilinear
  // between cell centres so neighbouring cells blend instead of tearing.
  final block = flow.block;
  final rows = flow.rows;
  final cols = flow.cols;
  final c0s = Int32List(width);
  final c1s = Int32List(width);
  final wxs = Float32List(width);
  for (var x = 0; x < width; x++) {
    final fx = (x + 0.5) / block - 0.5;
    final c0 = fx.floor();
    wxs[x] = (fx - c0).clamp(0.0, 1.0);
    c0s[x] = c0.clamp(0, cols - 1);
    c1s[x] = (c0 + 1).clamp(0, cols - 1);
  }
  final dx = flow.dx;
  final dy = flow.dy;
  for (var y = 0; y < height; y++) {
    final fy = (y + 0.5) / block - 0.5;
    final r0 = fy.floor();
    final wy = (fy - r0).clamp(0.0, 1.0);
    final row0 = r0.clamp(0, rows - 1) * cols;
    final row1 = (r0 + 1).clamp(0, rows - 1) * cols;
    final base = y * width;
    for (var x = 0; x < width; x++) {
      final c0 = c0s[x];
      final c1 = c1s[x];
      final wx = wxs[x];
      final u =
          (dx[row0 + c0] * (1 - wx) + dx[row0 + c1] * wx) * (1 - wy) +
          (dx[row1 + c0] * (1 - wx) + dx[row1 + c1] * wx) * wy;
      final v =
          (dy[row0 + c0] * (1 - wx) + dy[row0 + c1] * wx) * (1 - wy) +
          (dy[row1 + c0] * (1 - wx) + dy[row1 + c1] * wx) * wy;
      var ax = (x - t * u).round();
      var ay = (y - t * v).round();
      var bx = (x + s * u).round();
      var by = (y + s * v).round();
      ax = ax < 0 ? 0 : (ax >= width ? width - 1 : ax);
      ay = ay < 0 ? 0 : (ay >= height ? height - 1 : ay);
      bx = bx < 0 ? 0 : (bx >= width ? width - 1 : bx);
      by = by < 0 ? 0 : (by >= height ? height - 1 : by);
      var va = lut[a[ay * width + ax]];
      var vb = lut[b[by * width + bx]];
      if (va < 0 && vb < 0) {
        out[base + x] = 0;
        continue;
      }
      if (va < 0) va = 0;
      if (vb < 0) vb = 0;
      final value = va * s + vb * t;
      out[base + x] = value < radarRampMinMmh ? 0 : _rampColour(value, ramp);
    }
  }
}

// ---------------------------------------------------------------------------
// Warnings that switch interpolation off
// ---------------------------------------------------------------------------

class RadarWarning {
  const RadarWarning({required this.name, required this.rings});

  factory RadarWarning.fromJson(Map<String, dynamic> json) => RadarWarning(
    name: '${json['name'] ?? ''}',
    rings: [
      for (final ring in (json['rings'] as List<dynamic>? ?? const []))
        [
          for (final p in ring as List<dynamic>)
            LatLng(
              ((p as List<dynamic>)[1] as num).toDouble(),
              (p[0] as num).toDouble(),
            ),
        ],
    ],
  );

  final String name;
  final List<List<LatLng>> rings;
}

bool _pointInRing(double lat, double lon, List<LatLng> ring) {
  var inside = false;
  for (var i = 0, j = ring.length - 1; i < ring.length; j = i++) {
    final yi = ring[i].latitude, xi = ring[i].longitude;
    final yj = ring[j].latitude, xj = ring[j].longitude;
    if ((yi > lat) != (yj > lat) &&
        lon < xi + (lat - yi) * (xj - xi) / (yj - yi)) {
      inside = !inside;
    }
  }
  return inside;
}

bool _segmentsCross(
  double ax, double ay, double bx, double by,
  double cx, double cy, double dx, double dy,
) {
  double cross(double ox, double oy, double px, double py, double qx, double qy) =>
      (px - ox) * (qy - oy) - (py - oy) * (qx - ox);
  final d1 = cross(cx, cy, dx, dy, ax, ay);
  final d2 = cross(cx, cy, dx, dy, bx, by);
  final d3 = cross(ax, ay, bx, by, cx, cy);
  final d4 = cross(ax, ay, bx, by, dx, dy);
  return ((d1 > 0) != (d2 > 0)) && ((d3 > 0) != (d4 > 0));
}

/// True when any warning polygon overlaps the view rectangle at all.
///
/// Overlap, not containment: a warning clipping one corner of the screen is a
/// warning in the visible area.
bool warningsCoverView(
  List<RadarWarning> warnings, {
  required double south,
  required double west,
  required double north,
  required double east,
}) {
  final corners = [(south, west), (south, east), (north, east), (north, west)];
  for (final warning in warnings) {
    for (final ring in warning.rings) {
      if (ring.length < 3) continue;
      var minLat = 90.0, maxLat = -90.0, minLon = 180.0, maxLon = -180.0;
      for (final p in ring) {
        minLat = math.min(minLat, p.latitude);
        maxLat = math.max(maxLat, p.latitude);
        minLon = math.min(minLon, p.longitude);
        maxLon = math.max(maxLon, p.longitude);
      }
      if (maxLat < south || minLat > north || maxLon < west || minLon > east) {
        continue;
      }
      // A vertex inside the view.
      for (final p in ring) {
        if (p.latitude >= south &&
            p.latitude <= north &&
            p.longitude >= west &&
            p.longitude <= east) {
          return true;
        }
      }
      // The view inside the polygon.
      for (final (lat, lon) in corners) {
        if (_pointInRing(lat, lon, ring)) return true;
      }
      // Edges crossing with no vertex inside either.
      for (var i = 0, j = ring.length - 1; i < ring.length; j = i++) {
        for (var k = 0; k < 4; k++) {
          final c = corners[k];
          final d = corners[(k + 1) % 4];
          if (_segmentsCross(
            ring[j].longitude, ring[j].latitude,
            ring[i].longitude, ring[i].latitude,
            c.$2, c.$1, d.$2, d.$1,
          )) {
            return true;
          }
        }
      }
    }
  }
  return false;
}
