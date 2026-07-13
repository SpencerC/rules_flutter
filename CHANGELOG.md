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
- `flutter_test`: Bazel `shard_count` support (deterministic runner-side
  partition; empty shards pass), a `jobs` attr (`flutter test -j`) to cap
  internal concurrency, and an optional `cpu` attr declaring a local CPU
  reservation. `flutter_analyze_test` gains `cpu` too.
- `pub_cache_materialization` attr on `flutter_test`/`flutter_analyze_test`:
  `auto` (default) APFS-clones the test-time pub cache on macOS and
  byte-copies elsewhere (both writable, like before); `hardlink` opts into
  near-instant read-only linking; `reference` skips materialization entirely;
  `copy` pins the historical behavior. The goldens action stages its cache
  with the same clone-or-copy strategy.
- `dart_proto_library` supports proto toolchain resolution
  (`--incompatible_enable_proto_toolchain_resolution`): protoc comes from the
  resolved proto toolchain (e.g. a prebuilt binary registered by
  `toolchains_protoc`) instead of the source-built `@protobuf//:protoc`,
  keeping protobuf's C++ compilation graph out of analysis. Without the flag,
  behavior is unchanged. The e2e workspace registers `toolchains_protoc` so
  flag-on runs exercise the prebuilt path.

### Changed

- **Breaking:** the Gazelle plugin moved into its own Bazel module,
  `rules_flutter_gazelle`, published from the same repository and release
  tag. Labels changed from `@rules_flutter//gazelle/{flutter,dartproto}` to
  `@rules_flutter_gazelle//{flutter,dartproto}`, and consumers add
  `bazel_dep(name = "rules_flutter_gazelle", ..., dev_dependency = True)`.
  Plain `rules_flutter` consumers no longer resolve `rules_go`, Gazelle, a
  Go SDK, or Go module dependencies at all — previously these were non-dev
  dependencies inherited by every consumer.
- Release archives stamp the real version into both modules' `MODULE.bazel`
  (main carries `0.0.0` between releases).
- Semver-aware toolchain version selection (previously lexicographic).
- Generated pub-repository BUILD files expose the vendored `.pub_cache` (and
  other non-`lib`/`bin` top-level directories in `<package>_files`) as
  source-directory artifacts instead of recursive per-file globs. A
  pub.package closure runs to tens of thousands of files, and file-level
  globs made each one a configured target — ~40k targets and ~150s of cold
  analysis for `protoc_plugin` alone in the `dart_proto_library` aspect
  graph; directory artifacts collapse that to seconds. Repo contents only
  change on refetch, so invalidation is unaffected in normal operation
  (hand-editing files under `external/` now requires `bazel fetch --force`
  to be picked up; set
  `startup --host_jvm_args=-DBAZEL_TRACK_SOURCE_DIRECTORIES=1` to restore
  content-level tracking). Existing `DartProtoCompile` results re-execute
  once after upgrading (action inputs changed shape).
- Large tree outputs (assembled pub cache, prepared/overlay workspaces, the
  workspace seed) now default to `no-remote-cache`: uploading them on every
  source change drained CI invocations for minutes while rebuilding them
  locally takes seconds, and they stay eligible for the local disk cache.
  Opt back in with `--//flutter:remote_cache_trees`. Staged pub packages,
  golden renders, and `flutter build` outputs remain remotely cached.

### Fixed

- Targets in the repository root package no longer flatten their `srcs` to
  basenames when staging app/test workspaces (`test/` and `web/` trees kept
  their layout only for targets living in a subpackage).

### Removed

- Deprecated, ignored `dart_proto_library` `options`/`grpc` attributes.

<!--
On release, cut a versioned section here, e.g.:

## [0.1.0] - 2026-XX-XX
-->

[Unreleased]: https://github.com/SpencerC/rules_flutter/commits/main
