# Repository Guidelines

## Project Structure & Module Organization

- Root: `MODULE.bazel`, `.bazelrc`, `BUILD.bazel`, `WORKSPACE.bazel`.
- Rules: `flutter/*.bzl` (public), `flutter/private/*` (internal helpers, toolchains).
- Tests: `flutter/tests/*` (unit/toolchain), `e2e/smoke/*` (integration & smoke tests).
- Tooling: `tools/` (Bazel-run binaries), `scripts/` (maintenance scripts), `docs/` (generated API docs).

## Build, Test, and Development Commands

- `bazel build //...` — Build all rules and examples.
- `bazel test //...` — Run all tests.
- `bazel test //flutter/tests:all_tests` — Core unit/toolchain test suite (run from repo root).
- `cd e2e/smoke && bazel test //:integration_tests` — Integration tests in external workspace.
- `bazel test //e2e/smoke:smoke_test` — External smoke test.
- `bazel run //tools:update_flutter_versions` — Refresh Flutter SDK versions/hashes.
- `bazel run //:gazelle` — Regenerate `bzl_library` targets.
- `pre-commit install` and `bazel run @buildifier_prebuilt//:buildifier` — Set up hooks and format BUILD/Starlark.

## Pre-Commit & Quality Gates

- Install hooks once: `pre-commit install`.
- Before pushing or completing a task, run `pre-commit run --all-files`; fix all reported issues and re-run until clean.
- Before pushing or completing a task, ensure BUILD/Starlark are formatted: `bazel run @buildifier_prebuilt//:buildifier`.
- CI enforces the same hooks and tests; PRs must be green.

## Coding Style & Naming Conventions

- Starlark formatted and linted with buildifier; use two-space indent and snake_case for symbols.
- Public rule entrypoints live in `flutter/defs.bzl`; private helpers stay under `flutter/private/`.
- Bazel targets: test targets end with `_test`; files use `.bzl` for Starlark, `BUILD.bazel` for packages.
- Markdown/YAML/JSON are formatted by Prettier (via pre-commit).

## Testing Guidelines

- Frameworks: `@bazel_skylib//lib:unittest` and `@bazel_skylib//rules:build_test.bzl`.
- Always `cd e2e/smoke` before running any integration tests.
- Add new unit/toolchain tests under `flutter/tests/*`; extend suites in `flutter/tests/BUILD.bazel`.
- Add new integration tests under `e2e/smoke/*`; wire them into `//:integration_tests`.
- AGENTS: **only** create or modify integration tests inside `e2e/smoke/`.
- Keep tests hermetic (no network, no host-specific SDKs). Use toolchains and declared inputs only.
- Run selective suites, e.g., `cd e2e/smoke && bazel test //:integration_tests`.

## Commit & Pull Request Guidelines

- Use Conventional Commits (enforced by Commitizen). Examples:
  - `feat(flutter): add flutter_app web target`
  - `fix(toolchain): correct macOS integrity hash`
- PRs must include: clear description, linked issues, CI green, updated docs for public API changes, and tests for behavior changes.
- Keep changes focused and minimal; prefer small, reviewable diffs.

## Security & Configuration Tips

- Bazel 6+ with bzlmod is expected; `.bazelrc` enables `--enable_bzlmod`.
- For downstream/local testing, you can use `--override_repository=rules_flutter=/path/to/clone`.
- Do not commit credentials or SDK artifacts; toolchains are resolved via Bazel.
