# Changelog

All notable changes to `rules_flutter` are documented here. The format is based
on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project
aims to follow [Semantic Versioning](https://semver.org/spec/v2.0.0.html) once
it reaches 1.0.

## [Unreleased]

### Added

- Hermetic Flutter toolchains via the `flutter` module extension (no host
  Flutter install required), with per-platform SDK provisioning and a sealed,
  read-only SDK cache.
- `pub` module extension that scans checked-in `pub_deps.json` files and creates
  one Bazel repository per hosted package.
- Core rules: `flutter_library`, `dart_library`, `flutter_app` (web + Android
  APK/AppBundle + iOS), `flutter_test`, `flutter_analyze_test`,
  `dart_format_test`, and `dart_proto_library` (protobuf → Dart).
- `build_runner` integration and generated run helpers
  (`{name}.update`/`.format`/`.sync`/`.dev`/`.build_runner_*`).
- `flutter_build_settings` macro for release/mode/build-number configuration.
- Version escape hatch: `flutter.toolchain(flutter_version, integrity = {...})`
  for versions not in the built-in table, bound to their exact version.
- Gazelle language support for generating Flutter/Dart BUILD files.
- Performance: opt-in `build_runner` incremental cache, split pub-cache
  assembly, per-package staging fast path, and local-execution-with-remote-cache
  defaults for heavy actions (`--//flutter:allow_remote_execution` to opt in).

### Changed

- Semver-aware toolchain version selection (previously lexicographic).

### Removed

- Deprecated, ignored `dart_proto_library` `options`/`grpc` attributes.

<!--
On release, cut a versioned section here, e.g.:

## [0.1.0] - 2026-XX-XX
-->

[Unreleased]: https://github.com/SpencerC/rules_flutter/commits/main
