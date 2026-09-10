"""Apple WeatherKit as the third forecast source.

See ADR 0009. Called server-side over the REST API rather than from the app via the
native framework, so all three sources share one cache and one shape and Android is not
left with fewer sources than iOS.

Credentials are never in the repo. In development they come from
`~/.config/apple-weatherkit/`; in production from environment variables, because the
container has no access to the operator's home directory.
"""

from __future__ import annotations

import json
import os
import re
import time
from datetime import datetime, timezone
from urllib.error import HTTPError, URLError
from urllib.parse import urlencode
from urllib.request import Request, urlopen

from .weather_service import (
    WeatherServiceError,
    format_iso_label,
    wind_direction_to_compass,
)

SOURCE_ID = "apple-weatherkit"
SOURCE_NAME = "Apple Weather"
ATTRIBUTION_URL = "https://weatherkit.apple.com/attribution/en-CA"

WEATHERKIT_BASE_URL = "https://weatherkit.apple.com/api/v1/weather"
CONFIG_DIR = os.path.expanduser("~/.config/apple-weatherkit")

# Apple allows up to an hour. Sign well inside that so a token cannot expire
# mid-flight, and so clock skew between here and Apple is not fatal.
TOKEN_LIFETIME_SECONDS = 3600
TOKEN_REFRESH_MARGIN_SECONDS = 300

_token_cache: tuple[float, str] | None = None


class WeatherKitNotConfigured(WeatherServiceError):
    """Raised when credentials are absent.

    Distinct from a request failure: a machine with no WeatherKit credentials is a
    normal development state, not an outage.
    """


def _load_credentials() -> dict:
    """Environment first, then the operator's config directory.

    Production sets environment variables via `fly secrets set`. Development reads
    `~/.config/apple-weatherkit/`, per the standing convention that credentials live
    under `~/.config/<service>/` and never per-project.
    """
    team_id = os.environ.get("WEATHERKIT_TEAM_ID")
    services_id = os.environ.get("WEATHERKIT_SERVICES_ID")
    key_id = os.environ.get("WEATHERKIT_KEY_ID")
    private_key = os.environ.get("WEATHERKIT_PRIVATE_KEY")

    if not (team_id and services_id and key_id):
        config_path = os.path.join(CONFIG_DIR, "config.json")
        try:
            with open(config_path, encoding="utf-8") as handle:
                config = json.load(handle)
        except (OSError, json.JSONDecodeError) as err:
            raise WeatherKitNotConfigured(
                f"WeatherKit identifiers not in the environment and {config_path} "
                f"could not be read: {err}"
            ) from err
        team_id = team_id or config.get("team_id")
        services_id = services_id or config.get("services_id")
        key_id = key_id or config.get("key_id")

    if not private_key:
        key_path = os.environ.get("WEATHERKIT_KEY_PATH") or os.path.join(
            CONFIG_DIR, "key"
        )
        try:
            with open(key_path, encoding="utf-8") as handle:
                private_key = handle.read()
        except OSError as err:
            raise WeatherKitNotConfigured(
                f"WeatherKit private key unreadable at {key_path}: {err}"
            ) from err

    missing = [
        name
        for name, value in (
            ("team_id", team_id),
            ("services_id", services_id),
            ("key_id", key_id),
            ("private_key", private_key),
        )
        if not value or str(value).strip() in {"", "FILL_IN"}
    ]
    if missing:
        raise WeatherKitNotConfigured(
            f"WeatherKit credentials incomplete: {', '.join(missing)}"
        )

    return {
        "team_id": str(team_id).strip(),
        "services_id": str(services_id).strip(),
        "key_id": str(key_id).strip(),
        "private_key": private_key,
    }


def _signed_token() -> str:
    """A cached ES256 JWT for WeatherKit.

    Signing is not free, and the token is valid for an hour, so it is reused rather
    than minted per request.
    """
    global _token_cache

    now = time.time()
    if _token_cache and now < _token_cache[0]:
        return _token_cache[1]

    # Imported here so a machine without the dependency still serves the other two
    # sources instead of failing at import time.
    try:
        import jwt
    except ImportError as err:  # pragma: no cover - dependency is pinned
        raise WeatherKitNotConfigured(f"PyJWT is not installed: {err}") from err

    credentials = _load_credentials()
    issued_at = int(now)
    expires_at = issued_at + TOKEN_LIFETIME_SECONDS

    try:
        token = jwt.encode(
            {
                "iss": credentials["team_id"],
                "iat": issued_at,
                "exp": expires_at,
                "sub": credentials["services_id"],
            },
            credentials["private_key"],
            algorithm="ES256",
            headers={
                "kid": credentials["key_id"],
                "id": f"{credentials['team_id']}.{credentials['services_id']}",
            },
        )
    except Exception as err:  # noqa: BLE001 - surfaces as a source-level error
        raise WeatherServiceError(f"Could not sign WeatherKit token: {err}") from err

    _token_cache = (expires_at - TOKEN_REFRESH_MARGIN_SECONDS, token)
    return token


def _humanize_condition(code: object) -> str:
    """`MostlyCloudy` becomes `Mostly cloudy`.

    WeatherKit returns CamelCase condition codes while the other sources return prose.
    Presenting them side by side means they have to read alike.
    """
    if not isinstance(code, str) or not code.strip():
        return "-"
    spaced = re.sub(r"(?<!^)(?=[A-Z])", " ", code.strip())
    return spaced[0].upper() + spaced[1:].lower()


def _percent(value: object) -> float | None:
    """WeatherKit reports humidity and precipitation chance as 0-1 fractions.

    Open-Meteo and ECCC report percentages. Without this the comparison strip would
    show 0.6 next to 60 and look broken.
    """
    if not isinstance(value, (int, float)):
        return None
    return round(float(value) * 100, 1)


def _as_float(value: object) -> float | None:
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        return None
    return float(value)


def _normalize_current(current: dict) -> dict | None:
    if not isinstance(current, dict):
        return None

    bearing = _as_float(current.get("windDirection"))
    daylight = current.get("daylight")

    return {
        "time": current.get("asOf") if isinstance(current.get("asOf"), str) else None,
        "temperature": _as_float(current.get("temperature")),
        "apparent_temperature": _as_float(current.get("temperatureApparent")),
        "humidity": _percent(current.get("humidity")),
        "wind_speed": _as_float(current.get("windSpeed")),
        "wind_direction_degrees": bearing,
        "wind_direction_compass": wind_direction_to_compass(bearing),
        "uv_index": _as_float(current.get("uvIndex")),
        "weather_code": None,
        "weather": _humanize_condition(current.get("conditionCode")),
        "sunrise": None,
        "sunset": None,
        "is_daylight": daylight if isinstance(daylight, bool) else None,
    }


def _normalize_hourly(payload: dict) -> list[dict]:
    hours = (payload.get("forecastHourly") or {}).get("hours")
    if not isinstance(hours, list):
        return []

    items: list[dict] = []
    for hour in hours[:24]:
        if not isinstance(hour, dict):
            continue
        start = hour.get("forecastStart")
        if not isinstance(start, str):
            continue
        bearing = _as_float(hour.get("windDirection"))
        daylight = hour.get("daylight")
        items.append(
            {
                "time": start,
                "label": format_iso_label(start, "%H:%M"),
                "weather_code": None,
                "weather": _humanize_condition(hour.get("conditionCode")),
                "temperature": _as_float(hour.get("temperature")),
                "apparent_temperature": _as_float(hour.get("temperatureApparent")),
                "humidity": _percent(hour.get("humidity")),
                "wind_speed": _as_float(hour.get("windSpeed")),
                "wind_direction_degrees": bearing,
                "wind_direction_compass": wind_direction_to_compass(bearing),
                "uv_index": _as_float(hour.get("uvIndex")),
                "precipitation_probability": _percent(hour.get("precipitationChance")),
                "precipitation_amount_mm": _as_float(hour.get("precipitationAmount")),
                "is_daylight": daylight if isinstance(daylight, bool) else None,
            }
        )
    return items


def _normalize_daily(payload: dict) -> list[dict]:
    days = (payload.get("forecastDaily") or {}).get("days")
    if not isinstance(days, list):
        return []

    items: list[dict] = []
    for day in days[:7]:
        if not isinstance(day, dict):
            continue
        start = day.get("forecastStart")
        if not isinstance(start, str):
            continue
        sunrise = day.get("sunrise")
        sunset = day.get("sunset")
        items.append(
            {
                "date": start[:10],
                "label": format_iso_label(start, "%a"),
                "weather_code": None,
                "weather": _humanize_condition(day.get("conditionCode")),
                "temperature_min": _as_float(day.get("temperatureMin")),
                "temperature_max": _as_float(day.get("temperatureMax")),
                "uv_index_max": _as_float(day.get("maxUvIndex")),
                "precipitation_probability_max": _percent(
                    day.get("precipitationChance")
                ),
                "precipitation_amount_mm": _as_float(day.get("precipitationAmount")),
                "sunrise": sunrise if isinstance(sunrise, str) else None,
                "sunset": sunset if isinstance(sunset, str) else None,
            }
        )
    return items


def fetch_weatherkit_source(
    latitude: float, longitude: float, timezone_name: str = "America/Edmonton"
) -> dict:
    """Build a `SourceForecast`-shaped dict for WeatherKit, or an error stub.

    Mirrors `fetch_eccc_source`: this never raises. WeatherKit failing must degrade the
    comparison to two sources, never take the forecast down.
    """
    base: dict = {
        "source_id": SOURCE_ID,
        "source_name": SOURCE_NAME,
        "attribution_url": ATTRIBUTION_URL,
        "fetched_at": datetime.now(timezone.utc).isoformat(),
        "current": None,
        "hourly_next_24h": [],
        "daily_7d": [],
        "error": None,
    }

    try:
        token = _signed_token()
    except WeatherKitNotConfigured as err:
        base["error"] = f"WeatherKit not configured: {err}"
        return base
    except WeatherServiceError as err:
        base["error"] = str(err)
        return base

    query = urlencode(
        {
            "dataSets": "currentWeather,forecastHourly,forecastDaily",
            "timezone": timezone_name,
        }
    )
    url = f"{WEATHERKIT_BASE_URL}/en_CA/{latitude}/{longitude}?{query}"
    request = Request(url, headers={"Authorization": f"Bearer {token}"})

    try:
        with urlopen(request, timeout=15) as response:
            payload = json.loads(response.read().decode("utf-8"))
    except HTTPError as err:
        detail = ""
        try:
            detail = err.read().decode("utf-8", errors="replace")[:200]
        except Exception:  # noqa: BLE001 - best-effort detail only
            pass
        hint = ""
        if err.code == 401:
            # 400 means a malformed token; 401 points at the App ID capability.
            hint = " (check the WeatherKit capability on the App ID)"
        base["error"] = f"WeatherKit request failed {err.code}{hint}: {detail}"
        return base
    except URLError as err:
        base["error"] = f"Network error contacting WeatherKit: {err.reason}"
        return base
    except json.JSONDecodeError as err:
        base["error"] = f"Failed to parse WeatherKit response: {err}"
        return base

    if not isinstance(payload, dict):
        base["error"] = "Unexpected WeatherKit response shape"
        return base

    base["current"] = _normalize_current(payload.get("currentWeather") or {})
    base["hourly_next_24h"] = _normalize_hourly(payload)
    base["daily_7d"] = _normalize_daily(payload)
    return base
