# Stratus (Flutter)

Provider-based streaming client for Android and iOS. One codebase.

## Setup

Needs Flutter 3.24 or newer (`flutter --version`).

```bash
flutter create stratus          # makes the android/ and ios/ folders
# copy this folder's lib/ and pubspec.yaml over the new project, replacing the originals
cd stratus
flutter pub get
```

### Android

1. In `android/app/src/main/AndroidManifest.xml`, inside `<manifest>` (above `<application>`), add:
   ```xml
   <uses-permission android:name="android.permission.INTERNET"/>
   ```
2. If a provider serves plain `http://` streams, add `android:usesCleartextTraffic="true"` to the `<application>` tag.
3. Run: `flutter run`
4. Build an installable file: `flutter build apk --release`
   (output: `build/app/outputs/flutter-apk/app-release.apk`)

### iPhone (needs a Mac with Xcode)

1. `cd ios && pod install && cd ..`
2. For plain `http://` streams, add this to `ios/Runner/Info.plist`:
   ```xml
   <key>NSAppTransportSecurity</key>
   <dict><key>NSAllowsArbitraryLoads</key><true/></dict>
   ```
3. Run: `flutter run`, or `flutter build ios --release`

If `flutter pub get` reports a version conflict, run `flutter pub upgrade`.

## Get an APK without a computer setup (GitHub Actions)

1. Push this repo to GitHub (it is already set up).
2. Open the repo, go to **Actions**, pick **Build APK**, then **Run workflow**. It also runs on every push to `main`.
3. When the run finishes (about 8 to 12 minutes), open it and download **stratus-apk** from the Artifacts section.
4. Unzip it, send `app-release.apk` to your phone, and install it. Android will ask you to allow installs from unknown sources.

The workflow generates the Android project on the fly, adds the INTERNET permission, and builds a release APK.
It is signed with the debug key, which is fine for personal use. A Play Store release needs your own signing key.

## Built-in provider

MovieBox is enabled by default. Its homepage is loaded from the MovieBox homepage API, including the featured banner and category shelves. Search filters titles returned by the homepage catalog. The supplied API guide does not include detail or playback endpoints, so streaming is not enabled yet.

## Additional providers

Settings → Add provider accepts:

- a Stremio addon link (`https://host/manifest.json`)
- a JSON catalog link, or catalog JSON pasted in
- a repository link (JSON with a `providers` list) that installs several at once

Catalog format:

```json
{ "name": "My catalog",
  "items": [
    { "id": "m1", "type": "movie", "title": "Title", "year": 2008,
      "poster": "https://…", "plot": "…",
      "sources": [{ "name": "720p", "url": "https://…/video.mp4" }] },
    { "id": "s1", "type": "series", "title": "Show",
      "episodes": [{ "season": 1, "episode": 1, "title": "Pilot",
        "sources": [{ "name": "HD", "url": "https://…/ep1.m3u8" }] }] } ] }
```

Repository format: `{ "name": "…", "providers": [{ "name": "…", "url": "https://…" }] }`

## Layout

| File | Role |
| --- | --- |
| `lib/models.dart` | Item, Episode, Source, ProviderDef |
| `lib/store.dart` | App state, saved on the device |
| `lib/providers.dart` | MovieBox, Stremio and JSON adapters, link detection |
| `lib/widgets.dart` | Poster cards, shelves, grids |
| `lib/home_page.dart`, `search_page.dart`, `library_page.dart`, `settings_page.dart` | Tabs |
| `lib/detail_page.dart`, `player_page.dart` | Title page and player (media_kit) |

## Speed notes

- Poster rows use `ListView.builder` with a fixed `itemExtent`, so only visible cards are built.
- Posters are decoded at 360px wide (`memCacheWidth`) and cached on disk and in memory.
- Progress is written at most every 5 seconds, and only the "Continue watching" row rebuilds.
- Torrent streams are not supported. Only direct http(s) video links play.
