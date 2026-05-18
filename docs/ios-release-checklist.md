# iOS Release Checklist (Alberta Weather)

Use this checklist to go from current Flutter app to TestFlight/App Store.

## 0) Reality check

- **Tonight TestFlight:** realistic if signing + metadata are completed and app build is stable.
- **Tonight App Store public launch:** possible but **unlikely**. Apple review commonly takes 24h+ for a new app/account.

## 1) App Store Connect + Apple Developer setup

1. Create app in **App Store Connect**.
2. Create/register final **Bundle ID** in Apple Developer portal.
3. Ensure paid agreements, tax, and banking are complete.
4. Create App Store Connect API key (optional, for CI/Fastlane later).

## 2) Project identifiers and versions

Current defaults still need replacement:

- `mobile/flutter_app/ios/Runner.xcodeproj/project.pbxproj`
  - `PRODUCT_BUNDLE_IDENTIFIER = com.example.flutterApp;`
- `mobile/flutter_app/ios/Runner/Info.plist`
  - `CFBundleDisplayName = Flutter App`

Set final values in Xcode:

- Bundle Identifier: e.g. `com.yourcompany.albertaweather`
- Display Name: `Alberta Weather`
- Version: start with `1.0.0`
- Build number: increment each upload (`1`, `2`, ...)

## 3) API environment

For production builds, use hosted backend URL:

- `--dart-define=WEATHER_API_URL=https://<your-domain>/v1/weather/myrnam`

Do **not** ship with localhost URLs.

## 4) iOS assets + product polish

1. Replace AppIcon set (`ios/Runner/Assets.xcassets/AppIcon.appiconset`).
2. Verify launch screen and app name branding.
3. Confirm no debug text remains.
4. Test on a physical iPhone (not just simulator/web).

## 5) Privacy/compliance

1. Add Privacy Policy URL (public web page).
2. Complete App Privacy questionnaire in App Store Connect.
3. Add weather data attribution if required by data provider terms.
4. Fill category, age rating, support URL, and screenshots.

## 6) Build and upload

On macOS with Xcode and Flutter installed:

```bash
cd ~/weather-app/mobile/flutter_app
flutter clean
flutter pub get
flutter build ipa --release \
  --dart-define=WEATHER_API_URL=https://<your-domain>/v1/weather/myrnam \
  --build-name=1.0.0 \
  --build-number=1
```

Then upload via:

- Xcode Organizer (recommended first upload), or
- Transporter app.

## 7) TestFlight rollout

1. Add internal testers first.
2. Smoke test key flows: launch, location change, refresh, hourly/daily details.
3. Submit to external testers (if needed).

## 8) App Store submission

1. Select tested build.
2. Complete metadata and submit for review.
3. Respond quickly to any reviewer request.

---

## Minimum tonight plan (high probability)

1. Finalize bundle ID + display name.
2. Build and upload one clean TestFlight build.
3. Complete metadata + privacy answers.
4. Submit for review before end of day.

This gets you as close as possible to launch, with review time the main variable.
