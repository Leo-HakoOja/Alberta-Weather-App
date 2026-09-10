# WeatherKit joins as the third forecast source, signed server-side

Apple WeatherKit becomes the third **Weather Source** behind
[ADR 0001](0001-multi-source-side-by-side.md)'s side-by-side comparison, alongside
Open-Meteo and ECCC. It is called from the backend over the REST API, not from the app
via the native framework.

## Why the REST API and not the WeatherKit framework

The native framework is the obvious-looking choice and is wrong here:

- It is iOS only. The backend already fans out to Open-Meteo and ECCC and returns a
  `sources[]` array that both platforms consume. Calling WeatherKit from the app would
  split the comparison logic across two places and leave Android with two sources while
  iOS had three.
- It would bypass the backend's caching entirely, turning one cached fan-out per location
  into one call per device.

Server-side REST keeps all three sources in one place with one cache and one shape.

## Why a dependency was accepted

Signing a WeatherKit request needs an ES256 (ECDSA P-256) JWT. Python's standard library
has no ECDSA, so this could not be done without either a library or the `openssl` binary.

Both were evaluated properly rather than assumed. A zero-dependency prototype was written
first and **verified working against the live API** (HTTP 200, real observations for
Myrnam) using `openssl` plus stdlib, including the DER to raw `r||s` signature conversion.

It was still rejected for production:

- The deploy image is `python:3.12-slim`, which ships `libssl` but does not guarantee the
  `openssl` **command-line binary**. The no-dependency path would therefore have required
  an `apt-get install openssl` layer in the Dockerfile.
- That trades a pinned, version-locked pip dependency for an unpinned system binary
  assumption, plus a Dockerfile change, plus a subprocess in the request path. Strictly
  worse on every axis.
- The DER to raw conversion is the classic silent failure in hand-rolled ES256: the token
  looks well-formed and Apple rejects the signature. That belongs in a library.

**Installed:** `PyJWT[crypto]>=2.13.0,<3.0.0` (PyJWT is MIT; it pulls `cryptography`,
maintained by the Python Cryptographic Authority). Added to `backend/requirements.txt`.

**Reversal path:** remove the line from `requirements.txt`, `pip uninstall pyjwt
cryptography`, delete `app/weatherkit_service.py` and its call site, redeploy. Nothing
else references it.

## Credentials

WeatherKit needs three identifiers and a private key. None of them are in the repo.

- Team ID, Services ID and Key ID live in `~/.config/apple-weatherkit/config.json`
- The `.p8` private key lives at `~/.config/apple-weatherkit/key` (mode 600)

This follows the operator's standing convention that credentials live under
`~/.config/<service>/` and never per-project. In production the same values are supplied
as environment variables, because the fly.io container has no access to the operator's
home directory.

Two things that cost time and are recorded so they are not re-derived:

- **A Services ID generates no code.** The reverse-domain identifier you type when
  registering it *is* the value. There is no second screen and nothing to download.
- **The Key ID is the 10 characters in the `AuthKey_XXXXXXXXXX.p8` filename.**
- A `401 NOT_ENABLED` means the WeatherKit capability on the App ID is missing or still
  propagating (up to ~30 minutes). A malformed token returns 400, so 401 specifically
  points at the capability rather than the JWT.

## Attribution is a review requirement, not a nicety

WeatherKit requires the Apple Weather mark and a legal attribution link, fetched from
`https://weatherkit.apple.com/attribution/{locale}`. This is enforced at App Review.

It does **not** go in the portfolio footer, which is the app's only commercial element
under **Ad-Free**. It goes on a settings or about surface, which is where other apps have
had it accepted.

## Consequences

- The "multi-source" claim finally means three sources rather than two.
- Free tier is 500,000 calls/month with the Developer Program membership; paid tiers start
  around $49.99/month for 1M. With backend caching this is not a near-term cost.
- WeatherKit failing must degrade to two sources, never take the forecast down. Same
  posture as the ECCC source and the alert feed.
- Tokens are valid for up to an hour and are cached rather than signed per request.
