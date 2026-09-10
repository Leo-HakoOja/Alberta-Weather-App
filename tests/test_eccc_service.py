"""Regression tests for the ECCC site cache.

`_EcccSite` is declared `@dataclass(slots=True)`, so it has no `__dict__`. The site
cache originally serialised with `site.__dict__`, which raised AttributeError on every
cache write. That broke ECCC for any location that did not hit the KNOWN_ALBERTA_SITES
name shortcut, which in practice meant every location the user picked by coordinates.

It stayed invisible in production because the failure is swallowed into a per-source
`error` field, and the UI that would have displayed it was never mounted.
"""

import sys
from dataclasses import asdict
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from backend.app import eccc_service  # noqa: E402
from backend.app.eccc_service import _EcccSite  # noqa: E402

_SITES = [
    _EcccSite(site_id="ab-50", name="Edmonton", latitude=53.55, longitude=-113.49),
    _EcccSite(site_id="ab-52", name="Calgary", latitude=51.05, longitude=-114.07),
]


def test_ecccsite_has_no_dunder_dict():
    """Pins the reason the bug existed. If this ever fails, slots was removed."""
    site = _SITES[0]
    assert not hasattr(site, "__dict__")


def test_asdict_serialises_a_slots_dataclass():
    raw = asdict(_SITES[0])
    assert raw == {
        "site_id": "ab-50",
        "name": "Edmonton",
        "latitude": 53.55,
        "longitude": -113.49,
    }


def test_cached_sites_round_trip_back_into_dataclasses():
    """The cache stores dicts and rehydrates with _EcccSite(**raw)."""
    serialised = [asdict(site) for site in _SITES]
    restored = [_EcccSite(**raw) for raw in serialised]
    assert restored == _SITES


def test_resolve_site_code_uses_the_cache_without_network():
    saved = eccc_service._alberta_sites_cache
    try:
        import time

        eccc_service._alberta_sites_cache = (
            time.time(),
            [asdict(site) for site in _SITES],
        )
        # No name given, so this must go through the cache path that used to raise.
        assert eccc_service.resolve_site_code(None, 53.55, -113.49) == "ab-50"
        assert eccc_service.resolve_site_code(None, 51.05, -114.07) == "ab-52"
    finally:
        eccc_service._alberta_sites_cache = saved


def test_far_from_any_site_returns_none():
    """Outside Alberta must resolve to no site rather than the nearest one."""
    saved = eccc_service._alberta_sites_cache
    try:
        import time

        eccc_service._alberta_sites_cache = (
            time.time(),
            [asdict(site) for site in _SITES],
        )
        # Vancouver is well past the 250 km cutoff from any Alberta site.
        assert eccc_service.resolve_site_code(None, 49.28, -123.12) is None
    finally:
        eccc_service._alberta_sites_cache = saved
