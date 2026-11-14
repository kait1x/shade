# Shade UI verification

These PNGs are rendered by the real Flutter screen widgets using `client/test/ui_design_test.dart`.
The chat names and message text are presentation fixtures. These are not screenshots of a live exchange or proof of Google authentication.

- `welcome.png`: Google sign-in screen, 390 × 844 logical pixels.
- `chats.png`: chat list, local search and saved filter.
- `conversation.png`: bubbles, dates, delivery/read icons, composer.
- `find-person.png`: contact discovery screen.
- `welcome-large-text.png`: 320 × 640, font scale 1.4, scrolled to the form.

Run from `client`: `flutter test test/ui_design_test.dart`.

Three broken Roboto font assets (HTML responses) were replaced with genuine TTF files. Font headers are checked by an automated test.

Latest renders: monochrome palette and redrawn solid ghost. Full Flutter suite: 18 passed. APK rebuilt; prior Android UI hierarchy/runtime log describes the earlier palette, not a new emulator run.

Profile continuation: `profile.png` and `profile-showcase.png` render the real ProfileScreen. Decorative phone frames, clock, nicknames, email, notes, public-key input and online status are test fixtures. Profile behavior, key change and narrow/large-text cases: `client/test/profile_preview_test.dart`.
