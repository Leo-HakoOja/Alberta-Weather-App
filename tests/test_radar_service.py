"""Radar grids (ADR 0010). Offline: every test builds its own inputs."""

from __future__ import annotations

import math
import unittest
import xml.etree.ElementTree as ET
from datetime import datetime, timedelta, timezone
from io import BytesIO
from unittest.mock import patch

import numpy as np
from PIL import Image

from backend.app import radar_service as rs
from fastapi import HTTPException

from backend.app import main as api_main

UTC = timezone.utc


def _grid(width=64, height=48) -> rs.Grid:
    return rs.Grid(xmin=0.0, ymin=0.0, width=width, height=height, pixel_m=2000.0)


class CodeTableTests(unittest.TestCase):
    def test_thresholds_are_strictly_increasing_from_point_one_to_200(self):
        t = rs.THRESHOLDS
        self.assertEqual(len(t), rs.CODE_CLASSES)
        self.assertEqual(t[0], 0.1)
        self.assertEqual(t[-1], 200.0)
        self.assertTrue(all(b > a for a, b in zip(t, t[1:])))

    def test_codes_fit_under_nodata_and_the_red_channel(self):
        self.assertLess(rs.CODE_CLASSES, rs.NODATA)
        self.assertLessEqual(rs.CODE_CLASSES, 255)

    def test_encode_edges(self):
        codes = rs.encode_mmh(np.array([0.0, 0.0999, 0.1, rs.THRESHOLDS[5], 1e6, np.nan, -1.0]))
        self.assertEqual(codes.tolist(), [0, 0, 1, 6, rs.CODE_CLASSES, rs.NODATA, 0])

    def test_each_representative_value_encodes_back_to_its_code(self):
        values = rs.code_values()
        self.assertEqual(values[0], 0.0)
        self.assertEqual(len(values), rs.CODE_CLASSES + 1)
        codes = rs.encode_mmh(np.array(values))
        self.assertEqual(codes.tolist(), list(range(rs.CODE_CLASSES + 1)))

    def test_pack_round_trips_and_is_deterministic(self):
        g = _grid()
        codes = np.random.default_rng(1).integers(0, 121, (g.height, g.width), dtype=np.uint8)
        blob = rs.pack(codes)
        self.assertEqual(blob, rs.pack(codes))
        np.testing.assert_array_equal(rs.unpack(blob, g), codes)


class RadarStyleTests(unittest.TestCase):
    def test_style_is_xml_with_one_entry_per_code_plus_dry_and_ceiling(self):
        root = ET.fromstring(rs.radar_sld())
        entries = root.findall(".//ColorMapEntry")
        self.assertEqual(len(entries), rs.CODE_CLASSES + 2)
        self.assertEqual(entries[0].get("color"), "#000000")
        self.assertEqual(entries[1].get("color"), "#010000")
        self.assertEqual(float(entries[1].get("quantity")), rs.THRESHOLDS[0])
        self.assertEqual(entries[rs.CODE_CLASSES].get("color"), f"#{rs.CODE_CLASSES:02X}0000")

    def test_request_fits_under_geomets_url_limit(self):
        # GeoMet answers 414 somewhere between 7.8 KB and 8.4 KB (measured).
        url = rs.radar_url(datetime(2026, 9, 11, 16, 36, tzinfo=UTC))
        self.assertLess(len(url), 8000)
        self.assertIn("time=2026-09-11T16%3A36%3A00Z", url)
        self.assertIn("crs=EPSG%3A3857", url)


def _png(rgba: np.ndarray) -> bytes:
    buf = BytesIO()
    Image.fromarray(rgba, "RGBA").save(buf, format="PNG")
    return buf.getvalue()


class DecodeRadarTests(unittest.TestCase):
    def setUp(self):
        self.g = _grid(8, 4)
        self.rgba = np.zeros((4, 8, 4), dtype=np.uint8)
        self.rgba[0, 0] = (0, 0, 0, 255)  # covered, dry
        self.rgba[1, 1] = (37, 0, 0, 255)  # code 37
        self.rgba[2, 2] = (rs.CODE_CLASSES, 0, 0, 255)

    def test_red_is_the_code_and_transparent_is_nodata(self):
        codes = rs.decode_radar_png(_png(self.rgba), self.g)
        self.assertEqual(codes[0, 0], 0)
        self.assertEqual(codes[1, 1], 37)
        self.assertEqual(codes[2, 2], rs.CODE_CLASSES)
        self.assertEqual(codes[3, 3], rs.NODATA)

    def test_refuses_an_image_in_geomets_default_palette(self):
        self.rgba[1, 1] = (0, 175, 215, 255)
        with self.assertRaises(rs.RadarError):
            rs.decode_radar_png(_png(self.rgba), self.g)

    def test_refuses_a_red_value_beyond_the_table(self):
        self.rgba[1, 1] = (rs.CODE_CLASSES + 1, 0, 0, 255)
        with self.assertRaises(rs.RadarError):
            rs.decode_radar_png(_png(self.rgba), self.g)

    def test_refuses_an_exception_document(self):
        with self.assertRaises(rs.RadarError):
            rs.decode_radar_png(b"<?xml version='1.0'?><ServiceExceptionReport/>", self.g)

    def test_refuses_the_wrong_size(self):
        with self.assertRaises(rs.RadarError):
            rs.decode_radar_png(_png(self.rgba), _grid(9, 4))


class ForecastTests(unittest.TestCase):
    def test_resample_takes_the_source_pixel_under_each_grid_pixel(self):
        g = rs.GRID
        # One source pixel per degree, value = longitude of its west edge.
        lon0, lat0 = -130.0, 65.0
        cols = np.arange(-130, -100, dtype=np.float64)
        src = np.tile(cols, (25, 1))
        out = rs.resample_to_grid(src, lon0, lat0, 1.0, 1.0, g)
        self.assertEqual(out.shape, (g.height, g.width))
        # Column 0's centre is just east of the grid's west edge.
        west_lon = float(rs.lon_of_x(g.xmin + g.pixel_m / 2))
        self.assertEqual(out[0, 0], math.floor(west_lon))

    def test_resample_marks_pixels_outside_the_source_nan(self):
        g = rs.GRID
        src = np.ones((2, 2))
        out = rs.resample_to_grid(src, -115.0, 55.0, 0.5, 0.5, g)
        self.assertTrue(np.isnan(out[0, 0]))
        self.assertTrue(np.isfinite(out).any())

    def test_geotiff_to_codes_converts_mm_per_second_to_mm_per_hour(self):
        g = _grid(4, 4)
        g = rs.Grid(
            xmin=rs.merc_x(-115.0), ymin=rs.merc_y(53.0), width=4, height=4, pixel_m=2000.0
        )
        rate = 8.06 / 3600.0  # kg m-2 s-1 for 8.06 mm/h, the live value checked
        src = np.full((10, 10), rate, dtype=np.float32)
        buf = BytesIO()
        Image.fromarray(src, "F").save(
            buf,
            format="TIFF",
            tiffinfo={33922: (0.0, 0.0, 0.0, -115.5, 53.5, 0.0), 33550: (0.1, 0.1, 0.0)},
        )
        codes = rs.decode_forecast_tiff(buf.getvalue(), g)
        expected = int(rs.encode_mmh(np.array([8.06]))[0])
        self.assertTrue((codes == expected).all(), codes)

    def test_forecast_url_pins_the_model_run(self):
        url = rs.forecast_url(
            datetime(2026, 9, 11, 12, tzinfo=UTC), datetime(2026, 9, 11, 18, tzinfo=UTC)
        )
        self.assertIn("DIM_REFERENCE_TIME=2026-09-11T12%3A00%3A00Z", url)
        self.assertIn("TIME=2026-09-11T18%3A00%3A00Z", url)
        self.assertIn("format=image%2Ftiff", url)


CAPS = """
<Layer><Name>HRDPS</Name>
<Dimension name="time" units="ISO8601">2026-09-09T00:00:00Z/2026-09-12T12:00:00Z/PT1H</Dimension>
<Layer queryable="1"><Name>HRDPS.CONTINENTAL_RT</Name>
<Dimension name="time" units="ISO8601" default="2026-09-11T16:00:00Z" nearestValue="0">2026-09-11T13:00:00Z/2026-09-13T12:00:00Z/PT1H</Dimension>
<Dimension name="reference_time" units="ISO8601" default="2026-09-11T12:00:00Z" multipleValues="1" nearestValue="0">2026-09-10T06:00:00Z/2026-09-11T12:00:00Z/PT6H</Dimension>
</Layer></Layer>"""


class TimeTests(unittest.TestCase):
    def test_layer_dimensions_reads_the_layer_not_its_parent(self):
        dims = rs.layer_dimensions(CAPS, "HRDPS.CONTINENTAL_RT")
        self.assertEqual(dims["time"], "2026-09-11T13:00:00Z/2026-09-13T12:00:00Z/PT1H")
        self.assertEqual(dims["reference_time"], "2026-09-11T12:00:00Z")
        self.assertEqual(dims["reference_extent"], "2026-09-10T06:00:00Z/2026-09-11T12:00:00Z/PT6H")

    def test_expand_extent_is_inclusive(self):
        times = rs.expand_extent("2026-09-11T13:36:00Z/2026-09-11T16:36:00Z/PT6M")
        self.assertEqual(len(times), 31)
        self.assertEqual(rs.iso(times[-1]), "2026-09-11T16:36:00Z")

    def test_stamps_round_trip(self):
        t = datetime(2026, 9, 11, 16, 36, tzinfo=UTC)
        self.assertEqual(rs.parse_stamp(rs.stamp(t)), t)
        with self.assertRaises(rs.RadarError):
            rs.parse_stamp("../../etc/passwd")


class FlowTests(unittest.TestCase):
    def test_recovers_the_motion_of_a_shifted_storm(self):
        h, w = 320, 320
        yy, xx = np.mgrid[0:h, 0:w]
        a = np.zeros((h, w), dtype=np.uint8)
        blob = ((yy - 160) ** 2 / 40**2 + (xx - 140) ** 2 / 60**2) < 1
        a[blob] = 40
        a[blob & (((yy - 150) ** 2 + (xx - 150) ** 2) < 15**2)] = 80
        b = np.roll(np.roll(a, 24, axis=1), -12, axis=0)  # 24 px east, 12 px north
        dx, dy = rs.estimate_flow(a, b)
        r, c = 160 // rs.FLOW_BLOCK, 150 // rs.FLOW_BLOCK
        self.assertAlmostEqual(int(dx[r, c]), 24, delta=4)
        self.assertAlmostEqual(int(dy[r, c]), -12, delta=4)

    def test_empty_frames_do_not_move(self):
        z = np.zeros((128, 128), dtype=np.uint8)
        dx, dy = rs.estimate_flow(z, z)
        self.assertFalse(dx.any() or dy.any())

    def test_nodata_counts_as_dry(self):
        a = np.full((128, 128), rs.NODATA, dtype=np.uint8)
        dx, dy = rs.estimate_flow(a, a)
        self.assertFalse(dx.any() or dy.any())


def _feature(name, alert_type="warning", status="issued", expires="2099-01-01T00:00:00Z", ring=None):
    ring = ring or [[-114, 51], [-113, 51], [-113, 52], [-114, 52], [-114, 51]]
    return {
        "properties": {
            "alert_type": alert_type,
            "alert_name_en": name,
            "alert_code": "X",
            "status_en": status,
            "expiration_datetime": expires,
            "feature_name_en": "Calgary",
        },
        "geometry": {"type": "Polygon", "coordinates": [ring, [[-113.6, 51.4], [-113.5, 51.4], [-113.5, 51.5]]]},
    }


class WarningTests(unittest.TestCase):
    now = datetime(2026, 9, 11, 18, tzinfo=UTC)

    def test_keeps_only_active_tornado_and_severe_thunderstorm_warnings(self):
        features = [
            _feature("tornado warning"),
            _feature("severe thunderstorm warning"),
            _feature("severe thunderstorm watch", alert_type="watch"),
            _feature("rainfall warning"),
            _feature("tornado warning", status="ended"),
            _feature("tornado warning", expires="2026-09-11T17:00:00Z"),
        ]
        out = rs.warning_features(features, self.now)
        self.assertEqual([w["name"] for w in out], ["tornado warning", "severe thunderstorm warning"])

    def test_carries_outer_ring_and_bbox_only(self):
        (w,) = rs.warning_features([_feature("tornado warning")], self.now)
        self.assertEqual(len(w["rings"]), 1)
        self.assertEqual(w["bbox"], [-114, 51, -113, 52])

    def test_decimates_large_rings_but_keeps_them_closed(self):
        ring = [[-114 + i / 1000, 51 + (i % 7) / 100] for i in range(2000)]
        ring.append(ring[0])
        (w,) = rs.warning_features([_feature("tornado warning", ring=ring)], self.now)
        self.assertLessEqual(len(w["rings"][0]), 402)
        self.assertEqual(w["rings"][0][-1], [round(ring[0][0], 4), round(ring[0][1], 4)])


class ManifestTests(unittest.TestCase):
    def _dims(self, layer):
        if layer == rs.RADAR_LAYER:
            return {"time": "2026-09-11T13:36:00Z/2026-09-11T16:36:00Z/PT6M"}
        return {
            "time": "2026-09-11T13:00:00Z/2026-09-13T12:00:00Z/PT1H",
            "reference_time": "2026-09-11T12:00:00Z",
            "reference_extent": "2026-09-10T06:00:00Z/2026-09-11T12:00:00Z/PT6H",
        }

    def test_lists_the_window_of_real_frames(self):
        with patch.object(rs, "dimensions", side_effect=self._dims):
            m = rs.build_manifest(datetime(2026, 9, 11, 16, 40, tzinfo=UTC))
        self.assertEqual(m["observed"][-1]["id"], "20260911T163600Z")
        self.assertEqual(m["observed"][0]["time"], "2026-09-11T14:24:00Z")
        fc = m["forecast"]
        self.assertEqual(fc["run_id"], "20260911T120000Z")
        # From an hour before the seam, through now + 25 h.
        self.assertEqual(fc["frames"][0]["time"], "2026-09-11T16:00:00Z")
        self.assertEqual(fc["frames"][-1]["time"], "2026-09-12T17:00:00Z")
        self.assertEqual(m["codes"]["values"][0], 0.0)
        self.assertEqual(m["grid"]["width"], rs.GRID.width)

    def test_forecast_failure_still_serves_observed(self):
        def dims(layer):
            if layer == rs.FORECAST_LAYER:
                raise rs.RadarError("HRDPS down")
            return self._dims(layer)

        with patch.object(rs, "dimensions", side_effect=dims):
            m = rs.build_manifest(datetime(2026, 9, 11, 16, 40, tzinfo=UTC))
        self.assertIsNone(m["forecast"])
        self.assertIn("forecast", m["errors"])
        self.assertTrue(m["observed"])

    def test_both_down_is_an_error(self):
        with patch.object(rs, "dimensions", side_effect=rs.RadarError("down")):
            with self.assertRaises(rs.RadarError):
                rs.build_manifest()

    def test_frames_outside_the_advertised_extent_are_not_fetched(self):
        with patch.object(rs, "dimensions", side_effect=self._dims), patch.object(
            rs, "_http_get"
        ) as get:
            with self.assertRaises(LookupError):
                rs.observed_frame(datetime(2026, 9, 11, 16, 37, tzinfo=UTC))
            with self.assertRaises(LookupError):
                rs.forecast_frame(
                    datetime(2026, 9, 9, 0, tzinfo=UTC), datetime(2026, 9, 9, 3, tzinfo=UTC)
                )
            with self.assertRaises(LookupError):
                rs.forecast_frame(
                    datetime(2026, 9, 11, 12, tzinfo=UTC), datetime(2026, 9, 14, 3, tzinfo=UTC)
                )
            get.assert_not_called()

    def test_endpoint_maps_unknown_frames_to_404(self):
        with patch.object(rs, "dimensions", side_effect=self._dims):
            with self.assertRaises(HTTPException) as ctx:
                api_main.radar_observed("20260911T163700Z")
        self.assertEqual(ctx.exception.status_code, 404)


if __name__ == "__main__":
    unittest.main()
