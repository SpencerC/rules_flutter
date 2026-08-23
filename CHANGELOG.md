# Changelog

All notable changes to `rules_flutter` are documented here. The format is based
on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project
aims to follow [Semantic Versioning](https://semver.org/spec/v2.0.0.html) once
it reaches 1.0.

## [Unreleased]

## [0.3.0] - 2026-08-23

### Changed

- **Breaking:** `//flutter:remote_cache_trees` is a string flag taking `none`
  (default), `workspaces` or `all` instead of a boolean. The assembled pub
  cache and the prepared/overlay workspaces have very different economics — a
  worker must materialize the pub cache locally either way, while remote-caching
  the workspaces replaces a full `intl_utils` plus `build_runner` run with a
  ~180MB download — so they are no longer one decision. Migration:
  `--//flutter:remote_cache_trees` becomes
  `--//flutter:remote_cache_trees=all`.

  The setting classifies _actions_, not individual outputs, so an action that
  declares both kinds of tree counts as a pub cache and stays local under
  `workspaces`. That is the dependency-preparation action of a library with
  `assemble_dep_caches = False`, and of a pub package that assembles; the
  default library path assembles in a separate action and is unaffected.

- `docs/hermeticity.md` records what `remote_cache_trees=workspaces` can and
  cannot achieve: the prepared trees are not reproducible (`.dart_tool` embeds
  the producing sandbox's execroot in text _and_ inside the host native-asset
  binaries JIT codegen links, where load commands cannot be rewritten), and the
  SDK filegroup contributes 51 mtime-fingerprinted source directories. Sharing
  therefore works between workers that share an output base or a fetched SDK,
  and not between independently provisioned ones.

### Fixed

- `PrepareFlutterAppWorkspace` carries the same execution posture as every
  other tree-producing action. It had none, so a ~100MB rsync of the library
  workspace was remote-execution eligible (which would upload its
  `no-remote-cache` input tree) and its own ~100MB output was uploaded on every
  build under `--remote_upload_local_results` — the drain
  `//flutter:remote_cache_trees` exists to prevent.
- The dependency-preparation log (`<name>_pub_prepare.log`) no longer records a
  wall-clock timestamp. It is a declared output, so the clock reading made the
  action gratuitously unreproducible.

## [0.2.1] - 2026-07-14

### Fixed

- `dart_format_test` actually checks formatting now. The runner embedded a
  newline-joined `$'...'` literal that bash never word-splits, so
  `dart format` received one newline-joined pseudo-path, printed "No file or
  directory found", formatted nothing, and exited 0 — the gate passed
  vacuously on every multi-file target since its introduction. File lists
  are now emitted as properly quoted shell array literals, and an empty
  list fails loudly. The same latent pattern in the `flutter_test` runner
  (harmless with zero or one `test_files` entries, broken with several) is
  fixed the same way.
- The `pub` extension's `pub_deps.json` scan honors the consuming
  workspace's `.bazelignore`: stale copies inside ignored trees (nested
  workspaces, tool worktrees, vendored checkouts) no longer join — or
  version-conflict with — the real dependency scan.

## [0.2.0] - 2026-07-14

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
- Linux hosts no longer fail against the sealed SDK cache with older Flutter
  versions (e.g. 3.24): the fetch-time ios-usb artifact materialization now
  covers both artifact-name generations (`usbmuxd` as well as `libusbmuxd`),
  so the tool's up-to-date probe passes instead of rewriting
  `usbmuxd.stamp` into the read-only cache on every invocation.
- The `shell_example` smoke test resolves the SDK binaries through
  `$(rlocationpath ...)` and the runfiles library instead of a hardcoded
  canonical repository name, follows the documented launcher contract
  (`FLUTTER_ALREADY_LOCKED`, scratch `HOME`), and is wired into the e2e
  suite.

### Removed

- Deprecated, ignored `dart_proto_library` `options`/`grpc` attributes.

[Unreleased]: https://github.com/SpencerC/rules_flutter/compare/v0.3.0...HEAD
[0.3.0]: https://github.com/SpencerC/rules_flutter/compare/v0.2.1...v0.3.0
[0.2.1]: https://github.com/SpencerC/rules_flutter/compare/v0.2.0...v0.2.1
[0.2.0]: https://github.com/SpencerC/rules_flutter/commits/v0.2.0
