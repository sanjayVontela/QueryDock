# QueryDock

QueryDock is a cross-platform PostgreSQL workbench built with Flutter. It
provides a database navigator, SQL editor and autocomplete, editable result
grids, schema diagrams, connection protection, and optional AI-assisted query
generation.

## Download

Prebuilt Windows releases are available from the repository's
[Releases](https://github.com/sanjayVontela/db-viewer/releases) page.

1. Download `QueryDock-vX.Y.Z-windows-x64.zip`.
2. Extract the complete ZIP.
3. Run `querydock.exe`.

Windows may display a SmartScreen warning until release binaries are signed
with a trusted code-signing certificate.

## Development

```powershell
flutter pub get
flutter run -d windows
```

Run the checks before submitting a change:

```powershell
dart analyze
flutter test
```

## Creating A Release

Update the version in `pubspec.yaml`, commit the release, then push a version
tag:

```powershell
git tag v1.0.0
git push origin v1.0.0
```

The release workflow builds and tests QueryDock on GitHub, packages the full
Windows runtime, creates a SHA-256 checksum, and publishes both files under
GitHub Releases.
