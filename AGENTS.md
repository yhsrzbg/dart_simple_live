# Repository Guidelines

## Project Structure & Module Organization
This repository is a multi-package Dart/Flutter workspace:
- `simple_live_core/`: shared live-platform parsing, models, danmaku, and network logic (`lib/src/...`).
- `simple_live_app/`: main Flutter mobile/desktop app.
- `simple_live_tv_app/`: Flutter Android TV client.
- `simple_live_console/`: CLI wrapper around `simple_live_core`.
- `.github/workflows/`: CI/CD build and release pipelines.
- `assets/`: shared branding/screenshots for docs and releases.

Keep feature code inside the relevant package; only move logic into `simple_live_core` when reused by 2+ clients.

## Build, Test, and Development Commands
Run commands from each package directory unless noted.
- `flutter pub get` / `dart pub get`: install dependencies.
- `flutter run` (app/tv): run locally on connected device/emulator.
- `flutter test` (app/tv) and `dart test` (core/console): run tests.
- `flutter analyze` or `dart analyze`: static analysis using package lint config.
- `flutter build apk --release --split-per-abi` (app/tv): Android release build (matches CI).

Example:
```bash
cd simple_live_core
dart test
```

## Coding Style & Naming Conventions
- Follow `analysis_options.yaml` in each package (`flutter_lints` for app/tv, `lints` for core/console).
- Use `dart format .` before committing.
- Indentation: 2 spaces (Dart standard).
- Naming: `snake_case.dart` files, `PascalCase` classes/widgets, `camelCase` members.
- Prefer small, composable services/widgets under existing folders (`modules/`, `services/`, `widgets/`).

## Testing Guidelines
- Test framework: `flutter_test` (Flutter apps) and `package:test` (Dart packages).
- Place tests under each package¡¯s `test/` directory.
- Name tests `*_test.dart` and mirror source scope when possible.
- Add or update tests for parser/network changes in `simple_live_core` and behavior/UI logic in app/tv packages.

## Commit & Pull Request Guidelines
- Follow existing commit style: short imperative subject, often with scope prefix (for example `ci: ...`, `Fix ...`, `Update ...`, `Add ...`).
- Keep commits focused by package/concern.
- PRs should include:
  - clear summary and motivation,
  - linked issue(s),
  - test/analyze results,
  - screenshots or recordings for UI changes (mobile/TV/desktop).
- If release behavior changes, mention affected workflow(s) in `.github/workflows/`.
