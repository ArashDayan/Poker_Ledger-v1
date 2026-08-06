Drop a Farsi-capable font here to fix two things at once:

1. In-app Persian typography (see the commented-out `fonts:` section in
   pubspec.yaml — uncomment it once the files are here).
2. Farsi text rendering in exported PDF reports (ExportService already
   tries to load these exact files automatically — see
   ExportService._tryLoadFarsiTheme in lib/services/export_service.dart).

Required filenames (both needed for the PDF export to pick them up):
  - Vazirmatn-Regular.ttf
  - Vazirmatn-Bold.ttf

Recommended source: https://github.com/rastikerdar/vazirmatn (OFL-licensed,
covers Persian + Latin script in one font, so it also works for English
sessions).

Not required for the app to run — nothing here is fetched automatically,
and everything falls back gracefully to the default font if these files
are absent. But note: without them, Farsi player names/text in exported
PDF reports will not render correctly, since the `pdf` package's default
font is Latin-only. This is a known limitation until the files are added.
