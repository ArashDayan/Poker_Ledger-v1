# Building Poker Ledger V2

This archive is a complete Flutter project: `lib/`, `assets/`, `android/`,
`ios/`, `web/`, `test/` and all configuration. Open the folder directly in
Android Studio or VS Code.

## Requirements

* Flutter **3.19+** (Dart 3.3+)
* JDK **17** (Android Gradle Plugin 8.x will not run on JDK 11)
* Android SDK **34**

Check with `flutter doctor -v` before building.

## Build an APK

```bash
cd PokerLedger-V2
flutter pub get
flutter build apk --release
```

Output: `build/app/outputs/flutter-apk/app-release.apk`

Smaller, per-architecture APKs (recommended for sideloading):

```bash
flutter build apk --split-per-abi
```

For the Play Store, build an App Bundle instead:

```bash
flutter build appbundle --release
```

## Run on a connected device

```bash
flutter devices
flutter run --release
```

## Notes on this project

**`android/` and `ios/` were hand-written for this package.** The
repository never had `flutter create` run against it, so no platform
folders existed and earlier archives could not be built. They are
complete and correct, but if Gradle ever complains about a mismatch with
your Flutter version, the officially generated equivalents can be
regenerated over the top without losing any app code:

```bash
flutter create --platforms=android,ios .
```

That command only writes missing platform scaffolding — it does not touch
`lib/`, `assets/` or `pubspec.yaml`. Afterwards, re-apply the two settings
that are specific to this app if the tool overwrites them:

* `applicationId` / `namespace` = `com.pokerledger.app`
* `minSdk = 23` (required by `audioplayers` 6.x)

**Launcher icons are already generated** at every density in
`android/app/src/main/res/mipmap-*` and
`ios/Runner/Assets.xcassets/AppIcon.appiconset`, from the supplied brand
logo. To regenerate after changing the logo:

```bash
python3 tool/install_logo.py assets/images/logo_source.jpg
dart run flutter_launcher_icons
```

**`pubspec.lock` is not included.** The previously committed lock predated
the `audioplayers` dependency and would have failed version resolution.
`flutter pub get` will produce a correct one.

**Signing.** Release builds fall back to debug signing so a fresh clone
produces an installable APK immediately. For a distributable build, create
`android/key.properties`:

```properties
storePassword=<password>
keyPassword=<password>
keyAlias=<alias>
storeFile=<absolute path to keystore.jks>
```

`android/app/build.gradle` picks it up automatically when present.

## Verify before shipping

```bash
flutter analyze
flutter test
```

`test/` contains the settlement-engine, tournament, multi-table, privacy
and chip-sound suites.
