"""Tests for ECCC severe-weather alert handling.

ADR 0005 treats alerts as life-safety, so the failure modes that matter here are
the quiet ones: an alert tagged to the wrong location, an expired warning that
keeps showing, or ECCC's wording being altered on the way through.
"""

import sys
from datetime import datetime, timedelta, timezone
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from backend.app import alerts_service  # noqa: E402
from backend.app.alerts_service import (  # noqa: E402
    _geometry_contains,
    _is_active,
    _normalize,
    _severity_rank,
    fetch_alerts,
    fetch_alerts_safe,
)

# A square covering roughly central Alberta, in GeoJSON (lon, lat) order.
_SQUARE = {
    "type": "Polygon",
    "coordinates": [
        [
            [-114.0, 53.0],
            [-112.0, 53.0],
            [-112.0, 54.0],
            [-114.0, 54.0],
            [-114.0, 53.0],
        ]
    ],
}

# Same square with a hole punched in the middle.
_SQUARE_WITH_HOLE = {
    "type": "Polygon",
    "coordinates": [
        _SQUARE["coordinates"][0],
        [
            [-113.4, 53.4],
            [-112.6, 53.4],
            [-112.6, 53.6],
            [-113.4, 53.6],
            [-113.4, 53.4],
        ],
    ],
}


def test_point_inside_polygon():
    assert _geometry_contains(_SQUARE, -113.0, 53.5) is True


def test_point_outside_polygon():
    assert _geometry_contains(_SQUARE, -110.0, 53.5) is False
    assert _geometry_contains(_SQUARE, -113.0, 58.0) is False


def test_latitude_longitude_order_is_not_interchangeable():
    """Swapping the arguments must not accidentally match.

    GeoJSON is (lon, lat) while the rest of the codebase passes (lat, lon). A
    swap here would tag every alert to the wrong place without raising.
    """
    assert _geometry_contains(_SQUARE, -113.0, 53.5) is True
    assert _geometry_contains(_SQUARE, 53.5, -113.0) is False


def test_hole_is_excluded():
    assert _geometry_contains(_SQUARE_WITH_HOLE, -113.0, 53.5) is False
    # Still inside the ring, just not in the hole.
    assert _geometry_contains(_SQUARE_WITH_HOLE, -113.9, 53.1) is True


def test_multipolygon_matches_any_part():
    multi = {
        "type": "MultiPolygon",
        "coordinates": [
            _SQUARE["coordinates"],
            [
                [
                    [-119.0, 49.5],
                    [-118.0, 49.5],
                    [-118.0, 50.0],
                    [-119.0, 50.0],
                    [-119.0, 49.5],
                ]
            ],
        ],
    }
    assert _geometry_contains(multi, -113.0, 53.5) is True
    assert _geometry_contains(multi, -118.5, 49.7) is True
    assert _geometry_contains(multi, -100.0, 20.0) is False


def test_malformed_geometry_is_not_a_match():
    assert _geometry_contains(None, -113.0, 53.5) is False
    assert _geometry_contains({}, -113.0, 53.5) is False
    assert _geometry_contains({"type": "Point", "coordinates": [1, 2]}, 1, 2) is False
    assert _geometry_contains({"type": "Polygon", "coordinates": "x"}, 1, 2) is False


def _now():
    return datetime(2026, 9, 10, 12, 0, tzinfo=timezone.utc)


def test_expired_alert_is_dropped():
    past = (_now() - timedelta(hours=1)).isoformat().replace("+00:00", "Z")
    assert _is_active({"expiration_datetime": past}, _now()) is False


def test_future_expiry_is_active():
    future = (_now() + timedelta(hours=3)).isoformat().replace("+00:00", "Z")
    assert _is_active({"expiration_datetime": future}, _now()) is True


def test_ended_status_is_dropped_even_before_expiry():
    """A cancelled warning must clear immediately, not linger until expiry."""
    future = (_now() + timedelta(hours=3)).isoformat().replace("+00:00", "Z")
    props = {"expiration_datetime": future, "status_en": "ended"}
    assert _is_active(props, _now()) is False


def test_missing_expiry_does_not_drop_the_alert():
    assert _is_active({}, _now()) is True


def test_unparseable_expiry_does_not_drop_the_alert():
    """Fail toward showing a life-safety message, not hiding it."""
    assert _is_active({"expiration_datetime": "not-a-date"}, _now()) is True


def test_warnings_outrank_watches_and_statements():
    ranks = [
        _severity_rank({"alert_type": t})
        for t in ["statement", "warning", "watch", "advisory"]
    ]
    assert ranks == [3, 0, 1, 2]
    assert _severity_rank({"alert_type": "WARNING"}) == 0
    assert _severity_rank({}) == 4


def test_alert_text_passes_through_verbatim():
    """ADR 0005 passive posture: no rewording, no truncation, no title-casing."""
    text = (
        "Tornado warning in effect. Take shelter immediately. "
        "Damaging winds of 100 km/h are possible.  Multiple  spaces kept."
    )
    feature = {
        "properties": {
            "feature_id": "fea1-1",
            "alert_name_en": "tornado warning",
            "alert_text_en": text,
            "risk_colour_en": "red",
            "feature_name_en": "Vegreville - Tofield",
            "province": "AB",
            "expiration_datetime": "2026-09-10T18:00:00Z",
        }
    }
    out = _normalize(feature)
    assert out["text"] == text
    assert out["name"] == "tornado warning"
    assert out["risk_colour"] == "red"
    assert out["region"] == "Vegreville - Tofield"
    assert out["id"] == "fea1-1"


def test_normalize_rejects_a_feature_with_no_name():
    assert _normalize({"properties": {}}) is None
    assert _normalize({}) is None


def _install_fake_feed(monkeypatch_target, features):
    alerts_service._alerts_cache.clear()
    alerts_service._http_get_json = lambda url, timeout=15.0: {"features": features}


def test_fetch_alerts_only_returns_polygons_containing_the_point():
    original = alerts_service._http_get_json
    try:
        future = (
            datetime.now(timezone.utc) + timedelta(hours=5)
        ).isoformat().replace("+00:00", "Z")
        near = {
            "geometry": _SQUARE,
            "properties": {
                "alert_name_en": "tornado warning",
                "alert_type": "warning",
                "alert_text_en": "Take shelter.",
                "expiration_datetime": future,
                "feature_id": "in",
            },
        }
        far = {
            "geometry": {
                "type": "Polygon",
                "coordinates": [
                    [
                        [-100.0, 20.0],
                        [-99.0, 20.0],
                        [-99.0, 21.0],
                        [-100.0, 21.0],
                        [-100.0, 20.0],
                    ]
                ],
            },
            "properties": {
                "alert_name_en": "heat warning",
                "alert_type": "warning",
                "expiration_datetime": future,
                "feature_id": "out",
            },
        }
        _install_fake_feed(alerts_service, [near, far])
        out = fetch_alerts(53.5, -113.0)
        assert [a["id"] for a in out] == ["in"]
    finally:
        alerts_service._http_get_json = original
        alerts_service._alerts_cache.clear()


def test_fetch_alerts_sorts_warnings_first():
    original = alerts_service._http_get_json
    try:
        future = (
            datetime.now(timezone.utc) + timedelta(hours=5)
        ).isoformat().replace("+00:00", "Z")

        def feature(kind, fid):
            return {
                "geometry": _SQUARE,
                "properties": {
                    "alert_name_en": f"{kind} thing",
                    "alert_type": kind,
                    "expiration_datetime": future,
                    "feature_id": fid,
                },
            }

        _install_fake_feed(
            alerts_service,
            [feature("statement", "s"), feature("warning", "w"), feature("watch", "x")],
        )
        out = fetch_alerts(53.5, -113.0)
        assert [a["id"] for a in out] == ["w", "x", "s"]
    finally:
        alerts_service._http_get_json = original
        alerts_service._alerts_cache.clear()


def test_fetch_alerts_safe_swallows_a_broken_feed():
    """The forecast must still render when the alert feed is down."""
    original = alerts_service._http_get_json

    def boom(url, timeout=15.0):
        raise RuntimeError("feed down")

    try:
        alerts_service._alerts_cache.clear()
        alerts_service._http_get_json = boom
        assert fetch_alerts_safe(53.5, -113.0) == []
    finally:
        alerts_service._http_get_json = original
        alerts_service._alerts_cache.clear()
